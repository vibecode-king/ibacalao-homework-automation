# Agent protocol

All requests send `Authorization: Bearer <agent token>`. Base URL must be HTTPS (HTTP only for loopback). Redirects are refused. Responses larger than 2 MiB are rejected by the client.

## POST /api/agent/jobs/claim
Body: `{ "agentId": string, "pollIntervalMs": number }`
200: `{ "job": null }` or `{ "job": { "id", "title", "subject", "dueAt", "claimToken", "leaseMinutes", "prompt", "modelName"?, ... } }`
Errors: 401 bad token, 403 `ai_consent_required`, 429 `rate_limited` (30/min), 503.
The claim token is required to finish or fail the job. Leases expire after `leaseMinutes`.

`modelName` is optional. When present, the agent uses it for this job instead of its local `IBACALAO_LLM_MODEL` value. Student writing preferences are already included in `prompt` by the server. The endpoint URL and API key remain local to the agent.

In MCP mode, the claim tool returns this job-scoped token with the prompt to the connected AI app. The host app and its model provider may therefore receive the token; handle the tool result as credential-bearing data.

## POST /api/agent/jobs/{id}/complete
Body: `{ "claimToken", "artifactHtml" (non-empty, max 500 KB), "engine"?, "model"?, "qaResult"? }` (request max 2 MiB)
200: `{ "job": { "id", "state" }, "message" }`. The server must sanitize HTML before storing or rendering it. Retrying an identical payload is safe.
Errors: 400, 409 (assignment changed or already complete, or a different artifact is saved), 413.

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
