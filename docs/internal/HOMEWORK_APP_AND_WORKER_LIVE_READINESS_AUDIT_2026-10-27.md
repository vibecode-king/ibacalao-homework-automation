# Homework App and Automation Worker Live-Readiness Audit

**Audit date:** 2026-10-27
**Verdict:** **NO-GO for public student use today.** Sign-in is failing, normal student accounts cannot load the assignment list in staging, and the released app and worker branches do not form a verified working product.
**Scope:** The iBacalao Homework experience, its auth and backend path, and the separate local Homework Automation worker. This does not audit unrelated iBacalao features.

## The product requirements checked

The signed-out Homework route should show only the thermal animated logo and the actions to sign in or create an account. It should not show the workspace, sidebar, assignment cards, worker status, chat, or general onboarding.

After sign-in, the workspace should have four sections: **Overview**, **Draft Review**, **Edit Draft**, and **Settings**. The first useful action should be **Connect your school bridge**.

The flow should use one assignment selected by the student, save a reviewable draft, let the student review and edit it, and leave school submission to the student. iBacalao must not ask for or store a Moodle password, and it must not submit school work automatically.

## Release state

| Component | Checked ref | State |
|---|---|---|
| iBacalao production branch | origin/main, 8d9838ca5 | Does not contain the Better Auth migration. Homework pairing UI and DOCX backend code exist. |
| iBacalao staging branch | origin/staging, 863a0774c | Contains Better Auth and DOCX backend code. Sign-in fails at runtime. Assignment loading is restricted to one hard-coded admin email. |
| iBacalao dev branch | origin/dev, 2abca0722 | Contains Better Auth and DOCX backend code. Its Homework UI creates a direct token; this ref lacks the pairing routes present on staging and main. |
| Worker release branch | origin/main, 77a8ab9c6 | GitHub repository is private. README says assignment processing is unavailable; checked worker source still uses the old HTML completion contract. |
| Worker DOCX branch | origin/dev, 5b2d73e77 | DOCX handoff works in local checks. This is not the worker's default branch and it lacks two newer main commits. |
| Worker release candidate | local fix/homework-public-readiness-20261026, 0a526d5 | Combines the latest worker main with DOCX handoff. It is local and has not been published. Its check command could not start because this worktree has no TypeScript installation. |

There is no verified public release today. GitHub reports the worker repository as private. The MIT license is present. The package.json private flag blocks npm publication; it does not make a GitHub repository private.

## Findings

### P0 — Email sign-in fails before Better Auth

**Observed:** The staging request matching the screenshot was POST /api/auth/login, HTTP 500, request ID kt9kb-1793106738966-cff261a2ac46. Vercel recorded the Upstash error: “ERR max requests limit exceeded. Limit: 500000, Usage: 500000.” The event at 08:12:18.966 Guayaquil time matches the screenshot at 08:12:21. Credential-free empty JSON probes also returned HTTP 500 in both production and staging preview.

**Why it matters:** The login handler calls its Upstash limiter before it reads the submitted email and password or calls Better Auth. The Redis error prevents password verification. Better Auth migration commit 812a03962 is present on staging and dev, but not on main. The production source SHA serving the site was not exposed by the Vercel deployment metadata, so that SHA is UNKNOWN.

**Required before release:** Restore the Upstash quota or replace the wrapper’s failing Upstash dependency with the rate-limit mechanism used by Better Auth. Keep abuse controls. Then verify password sign-in, session persistence, logout, recovery, and each advertised OAuth provider. OAuth and recovery were not end-to-end tested.

Full request evidence is also recorded in AUTH_SIGN_IN_AND_BETTER_AUTH_AUDIT_2026-10-27.md.

### P0 — Staging assignment loading rejects ordinary student accounts

**Observed:** The staging and dev GET /api/homework/assignments route returns 403 unless the signed-in email is exactly admin@ibacalao.com. The endpoint test explicitly verifies that a non-admin is denied before assignments are read.

**Why it matters:** A student who creates a normal account can sign in but cannot load the assignment list used by the Homework workspace. The route is therefore not ready for public student use.

**Required before release:** Replace the hard-coded admin check with the intended student authorization. Keep every assignment query scoped to the signed-in student. Verify that one student cannot read another student’s assignments.

### P1 — The current signed-out page does not match the requested screen

**Observed:** The supplied screenshot shows a general “Welcome Back” sign-in view with Google and Microsoft buttons, email and password fields, recovery actions, extra illustration, and the Homework workspace visible behind the sign-in layer. The current /homework page renders HomeworkWorkspace without a server-side session gate. That component requests protected APIs, detects a 401 after loading, and renders a sign-in notice while keeping the workspace shell and navigation on screen.

