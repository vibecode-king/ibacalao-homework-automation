# iBacalao Homework Live Readiness Handoff

**Date:** 2026-10-27
**Decision:** **NO-GO for student launch.**
**Current authorization:** Audit, plan, and this handoff only. No implementation, more tests, service restart, install, publish, push, merge, or deploy is authorized by the current request.

## What this handoff covers

This is a standalone handoff for the requested iBacalao Homework screens and their real auth, school bridge, worker, and draft path. It is not a request to redesign the rest of iBacalao. The requested product surface is:

1. A signed-out first screen with the thermal iBacalao logo and **Sign in** / **Create an account** actions.
2. A focused sign-in and account creation screen. Successful sign-in must land directly in Homework.
3. The signed-in Homework workspace with **Overview**, **Draft Review**, **Edit Draft**, and **Settings**, including school connection, worker/MCP setup, and draft editing.

The product must process only an assignment the student selected, require clear consent before sending assignment content to an AI model, let the student review and edit the resulting draft, and leave submission to the student. Do not ask for or store a school password. Do not submit work to Moodle automatically.

The user has repeatedly clarified that the general chat app, the general onboarding flow, and other product screens are outside scope. In particular, the screenshot reading “SET IT UP ONCE. THEN WAIT FOR THE ‘SUBMITTED’ NOTIFICATION.” is unwanted for this Homework flow. Its exact redirect trigger was not established. It is evidence that the user reached a general onboarding screen, not proof that Homework submitted an assignment.

## Correct app and route

The target app is the installed **`/Applications/iBacalao.app`** on the Mac, showing the staging Homework route:

```text
https://ibacalao-git-staging-vanos-projects-91d1222a.vercel.app/homework
```

The user corrected an earlier mistake: **`/Users/joaquin/Applications/iBacalao Student Test.app` is not the requested app.** The earlier general workspace/dashboard screenshot from that app is not valid evidence for the requested Homework first screen.

The actual installed iBacalao app was subsequently opened on the staging `/homework` route. Its visible screen included the Homework sections and a sign-in path. At 10:19 on 2026-10-27, the user supplied a screenshot showing the general “SET IT UP ONCE…” onboarding page after attempting the flow. The user had earlier supplied the school login URL for a future live test:

```text
https://moodle.colstephenhawking.edu.ec/login/index.php
```

No successful iBacalao login, school login, worker pairing, model call, or real draft round trip has been established. The user must enter account and school credentials directly into the correct app/browser when a live test is authorized. Do not ask them to send credentials in chat.

## Source audits

The two source audits are in another task’s owned worktree. Read them as evidence; **do not edit, adopt, or remove that worktree or its owner claim**.

- [Homework app and worker live-readiness audit](/Users/joaquin/Documents/iBacalao/.worktrees/auth-live-readiness-audit/docs/app-launch/HOMEWORK_APP_AND_WORKER_LIVE_READINESS_AUDIT_2026-10-27.md)
- [Sign-in and Better Auth audit](/Users/joaquin/Documents/iBacalao/.worktrees/auth-live-readiness-audit/docs/app-launch/AUTH_SIGN_IN_AND_BETTER_AUTH_AUDIT_2026-10-27.md)

The first audit’s verdict is NO-GO. It records the release-branch gaps, student authorization failure, app/worker contract mismatch, and unknown live DOCX storage setup. The second audit traces the live sign-in failure to the exhausted Upstash Redis quota in front of Better Auth. Neither audit is proof of a successful live end-to-end Homework flow.

## Observed release state

These refs were checked on 2026-10-27 and can move. Recheck their current tips before any later implementation or release decision.

| Component | Ref observed | Evidence and consequence |
|---|---|---|
| iBacalao `dev` | `origin/dev` at `2abca0722` | Contains Better Auth commit `812a03962` and DOCX backend code. The Homework UI still uses a direct-token setup path at this ref; pairing/exchange routes are missing here. |
| iBacalao `staging` | `origin/staging` at `863a0774c` | Contains Better Auth, pairing API routes, and DOCX backend code. Its visible Homework UI still exposes a long-lived token directly. Ordinary students are rejected by an admin-email check on assignment loading. Live auth requests failed. |
| iBacalao `main` | `origin/main` at `8d9838ca5` | Does not contain Better Auth commit `812a03962`. The exact source SHA serving production was not available from the inspected Vercel metadata and remains **UNKNOWN**. A live `/homework` request redirected to `/`; this alone does not identify the deployed source SHA. |
| Worker release | `origin/main` at `77a8ab9c6` | The repository was private at audit time. Its release branch still uses an older HTML completion contract, which does not match the app’s DOCX endpoint. |
| Worker DOCX branch | `origin/dev` at `5b2d73e77` | Has the DOCX handoff and passed its local typecheck and 11 tests, but is not the worker default branch and lacks two newer `main` commits. |
| Worker candidate | local `fix/homework-public-readiness-20261026` at `0a526d5` | Combines the newer worker `main` with DOCX support. Local only; not published. Its prior `npm run check` could not start because that worktree lacked TypeScript. |

