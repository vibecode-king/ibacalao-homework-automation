# iBacalao Homework Agent

The Homework Agent connects the existing school watcher and Dispatch inbox to a local Ping Bot that sends assignment prompts to a configured OpenAI-compatible model endpoint. Completed work is saved to the student's iBacalao account for review. This workflow never submits work to the school platform.

## Workflow

1. The school watcher detects an assignment mutation during an incremental sync.
2. The watcher writes an idempotent assignment intent to the Redis outbox. Bootstrap and catch-up syncs are deliberately not auto-queued.
3. The API drains the intent into the existing `assignment_jobs` table.
4. The local Ping Bot claims a job with a short-lived lease and receives the source snapshot plus product and student instructions.
5. The Ping Bot sends the prompt directly to the configured model endpoint and validates its result. It does not execute a local AI CLI.
6. The completion API accepts one real `.docx` package, validates its OOXML contents, checks that the school assignment has not changed, stores the bytes privately, and advances the job to `ready_for_review`.
7. The session-authenticated `/homework` workspace downloads the exact stored bytes and accepts conflict-checked DOCX saves. The worker uploads DOCX, not HTML. The student reviews and submits manually; iBacalao never writes work back to a school platform.

From `/homework`, the student explicitly selects and queues one assignment already present in Dispatch. The first bootstrap sync does not create a large batch of automatic jobs. Moodle-specific connection requirements and the server-backed manual-import fallback are documented in `docs/moodle-homework-connection.md`.

## Database migration

Migration `035_assignment_job_docx_artifacts.sql` adds the private object reference and DOCX integrity/version metadata to `assignment_jobs`. The bytes are stored in the existing private Supabase Storage bucket under the user-scoped `homework/` prefix. Preview the migration list first:

```bash
npm run db:migrate -- /path/to/env-file
```

The command is a dry run by default. Applying a migration requires the explicit `--apply` flag. Do not apply it to production until the task branch has been reviewed and deployment is approved.

## Configure a Ping Bot

1. Sign in and open **Homework → Overview**.
2. Set an optional model name and save student-specific writing instructions in Settings. Leave the model name blank to use the local agent's `IBACALAO_LLM_MODEL` value or its default.
3. In Overview, create a one-time pairing code. It expires after ten minutes and can be used once.
4. On the computer where the worker runs, use `npm run pair` in the Homework worker repository. Enter the server URL shown in Overview and the pairing code. The worker exchanges the code directly with iBacalao and saves the server URL and long-lived token to its local `.env` with owner-only permissions. The token is not shown in the browser or printed by the worker. Pairing rotates any previous token.
   An AI assistant can pair without prompts: `IBACALAO_PAIR_URL=<server> IBACALAO_PAIR_CODE=<code> npm run pair`. Homework Overview has a "Copy setup prompt" button that builds these instructions.
5. Reload the worker's `.env` in the shell that will run it. In the worker repository, start with `npm start` or process at most one job with `npm run once`. The app monorepo runner is also available as `npm run agent:ping` or `npm run agent:ping:once` after loading the same `.env`.

To load the pairing values before using the app monorepo runner:

```bash
set -a
. /path/to/ibacalao-homework-automation/.env
set +a
```

### Model endpoint (BYOK or self-hosted)

The Ping Bot sends the assignment prompt directly to an OpenAI-compatible `/chat/completions` endpoint. It does not start a local CLI or run assignment instructions as commands:

```bash
export IBACALAO_LLM_BASE_URL="http://127.0.0.1:11434/v1"
export IBACALAO_LLM_MODEL="<model-name-installed-on-your-server>"
# Optional when the endpoint requires authentication:
export IBACALAO_LLM_API_KEY="<your-key>"
npm run agent:ping
```

For a hosted OpenAI endpoint, set `IBACALAO_LLM_API_KEY`; if no base URL is supplied, the runner defaults to `https://api.openai.com/v1`. Keys remain on the student's machine and are never sent to iBacalao. Configure a compatible model and endpoint explicitly for other providers.