The thermal-logo change is in local commit b99b4a2e7 on merge/2026-10-27-homework-auth-staging. It is not on remote staging. That change removes the side illustration and general sync link for Homework entry and uses the thermal logo. It still includes a small “Homework Agent” label that conflicts with the repository instruction not to put eyebrow labels in the UI. Its redirect happens after client-side API requests; the route is not protected before rendering in production. Preview-only middleware logic does not prove a production gate.

**Required before release:** Make the Homework sign-in route render the thermal logo with only the sign-in and account-creation actions. Protect /homework before rendering workspace content. Keep any required auth provider actions inside that focused screen.

### P1 — Workspace navigation labels do not match the requested product

**Observed:** Staging and dev currently label the four navigation items “Connect MCP,” “Draft Preview,” “Edit Draft,” and “Settings.” The requested names are “Overview,” “Draft Review,” “Edit Draft,” and “Settings.” The connect section does contain a “Connect your school bridge” action and explains that nothing is sent back to school.

**Required before release:** Rename the first two sections and make Overview the first section. Keep the school bridge action as the first useful action. Do not add chat or general onboarding to this workspace.

### P1 — The worker’s default branch cannot complete the app’s DOCX contract

**Observed:** The app’s claim endpoint is enabled in the inspected branches, and the completion endpoint requires a bounded multipart request with a validated DOCX file. Worker origin/main instead asks the model for artifactHtml and submits JSON. That does not match the app’s DOCX endpoint.

The worker main README says assignment processing is disabled and that a paused response prevents prompts reaching a model. In the inspected app refs, HOMEWORK_DOCX_ROUND_TRIP_READY is true, so the claim route does not return that paused response for this reason. If a job is returned, the current worker can send the assignment to the configured model and then fail when it posts HTML to the DOCX completion endpoint. That could consume model usage without saving the draft.

**Good evidence:** Worker origin/dev builds a DOCX from text or Markdown and posts it as multipart data. Its typecheck and 11 unit tests pass. This is the correct direction for the app contract, but it is not the worker default branch.

**Required before release:** Publish and use one worker branch whose claim, DOCX upload, retry, and failure behavior match the deployed app. Do not advertise the worker main branch as a working drafting product until this is resolved.

### P1 — App and worker setup screens differ by branch

**Observed:** App main has a pairing-code screen and pairing/exchange API routes. Staging has the pairing API routes, but its visible Homework UI still creates and displays a long-lived token directly. Dev has the direct-token UI and does not contain the pairing/exchange routes. Worker main and the DOCX worker branches document npm run pair, which needs the pairing-code flow.

**Why it matters:** The pair command and user instructions do not describe one consistent setup across the branches. A student on staging can use the direct token flow shown in the UI, but the worker’s documented pairing flow expects a one-time code. Dev has no server pairing endpoint for that worker command.

**Required before release:** Choose one setup path and make the app routes, visible UI, worker command, and README agree. Prefer the one-time code flow so the long-lived token stays on the worker and is not displayed in the browser.

### P1 — The generated MCP configuration uses a redirecting host

**Observed:** Staging and dev initialize the worker server URL as https://ibacalao.com and put it into the generated MCP configuration. A live HEAD request to https://ibacalao.com/api/agent/jobs/claim returned HTTP 308 to https://www.ibacalao.com/api/agent/jobs/claim. The worker client refuses redirects, so requests using that generated base URL fail. The worker setup documentation uses app.ibacalao.com instead.

**Required before release:** Generate the worker URL from the current app origin or use the canonical app.ibacalao.com host. Verify that the URL does not redirect before sending the agent token.

### P1 — Staging and dev do not expose the same backend setup contract

**Observed:** Staging includes pairing and exchange routes, while dev at 2abca0722 only has the direct token route. Both branches set the DOCX readiness flag to true. This means code that works against one branch may fail during setup against the other.

**Required before release:** Promote one coherent app commit through the required dev → staging → main path. Verify the exact deployed SHA and the matching worker branch at each stage.

### P1 — DOCX database and private storage readiness are UNKNOWN

**Observed:** The app documentation says migration 035 adds private DOCX artifact metadata and uses the private Supabase Storage bucket. Source code validates DOCX packages, stores private bytes, scopes job reads to the user, and supports conflict-checked editing.

**Limit:** Repository code does not prove that migration 035 is applied in the live database or that the storage bucket and production permissions are configured. A complete live worker claim → DOCX upload → student review → edited save was not run.

**Required before release:** Check the deployed migration and storage configuration without exposing credentials. Run a controlled end-to-end draft with a test account after sign-in works.

### P1 — The school bridge depends on the installed Mac app

