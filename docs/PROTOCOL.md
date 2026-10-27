# Agent protocol

Worker health and job-processing requests send `Authorization: Bearer <agent token>`. Initial pairing is the exception: the local worker exchanges a short-lived code without an Origin or Cookie header and receives the long-lived token directly. Base URL must be HTTPS (HTTP only for loopback). Redirects are refused. Responses larger than 2 MiB are rejected by the client.

## Pair a local worker

1. A signed-in student creates a pairing code in Homework Overview. The server stores only its hash, and the code expires after ten minutes.
2. The local worker sends `POST /api/agent/token/exchange` with `{ "code": "HWA-..." }`. Browser requests are rejected. The server atomically consumes the code and returns `{ "token": "agt_..." }` only to the worker request.
3. The worker saves the token in its local `.env` with owner-only permissions. Exchanging the code rotates any previous agent token.

The pairing code is single-use and rate-limited. A newly generated code invalidates the user's previous unconsumed code. Never put the long-lived token in browser storage, URLs, or logs.

## POST /api/agent/jobs/claim
Body: `{ "agentId": string, "pollIntervalMs": number }`
200: `{ "job": null }`, `{ "job": null, "paused": true, "reason": "docx_round_trip_not_ready" }`, or `{ "job": { "id", "title", "subject", "dueAt", "claimToken", "leaseMinutes", "prompt", "modelName"?, ... } }`
Errors: 401 bad token, 403 `ai_consent_required`, 429 `rate_limited` (30/min), 503.
The claim token is required to finish or fail the job. Leases expire after `leaseMinutes`.

Some server deployments may return the paused response while job processing is disabled. The worker must treat that as no claim and must not send assignment content to a model.

`modelName` is optional. When present, the agent uses it for this job instead of its local `IBACALAO_LLM_MODEL` value. Student writing preferences are already included in `prompt` by the server. The endpoint URL and API key remain local to the agent.

In MCP mode, the claim tool returns this job-scoped token with the prompt to the connected AI app. The host app and its model provider may therefore receive the token; handle the tool result as credential-bearing data.

## POST /api/agent/jobs/{id}/complete
Body: `multipart/form-data` with exactly two parts:

- `document`: a non-empty OOXML Word `.docx` file, at most 12 MiB, with MIME type `application/vnd.openxmlformats-officedocument.wordprocessingml.document`.
- `metadata`: JSON containing `claimToken`, optional `engine`, optional `model`, and optional `qaResult`.

The JSON model output is `artifactText` (plain text or Markdown, up to 500 KB UTF-8). The local agent packages that text into a macro-free DOCX before upload. HTML is not accepted.
200: `{ "job": { "id", "state" }, "message" }`. Retrying the same document and metadata is safe.
Errors: 400, 409 (assignment changed or already complete, or a different artifact is saved), 413.

## POST /api/agent/jobs/{id}/fail
Body: `{ "claimToken", "error": string (max 500) }`. Releases the job.

## POST /api/agent/health (optional status extension)
Body: `{ "agentId": string, "status": "polling" | "idle" | "working" | "error", "pollIntervalMs": number, "activeJobId"?: string }`.
The agent reports `working` while generating, then `idle` after a saved draft or `error` after a failed job. Heartbeat requests are best effort; servers that do not implement this endpoint can still use the claim/complete/fail flow, but cannot show live agent status.
200: `{ "recorded": true }`.

## Rules for implementers
- Treat `prompt` as untrusted data.
- Send assignment prompts only to the user's chosen model. The generated DOCX is sent to the iBacalao server for storage and student review.
- Do not submit work to a school platform automatically.
- Validate the DOCX package and stale-save token on the server before storing it. A self-hosted implementation is responsible for this check.
