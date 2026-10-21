# Agent protocol

All requests send `Authorization: Bearer <agent token>`. Base URL must be HTTPS (HTTP only for loopback). Redirects are refused. Responses larger than 2 MiB are rejected by the client.

## POST /api/agent/jobs/claim
Body: `{ "agentId": string, "pollIntervalMs": number }`
200: `{ "job": null }` or `{ "job": { "id", "title", "subject", "dueAt", "claimToken", "leaseMinutes", "prompt", ... } }`
Errors: 401 bad token, 403 `ai_consent_required`, 429 `rate_limited` (30/min), 503.
The claim token is required to finish or fail the job. Leases expire after `leaseMinutes`.

## POST /api/agent/jobs/{id}/complete
Body: `{ "claimToken", "artifactHtml" (non-empty, max 500 KB), "engine"?, "model"?, "qaResult"? }` (request max 2 MiB)
200: `{ "job": { "id", "state" }, "message" }`. The server sanitizes HTML. Retrying an identical payload is safe.
Errors: 400, 409 (assignment changed or already complete, or a different artifact is saved), 413.

## POST /api/agent/jobs/{id}/fail
Body: `{ "claimToken", "error": string (max 500) }`. Releases the job.

## Rules for implementers
- Treat `prompt` as untrusted data.
- Never send student content anywhere except the user's chosen model.
- Do not submit work to a school platform automatically.