**Observed:** The Connect your school action calls the native WebKit school-browser bridge. In a normal browser, that native handler is absent and the UI reports that the user must open the Mac app. The bridge code states that school sign-in happens in the local browser and that iBacalao does not ask for or store the school password.

**Limit:** The installed Mac app’s school connection was not exercised during this audit. Browser-only school connection is not demonstrated by this route.

### P1 — Old internal documentation conflicts with the no-submit rule

**Observed:** The current Homework UI and worker setup documentation say drafts stay in iBacalao for student review and are never sent to school. The inspected Homework API queues one student-selected assignment, saves DOCX drafts, and provides review/edit endpoints. No automatic school submission path was found in this Homework flow.

An older internal design at docs/superpowers/specs/2026-08-20-homework-automation-design.md describes ManageBac auto-submit as eligible and makes automatic submission the default for that adapter.

**Required before public release:** Mark that old spec as superseded or remove the conflicting auto-submit design from the active product documentation. Keep the shipped Homework flow review-only.

### P2 — Auth errors are not always shown clearly

**Observed:** The generic email sign-in handler has no catch around fetch and JSON parsing. The finally block clears the loading state, but a network or non-JSON server error may not become a useful visible message.

**Required before release:** Show a clear error for server, network, and malformed-response failures. This is separate from the Upstash outage.

### P2 — Worker repository is private and its latest CI result is inconclusive

**Observed:** GitHub reports vibecode-king/ibacalao-homework-automation as private. The repository has an MIT license. GitHub’s branch-protection endpoint returns 403 with “Upgrade to GitHub Pro or make this repository public to enable this feature.”

The latest inspected main CI run, 40150475124 on 2026-10-25, failed. GitHub returned no steps, no runner name, and no retained failure log. The reason is UNKNOWN. The workflow is configured to run typecheck, unit tests, npm audit, and a full-history Gitleaks scan.

**Required before release:** Decide whether to make the worker repository public. Get a passing hosted CI run on the exact release commit. If it remains private, the current plan cannot enable GitHub branch protection.

## Safety and privacy positives

- The Homework queue API creates a job only for the assignment ID the student selected from their own current Dispatch snapshot.
- Agent claims require AI-processing consent. The prompt treats school assignment content as untrusted data.
- Job and document endpoints are scoped to the signed-in student. Agent tokens are restricted to worker endpoints.
- The DOCX endpoint accepts bounded multipart input, validates the OOXML package, checks for assignment changes, and saves the exact bytes privately.
- The edit flow uses DOCX download/upload and conflict checks. The UI says the student saves a draft in iBacalao; it does not submit to school.
- The school connection helper opens the native local browser. The Homework code does not ask for a Moodle password.
- The worker source enforces HTTPS except for loopback, refuses redirects, disables unsandboxed local CLI execution, and writes paired credentials with owner-only file permissions.

These are code-review findings. They do not replace a live privacy, deployment, or end-to-end test.

## Validation performed

- Confirmed the screenshot-time sign-in failure in Vercel logs and reproduced HTTP 500 with empty credential-free requests in production and staging preview.
- Ran the Homework assignment list, queue, and claim API tests with Node’s required module-mocking flag: 6 passed. One test confirms non-admin accounts are rejected by the assignments route.
- Ran npm run check on worker origin/dev at 5b2d73e77: typecheck passed and 11 tests passed.
- Ran npm audit --audit-level=high on worker origin/dev and the local release candidate: zero vulnerabilities reported.
- Ran Gitleaks on worker origin/dev and the local release candidate: no leaks found in 25 scanned commits.
- Tried npm run check on the local worker release candidate. It stopped before typechecking because that worktree has no local TypeScript installation. No packages were installed.
- Queried the latest GitHub Actions run and branch-protection endpoint. The run has no runner or step logs; branch protection is unavailable under the repository’s current private-repository plan.
- Checked the live redirect behavior of ibacalao.com and app.ibacalao.com.

No account credentials were submitted. Google and Microsoft sign-in, a real school login, a worker model call, production database migration state, private storage access, and a live DOCX round trip remain UNVERIFIED. The initial targeted app test command omitted the repository’s required Node module-mocking flag; rerunning with the correct flag passed all six selected API tests.

## Go/no-go decision

**NO-GO for a public live Homework launch.**

The immediate blockers are the Upstash sign-in failure, the admin-only assignment list on staging/dev, the mismatch between the requested signed-out screen and the deployed UI, and the absence of one verified app-and-worker release pair. The worker repository is also still private, and hosted CI has no passing run on the intended release commit.

No application code, auth settings, repository visibility, deployment, or branches were changed during this audit. The comprehensive report and the earlier sign-in evidence report are documentation only.