Do not merge `staging` wholesale into production. The repo has other app surfaces, including Student Test, and its documented promotion path is task branch → `dev` → `staging` → `main`, with explicit user approval required before pushing or promoting to production.

## Live auth evidence

The sign-in issue is **not evidence that Better Auth is a different provider**. Better Auth is already present on the observed `dev` and `staging` refs. The direct failure is a separate exhausted Redis rate-limit dependency that runs before the Better Auth check.

- The sign-in audit matched a staging `POST /api/auth/login` failure at 08:12 Guayaquil time (2026-10-27), HTTP 500. Vercel recorded `ERR max requests limit exceeded. Limit: 500000, Usage: 500000`. The route’s custom Upstash check runs before it parses credentials or calls Better Auth.
- Credential-free empty JSON probes also returned HTTP 500 in the inspected production and staging environments. They did not use a real account password.
- The later user-provided 10:19 screenshot showed the staging Google flow. A sanitized Vercel log query matched `POST /api/auth/oauth/start/google`, HTTP 503 at 10:19:01.863 Guayaquil time, with the same exhausted Upstash request limit. This does not establish that Google authentication completed or that credentials were checked.
- The staging and dev assignment endpoint checks whether the signed-in email is exactly `admin@ibacalao.com`. A normal student therefore receives 403 even if authentication succeeds.
- Better Auth configuration uses Postgres-backed sessions and rate limits, but existing application data paths still use Redis for legacy profile/account data, native OTP, agent pairing/token records, and other compatibility functions. Treat Redis as a legacy data/storage dependency in this investigation, not as the auth provider. Do not disable it or recreate accounts without proving a safe, data-preserving replacement for every dependent record.
- OAuth callback code has a new-user path to `/onboarding`. Email signup code also had a general onboarding redirect. The precise path that produced the user’s 10:19 onboarding screenshot remains **UNKNOWN**; inspect and verify each Homework auth entry and callback separately.

## Main readiness blockers

### P0: Sign-in depends on an exhausted rate-limit service

The custom Upstash call can fail before Better Auth processes sign-in. The same service has been observed in other auth paths, including OTP and recovery. Removing abuse protection is not a fix. The solution must preserve rate limiting using a healthy, verified implementation and must keep existing user identity, session, legacy-profile, and account data intact.

### P0: Ordinary students cannot load their assignments

The observed staging/dev assignment route denies users outside a hard-coded admin email. The authorized behavior is per-user access to the student’s own assignments and jobs, with a second user unable to read the first user’s work.

### P0: The requested screen sequence is not proven live

The user reached unwanted general onboarding after using the real app. No successful path from first screen → auth → Homework workspace has been demonstrated for email, Google, or Microsoft. A local mock or browser-only route is not live proof.

### P1: App and worker pairing paths disagree

The observed branches mix direct long-lived browser tokens and one-time pairing codes. Dev lacks pairing routes while staging has routes whose UI does not use them. Choose one pairing contract across the Homework UI, app API, worker CLI, and README. Prefer a short-lived, single-use code so the durable worker token never needs to appear in the browser.

The generated worker API origin must also be canonical and non-redirecting. `https://ibacalao.com` was observed redirecting to `https://www.ibacalao.com`, while the worker refuses redirects. Verify the selected app API host before sending a token.

### P1: The worker default branch does not match the DOCX app contract

Worker `main` still posts the older HTML completion shape. The app expects a DOCX upload. A job could consume model usage and then fail to save. Select one compatible release commit and verify claim, completion, retry, and failure behavior together. The intended public/private repository policy and passing hosted CI on that exact release commit were not verified.

### P1: Live DOCX storage readiness is unknown

Repository code includes private DOCX metadata and storage behavior, validation, per-user access, and edit conflict checks. Code does not prove that migration 035 is applied in the live database, that the private storage bucket exists, or that deployed permissions/environment configuration are correct.

### P1: School connection and document editing have explicit limits

School connection uses the installed Mac app’s native WebKit browser bridge. The school login must happen locally, and the app must not collect or store the Moodle password. The bridge was not exercised with the school account.