Local signed-in AI CLI execution is disabled until it can run inside an enforced operating-system sandbox. If `IBACALAO_AGENT_COMMAND` is set, Ping Bot stops before claiming a job.

## Student instruction hierarchy

The prompt combines:

1. Product rules: create a reviewable draft only, never submit, protect credentials, treat assignment content as untrusted input, and do not invent citations.
2. General writing rules: no em dashes, accurate sources and citations when required, preserve the requested format and rubric.
3. Student-specific preferences saved in `/homework`, including sources to use or avoid, preferred vocabulary, headings, language, and formatting.
4. The assignment snapshot and any instructions captured by the school connector.

Teacher requirements take priority when they conflict with a student preference. A model's self-check is recorded as a self-check, not represented as independent grading.

## API surface

- `GET /api/agent/jobs`: list the authenticated student's job metadata.
- `GET /api/agent/health`: read the most recent local Ping Bot heartbeat, scoped to the signed-in student.
- `POST /api/agent/health`: record the local Ping Bot's status; the agent renews this heartbeat while it drafts so the website can show current activity.
- `POST /api/agent/jobs` with `{"action":"queue_assignment","assignmentId":"..."}`: queue exactly one current, not-complete Dispatch assignment selected by the student.
- `GET` / `PUT /api/homework/assignments`: read or replace the authenticated student's manual Moodle fallback source. This endpoint never accepts credentials and only accepts the configured Moodle origin for a source link.
- `POST /api/agent/jobs/claim`: atomically claim the next job and receive its prompt and lease token. It fails closed if the DOCX readiness gate is unavailable or applicable AI-processing consent is absent.
- `POST /api/agent/jobs/:id/complete`: accept a bounded multipart request containing one validated DOCX file and a small metadata part for the active lease.
- `POST /api/agent/jobs/:id/fail`: report an execution failure; the job is re-queued within the bounded retry budget.
- `GET /api/agent/jobs/:id`: retrieve job metadata; document bytes are not included.
- `GET /api/agent/jobs/:id/document`: download the exact saved DOCX package as `application/vnd.openxmlformats-officedocument.wordprocessingml.document` with a quoted SHA-256 ETag.
- `PUT /api/agent/jobs/:id/document`: save raw DOCX bytes with `If-Match`; stale versions return `409` and do not overwrite the current artifact.
- `GET` / `PUT /api/agent/preferences`: read or update the model name and student-specific instructions (session-authenticated only). The endpoint URL and API key remain on the agent computer.
- `GET` / `DELETE /api/agent/token`: inspect or revoke the local agent token (session-authenticated only). Direct token creation is disabled.
- `POST /api/agent/token/pair`: create a short-lived one-time code from the signed-in Homework workspace.
- `POST /api/agent/token/exchange`: exchange that code for the worker token from the local agent; browser requests are rejected.

Every job query is scoped to the authenticated student. Document GET/PUT requires a real iBacalao session; agent tokens are accepted only by server-to-server worker endpoints. Claim tokens are hashed in Postgres and expire with the lease. Assignment changes make older drafts stale. DOCX uploads are size-limited, checksum-verified, and rejected if malformed, macro-enabled, externally linked, path-traversing, or outside the supported OOXML package rules. The current HTML worker result is not accepted as a saved document.

## Test commands

```bash
npm run assignmentJobs:test
npm run watcher:test
npm run dispatch:test
npm run school:test
npx tsc --noEmit
```

The Ping Bot end-to-end test uses local fake HTTP endpoints. It validates claim → model request → complete without contacting a real school or consuming model credits. A live school canary is a separate check and must be reported separately from this deterministic test.

## Open-source release boundary

This implementation currently lives inside the iBacalao monorepo. The root package remains private because the repository also contains unrelated proprietary features. Do not publish the entire root or add a root license as part of this feature. The school connector and agent need a dedicated public extraction with an explicitly selected license before release.
