# Moodle Homework connection

The student workflow is `/homework`: import or sync an assignment, choose one assignment, queue one draft, review the DOCX, edit it locally, save it back to iBacalao, then submit it to Moodle manually. iBacalao never submits to Moodle.

## Current school capability

On 2026-10-24, the target at `https://moodle.colstephenhawking.edu.ec/my/` redirected unauthenticated requests to Moodle login. Its REST endpoint responded but no public passwordless OAuth or student-scoped service authorization was discoverable. Do not use Moodle's password-to-token endpoint: iBacalao must not receive or store a student Moodle password.

Automatic sync is therefore **not enabled**. `/homework` labels this clearly and supplies the server-backed manual assignment import fallback. Imported data is stored in the student's Dispatch source `moodle-manual`; replacing the import replaces that source, so removed or changed instructions propagate through the existing source-hash/stale checks. The fallback preserves title, subject, instructions, due date, Moodle source URL, and completion status. It does not download private Moodle attachments; the student must add attachment instructions manually until school-approved attachment scopes are available.

## School administrator requirement for automatic sync

Before adding automatic Moodle sync, the school must create and document one least-privilege integration path:

1. Enable Moodle web services and a dedicated external service restricted to read-only course, assignment, submission-status, and file-download functions needed for the student's own enrolments.
2. Prefer a Moodle OAuth 2/OpenID Connect authorization-code client with PKCE and a revocation endpoint. The redirect URI must be an iBacalao HTTPS callback. If the Moodle version only supports service tokens, the school must supply a student-revocable, read-only personal service token flow; iBacalao must encrypt it at rest with a production KMS and never log it.
3. Permit only `core_webservice_get_site_info`, course/assignment reads, per-user submission status reads, and explicitly approved attachment reads. Do not grant assignment creation, grading, messaging, enrolment, or submission functions.
4. Verify revocation at both the school and iBacalao, token expiry/refresh behavior, rate limits, and that no write-capable web-service function is reachable.

Until each item is complete and tested with a consenting test student, the UI must remain in manual-import mode and must not claim Moodle synchronization.

## Consent and processing boundary

Importing an assignment does not call a model. The selected job is only sent to the local worker's configured model after iBacalao AI-processing consent is active; the claim endpoint enforces this again for the worker token. The model endpoint and API key remain on the student's local worker. iBacalao origin checks, authenticated user scoping, request limits, source freshness checks, bounded completion retries, and DOCX package validation remain required release gates.