The current edit path is a DOCX download/edit/upload round trip with an ETag conflict check. It is not an embedded Word editor. Do not claim it is one. No automatic Moodle submission was found in the inspected current Homework flow, but the older internal design at `docs/superpowers/specs/2026-08-20-homework-automation-design.md` conflicts with the no-submit requirement and must not guide this flow.

## Current local work: preserve it

The user’s most recent instruction narrowed the task to audit and plan. The following code changes were made earlier in the same task, before that correction. They remain uncommitted and must not be silently applied, discarded, reset, or represented as released. Review them as a draft if implementation is authorized later.

### iBacalao app worktree

```text
Path:   /Users/joaquin/Documents/iBacalao/.worktrees/fix-auth-live-signin-resilience
Branch: fix/auth-live-signin-resilience
HEAD:   2abca07220c6244f1bfb3b75900096976cb85061
Base:   origin/dev at the same commit when last checked
Owner:  ibacalao-auth-signin-resilience-20261027
State:  dirty; no task commit created
```

The current draft includes auth error/limiter handling, the student assignment authorization change, a Homework signed-out page and auth redirect work, worker token pairing/exchange routes, a consent endpoint/UI, and tests for the changed paths. This is not a production fix: runtime data dependencies remain, the new-user OAuth onboarding route is not fully resolved, live auth was not completed, and the build did not finish. The full modified/untracked path list is in `git status --short --branch` at that worktree. At last check, tracked changes covered:

```text
app/api/auth/forgot-password/route.ts
app/api/auth/login/route.ts
app/api/auth/login/verify/route.ts
app/api/homework/assignments/__tests__/route.test.ts
app/api/homework/assignments/route.ts
app/homework/HomeworkWorkspace.tsx
app/homework/page.tsx
app/homework/sign-in/page.tsx
app/login/page.tsx
components/AuthModal.tsx
components/SiteFooter.tsx
lib/__tests__/middleware.appHost.test.ts
lib/appAuth.ts
lib/assignmentJobs/agentToken.ts
lib/nativeAuth.ts
middleware.ts
```

There are also untracked route/component/test files under `app/api/agent/consent/`, `app/api/agent/jobs/[id]/document/__tests__/`, `app/api/agent/token/`, `app/api/auth/login/__tests__/`, and `app/homework/__tests__/`, plus `components/desktop/HomeworkThermalLogo.tsx`, `lib/authRateLimit.ts`, and related tests. Recheck exact status before editing.

The install `npm ci` in this app worktree was explicitly approved by the user and completed earlier. Do not infer permission for another install. `node_modules` is ignored local state.

### Homework worker worktree

```text
Path:   /Users/joaquin/Documents/.worktrees/ibacalao-homework-worker-pairing
Branch: fix/homework-worker-pairing
HEAD:   0a526d53ad2a6b2d1ba450c28bd15b0388a9f043
State:  dirty; no commit or publish
```

Its current draft changes only `README.md`, `docs/PROTOCOL.md`, and `src/pair.ts`, updating setup wording to the Overview → Connect the Homework worker flow. The worker check had passed earlier (typecheck plus 11 tests); that validates local worker code only, not the deployed pair or end-to-end flow.

### Other existing worktrees

- Audit source worktree: `/Users/joaquin/Documents/iBacalao/.worktrees/auth-live-readiness-audit`, branch `docs/auth-live-readiness-audit-20261027`, owned by a different task. Its two audit documents are untracked. Do not modify or claim it.
- Staging integration worktree: `/Users/joaquin/Documents/.worktrees/ibacalao-homework-auth-staging-20261027`, branch `merge/2026-10-27-homework-auth-staging`, local commit `b99b4a2e7`. It has a prior thermal sign-in UI change, is not pushed, and is separate from the current app worktree. Preserve it and inspect before any future integration.
- Worker base checkout `/Users/joaquin/Documents/ibacalao-homework-automation` had local divergence and an untracked `.worktrees/` directory during the audit. Preserve its local state.

## Validation already performed

These are results from the earlier work in this conversation, not new checks performed while writing this handoff.

