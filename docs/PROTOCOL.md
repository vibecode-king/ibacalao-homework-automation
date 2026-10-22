# Agent protocol

Worker health and job-processing requests send `Authorization: Bearer <agent token>`. Initial pairing is the exception: the local worker exchanges a short-lived code without an Origin or Cookie header and receives the long-lived token directly. Base URL must be HTTPS (HTTP only for loopback). Redirects are refused. Responses larger than 2 MiB are rejected by the client.

## Pair a local worker

1. A signed-in student creates a pairing code in Homework settings. The server stores only its hash, and the code expires after ten minutes.
2. The local worker sends `POST /api/agent/token/exchange` with `{ "code": "HWA-..." }`. Browser requests are rejected. The server atomically consumes the code and returns `{ "token": "agt_..." }` only to the worker request.
3. The worker saves the token in its local `.env` with owner-only permissions. Exchanging the code rotates any previous agent token.

The pairing code is single-use and rate-limited. A newly generated code invalidates the user's previous unconsumed code. Never put the long-lived token in browser storage, URLs, or logs.

## POST /api/agent/jobs/claim
Body: `{ "agentId": string, "pollIntervalMs": number }`
200: `{ "job": null }`, `{ "job": null, "paused": true, "reason": "docx_round_trip_not_ready" }`, or `{ "job": { "id", "title", "subject", "dueAt", "claimToken", "leaseMinutes", "prompt", "modelName"?, ... } }`
Errors: 401 bad token, 403 `ai_consent_required`, 429 `rate_limited` (30/min), 503.
The claim token is required to finish or fail the job. Leases expire after `leaseMinutes`.

The current iBacalao web implementation returns the paused response above. It can pair the worker and report health, but it does not release assignment content to the worker until the DOCX round-trip contract is implemented.

`modelName` is optional. When present, the agent uses it for this job instead of its local `IBACALAO_LLM_MODEL` value. Student writing preferences are already included in `prompt` by the server. The endpoint URL and API key remain local to the agent.

In MCP mode, the claim tool returns this job-scoped token with the prompt to the connected AI app. The host app and its model provider may therefore receive the token; handle the tool result as credential-bearing data.

## POST /api/agent/jobs/{id}/complete
Body: `{ "claimToken", "artifactHtml" (non-empty, max 500 KB), "engine"?, "model"?, "qaResult"? }` (request max 2 MiB)
200: `{ "job": { "id", "state" }, "message" }`. The server must sanitize HTML before storing or rendering it. Retrying an identical payload is safe.
Errors: 400, 409 (assignment changed, already complete, different artifact saved, or current iBacalao web implementation has disabled HTML completion), 413.

`artifactHtml` is the legacy protocol contract and is not a DOCX representation. Do not label it as `.docx` or use it as the sole saved copy. See the web app's `docs/homework-docx-roundtrip-contract.md` for the required binary contract.

## POST /api/agent/jobs/{id}/fail
Body: `{ "claimToken", "error": string (max 500) }`. Releases the job.

## POST /api/agent/health (optional status extension)
Body: `{ "agentId": string, "status": "polling" | "idle" | "working" | "error", "pollIntervalMs": number, "activeJobId"?: string }`.
The agent reports `working` while generating, then `idle` after a saved draft or `error` after a failed job. Heartbeat requests are best effort; servers that do not implement this endpoint can still use the claim/complete/fail flow, but cannot show live agent status.
200: `{ "recorded": true }`.

## Rules for implementers
- Treat `prompt` as untrusted data.
- Never send student content anywhere except the user's chosen model.
- Do not submit work to a school platform automatically.
- Sanitize `artifactHtml` on the server before storing or rendering it. A self-hosted implementation is responsible for this check.
