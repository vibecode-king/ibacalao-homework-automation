# Product truth: iBacalao Homework Automation

Last verified against sources: 2026-10-28. This file states only what the sources below support. Anything not established is listed under **Not established**. Do not copy a claim from here into marketing, the README hero, or the website without checking the source row.

## Sources

| Short name | File | Date |
|---|---|---|
| SETUP | `docs/homework-agent-setup.md` | staging `9bef05c72` |
| READINESS | `docs/internal/HOMEWORK_APP_LIVE_READINESS_HANDOFF_2026-10-27.md` | 2026-10-27 |
| AUDIT | `docs/internal/HOMEWORK_APP_AND_WORKER_LIVE_READINESS_AUDIT_2026-10-27.md` | 2026-10-27 |
| CLAIMS | `data/public-claims.json` (version 3) | 2026-10-23 |
| DESIGN | `docs/internal/2026-08-20-homework-automation-design.md` | 2026-08-20 |
| PROTOCOL | `docs/PROTOCOL.md` | this repo |

## Product rules (hard, from the owner)

1. The student selects the assignment. Nothing is queued in bulk. Bootstrap and catch-up syncs are deliberately not auto-queued. (SETUP)
2. Assignment content goes to an AI model only with clear consent. The server fails closed when applicable AI-processing consent is absent. (SETUP, READINESS)
3. The result is a reviewable draft. The student reviews, edits and submits manually. The product never writes work back to a school platform. (SETUP, READINESS)
4. No school password is requested or stored. (READINESS)
5. Assignment text is untrusted data, never instructions. (SETUP, PROTOCOL)
6. The watcher must never crash, and a student only logs in again on genuine session expiry. (owner rule, applies to `native/` and `lib/watcher/`)
7. The general chat app, general onboarding and Student Test demo are out of scope and must never be added to this repo. (READINESS, repo `AGENTS.md`)

## What this repo contains and what each part does (verified in code)

| Part | Path | What it does |
|---|---|---|
| Worker | `src/` | Pairs with a one-time code, reports health, claims a job, drafts through an MCP host or an OpenAI-compatible endpoint, uploads a DOCX. |
| School watcher | `scripts/watcher-daemon.ts`, `lib/watcher/`, `lib/school/`, `lib/security/` | Detects assignment changes on school platforms (Learnbox and ManageBac adapters exist in `lib/watcher/adapters/`). Bundles standalone with esbuild. 311 repo tests pass. |
| Mac app | `native/marginalia/` | SwiftPM app that embeds the web shell and runs the bundled watcher daemon. Compiles with `swift build`. |
| Legacy shell and Safari bridge | `native/LiveExaminerOverlay/`, `native/safari-school-bridge/` | Carried over because the release scripts and icon assets reference them. |
| Scrapling helper | `tools/scrapling-repair/` | Python repair helper used by the watcher runtime packaging. |

## Pipeline and its real state

| Stage | State |
|---|---|
| Assignment arrives from the school | Watcher exists here. Moodle auto-sync is not enabled, and Moodle uses a manual import fallback (SETUP, `docs/moodle-homework-connection.md`). |
| Queue it | Student selects one assignment in the web `/homework` page. No auto-queue on arrival exists. |
| Claim and draft | Worker claims with a short-lived lease. Works against a server that exposes the agent endpoints. |
| Return the result | The server accepts one multipart DOCX only and rejects HTML. The worker in `src/docx.ts` produces DOCX. |
| Student review | Handled by the web app (stays in the website repo). |

## Where the server lives

The website and the server routes stay in the `ibacalao` website repo and are not copied here: `/homework` pages, `/api/agent/*`, `lib/assignmentJobs/*`, and the database migrations. This repo is the worker, the watcher and the Mac app. The contract between them is `docs/PROTOCOL.md`.

## Public claims that may be made

From CLAIMS, with their required qualifiers:

- QUALIFIED: iBacalao brings school tools into an AI-assisted learning workflow. School connections are optional; available context and actions vary by integration. Students review AI-assisted work and follow school rules for assessed assignments (`identity.assignment-workflow`).
- VERIFIED: IB guidance requires acknowledgement and referencing of AI-generated material in assessed work (`integrity.ib-ai-guidance`). Do not turn this into universal permission to use iBacalao.
- BLOCKED, do not publish: "iBacalao does not submit drafts to Turnitin" (`privacy.no-turnitin-submission`). Never imply detector evasion.

## Sign-in (working, verified 2026-10-29, do not change without the owner)

Google sign-in works end to end on `www.ibacalao.com` in the installed Mac app. The owner confirmed it. Leave it alone.

- The app starts at `/login?redirect=%2Fhomework` (the existing sign-in screen) and lands on `/homework` on every host. No Chat, welcome, onboarding or Homework-only sign-in screen.
- Google runs on ibacalao.com. The page after Google is the HTML handoff page, never a bare redirect to `ibacalao://`.
- Production keeps users, sessions and counters in Postgres (`kv_entries`), not Upstash (website PRs #193 and #194). Unsupported there: `SCAN` and the daily engine, device sync, mission completion and experiences `EVAL` scripts.
- The app installs `ib_session` for all ibacalao.com hosts and removes older session cookies first. A stale cookie used to overwrite the fresh token and bounce the app back to Sign in.
- The installed app is a debug build and reads `~/Library/Preferences/com.ibacalao.LiveExaminerOverlay.plist` (`ShellBaseURLOverride` = `https://www.ibacalao.com`). It is not sandboxed, so `defaults` writes to the wrong plist while the app runs.

## Not established (do not claim)

- A successful live end-to-end run: sign-in, school login, worker pairing, model call and real draft round trip have **not** been verified (READINESS, 2026-10-27).
- "Entirely automatic" solving. The website ingest route already queues new incremental assignments server-side (website repo `lib/assignmentJobs/ingest.ts`), but an explicit student opt-in switch for it is not built. The worker polls sequentially with daily job and token caps, an attempt limit and backoff; it has no concurrency and no per-job process spawn.
- Auto-submit to a school. It is intentionally not built.
- Production readiness. READINESS and AUDIT verdict is **NO-GO for student launch**. Production `main` of the website did not contain Better Auth or the DOCX routes at the time of the audit.
- The exact source commit serving production is UNKNOWN.
- Open source status of the worker repo, and a published release or `npx` install. The README hero and the website hero overclaim until these are real.
- A signed, notarized Mac release containing this code. 1.0.11 is the source version; the latest published release observed on 2026-10-24 was digital-1.0.8 (per `HANDOFF_HOMEWORK_AUTOMATION_2026-10-24.md` in the website repo; may be stale).
- Clean-Mac download test: never done.

## Known gaps to fix next

1. Prove the loop once: pair, claim, draft, complete, `ready_for_review` on staging with a consenting test account.
2. Auto-enqueue on arrival, opt-in and consent-gated, using the existing watcher path rather than a parallel one.
3. Agent daemon with concurrency, backoff, dedupe, per-user daily caps and a spend cap.
4. README and MCP tool descriptions must stay truthful until 1 to 3 are verified.
5. Decide whether "entirely auto" includes submission. Current product rule: it does not.