- The app worktree `git diff --check` passed.
- `npm ci --no-audit --no-fund` completed in the app worktree after an initial network timeout.
- App TypeScript check `./node_modules/.bin/tsc --noEmit --incremental false` exited successfully.
- Focused app auth/Homework/consent/pair tests reported 23 passed. A separate direct run of the bracket-path DOCX round-trip test reported 1 passed. A targeted Homework middleware test reported 1 passed.
- The full assignment-jobs test suite reported 61 passed.
- Worker `npm run check` reported passing typecheck and 11 tests.
- Scoped ESLint reported no errors and two warnings in `components/AuthModal.tsx`.
- The full app-host middleware test file had two unrelated root-routing failures. The targeted Homework-entry middleware test passed. Do not report the whole middleware file as green.
- The first production build attempt ran out of memory. A retry with a 6 GiB Node heap compiled successfully, but was interrupted during “Linting and checking validity of types” after the user restricted work to audit and plan. **There is no completed production build result.**
- Local server checks showed the signed-out `/homework` route redirecting to `/homework/sign-in`. A local browser showed the intended two-action sign-in entry after a local change. This is local evidence only; it does not prove deployed or end-to-end behavior.
- No real account sign-in, password reset email, Google/Microsoft completion, Moodle session, worker pair, model request, live job, private storage access, or real DOCX save was verified.

## Bounded implementation and verification plan

Use this as the plan if the user later authorizes implementation. The current task stops at this document.

1. **Preserve and review the local drafts.** Recheck every worktree’s owner, branch, HEAD, and dirty status. Review the app and worker diffs against their current bases. Keep or revise changes only with the user’s later implementation instruction. Do not reuse another task’s worktree or discard changes.
2. **Restore Better Auth availability without losing legacy data.** Trace every custom rate-limit call on email login, OTP, recovery, native auth, pairing, and worker tokens. Use a healthy rate-limit store and fail with a useful, safe response. Keep Better Auth as the provider. Determine which legacy records are still required and prove a data-preserving path before any migration or storage removal.
3. **Complete the Homework auth entry and redirects.** Make the signed-out Homework screen the thermal logo plus Sign in/Create account. Keep login and signup focused. Route successful email and OAuth sign-in directly to `/homework`; remove general onboarding only from the Homework paths that currently invoke it. Verify return URLs, app host, cookies, logout, recovery, and errors without changing unrelated app onboarding.
4. **Authorize normal students by identity and ownership.** Replace the hard-coded admin-only assignment gate with the signed-in student’s own data. Verify unauthenticated requests fail, two students cannot read each other’s assignments/jobs/documents, and workers can access only the scoped job operations.
5. **Make one pairing contract real.** Align the visible Settings/Overview action, app pairing and exchange APIs, worker CLI, instructions, and generated canonical API URL. Pair once with an expiring single-use code; keep the long-lived token on the local worker with owner-only file permissions. Verify expiry, replay rejection, token scope, HTTPS, and no redirect.
6. **Verify consent, queue, and DOCX storage.** Confirm explicit AI consent precedes model use, a job can only reference the student-selected assignment, and app/worker completion contracts match. Verify migration 035, private bucket access, ownership checks, bounded/validated DOCX upload, download, and ETag conflict behavior in the intended environment. Never claim an embedded editor if the path remains external Word-compatible edit plus upload.
7. **Run the actual end-to-end test in the correct Mac app.** Use `/Applications/iBacalao.app` at the intended staging Homework URL. The user enters iBacalao credentials in the app and school credentials in the native Moodle browser. Verify: signed-out entry → email and each advertised OAuth path → direct Homework landing → school bridge → one selected assignment → consent → paired worker → job claim/model draft → Draft Review → DOCX edit/save → other student denied → logout/recovery. Confirm no school password is stored and no Moodle submission occurs. Keep evidence tied to the exact deployed app and worker SHAs.
8. **Release only after the gates pass.** Establish one coherent app/worker pair, hosted CI for the exact worker release commit, exact deployment SHAs, and a real staging end-to-end run. Then follow task branch → `dev` → `staging` → `main`. Show the exact changes and wait for explicit approval before any push, merge/promotion, or deploy.

## Reproduction and handoff commands

These commands are for a later authorized implementation/review session. They inspect local state and do not prove live readiness:

```bash
cd /Users/joaquin/Documents/iBacalao/.worktrees/fix-auth-live-signin-resilience
git status --short --branch
git rev-parse HEAD
git diff --stat
git diff --check

cd /Users/joaquin/Documents/.worktrees/ibacalao-homework-worker-pairing
git status --short --branch
git rev-parse HEAD
```

The app repo’s mandatory preflight passed for the existing owner and continuation task ID before this handoff file was added. Do not copy that owner ID into a new task. The repository’s task guard and promotion rules are in `/Users/joaquin/Documents/iBacalao/AGENTS.md`.

## Current stop condition

The requested audit and plan are complete. The launch decision remains **NO-GO** because sign-in is blocked by the exhausted rate-limit service, ordinary student assignment access is denied on staging/dev, the actual requested screen sequence is not verified, and there is no proven app/worker/DOCX end-to-end run. This file records the plan; it does not authorize continuing implementation or release actions.
