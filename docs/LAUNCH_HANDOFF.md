# Homework Agent: implementation and release status

Updated 2026-10-30 after production promotion. Website deployment is live; this is not Mac-app install or authenticated-flow proof.

## Previously verified production behavior

- Overview screen: finished steps collapse to a title with a check, "Create connection code" then "Copy prompt for AI", a copy toast. Live on production (PR #207, #208).
- Mac app stays signed in across launches (ProductShell.swift tri-state check).
- Draft pipeline on production: Start work, worker claims the job, the user's own AI CLI writes the draft, the Word file saves, status becomes ready_for_review (PR #210 moved Word storage to Neon, PR #211 fixed the bigint length check). Job 20aef7fa reached ready_for_review.
- Moodle assignment pages are now classified as assignments (lib/school/evidence.ts), Moodle error pages are filtered (lib/school/tableParse.ts).

## Items 1 to 6 from the original handoff

1. **Automatic assignment import: worker code is promoted to worker dev/staging/main; website integration is deployed to production.** The bundled watcher visits one Moodle assignment detail at a time through its local persistent Chromium profile, on a rate limit, with GET/HEAD requests only. It closes each temporary page. It does not use Safari. This follows the app's existing Playwright session architecture rather than the old handoff's proposed WKWebView architecture. The installed Mac app has not been replaced and no real school session test has been run.
2. **Assignment instructions and details: worker code is promoted to worker dev/staging/main; website integration is deployed to production.** Detail extraction reads the brief, supported attachments, due date, and Moodle submission-status row. Enrichment uploads use bootstrap mode so reading details cannot create a homework job. The installed Mac app has not been replaced and no real assignment round trip has been run.
3. **Worker setup for other Macs: setup code is promoted to worker dev/staging/main; website integration is deployed to production.** The source bundles a setup command that pairs privately, selects an installed Codex or Claude CLI, installs or refreshes the app-managed LaunchAgent, and migrates the old worker label without deleting its files. Homework Settings' model name is passed from the claimed job to `--model` for Claude or `-m` for Codex. No new Mac package or clean-Mac install has been tested.
4. **Learning and Moodle deadlines/submissions: partially implemented in the worker repo and promoted to its dev/staging/main.** The passive learning window remains open while capabilities are missing or partial. Moodle detail reads now record due-date and submission-status support as partial evidence, so the app no longer labels those reads as wholly missing. Cross-school learning and complete collection coverage remain unverified; assignment pages alone do not establish that every school section was captured.
5. **CAS and Supabase storage: retired from the Homework app.** The native shell now returns legacy product pages, including CAS and Dispatch, to Homework. No CAS storage migration was done because CAS is no longer part of this app. Legacy website CAS API routes remain in the separate website repo and are outside Homework.
6. **`/api/auth/me` 500: code-level cause addressed and deployed to website production.** The endpoint calls `remainingReviews`, which runs `REVIEW_BALANCE_SCRIPT` and `WEEKLY_SHELL_BALANCE_SCRIPT`. The Postgres key/value adapter did not translate either script, so it could throw on this request. Single-statement Postgres translations and a concurrent-migration retry are now added. Auth probe failures return 503 instead of a false signed-out response. The unauthenticated production probe returned 200 with `user: null`; no authenticated production database request was run.

## Verification from this pass

- Worker `npm run check`: typecheck passed and 336 tests passed.
- Worker bundle script created `homework-pair.cjs`, `homework-worker.cjs`, and `homework-setup.cjs` in `/tmp/ibacalao-homework-runtime-final-check`.
- Native `swift build -c debug` passed. `swift test` could not run because this Swift toolchain has no `XCTest` module.
- Website focused tests: 16 passed. `tsc --noEmit` passed. ESLint completed with 72 warnings and zero errors on the main-safe candidate. Vercel dev, staging PR preview, main-safe PR preview, staging deployment, and production deployment reached READY.
- Production deployment for main commit `be63abc8` is READY at `www.ibacalao.com` and `app.ibacalao.com`. Anonymous `/homework` returned 307 to `/homework/sign-in`; that page returned 200. Unauthenticated `/api/auth/me` returned 200 with `user: null`. No authenticated session, real school connection, Moodle import, or draft round trip was exercised.
- GitHub Actions did not start its Typecheck and build job because account payment or spending limits blocked the runner.
- `git diff --check` passed in both repositories.

## Remote promotion and app release state

- Worker repo: `origin/dev`, `origin/staging`, and `origin/main` point to the same handoff update and include the worker feature commit `bc2fcaf`.
- Website repo: PR [#212](https://github.com/vibecode-king/ibacalao/pull/212) merged to `dev` as `6c81f1c`; PR [#214](https://github.com/vibecode-king/ibacalao/pull/214) merged to `staging` as `27e9814`; main-safe PR [#215](https://github.com/vibecode-king/ibacalao/pull/215) merged to `main` as `be63abc8`. The main deployment is READY. The feature branch head is `bc5e45f` (`test(homework): run CAS tests under CJS runner`).
- Existing unrelated dirty work in the website primary checkout was preserved.
- The installed `/Applications/iBacalao.app` was not replaced. `swift build` produced a local debug executable, not a packaged or installed app.
- The website changes are live on production. No new Mac app package was built or installed; the existing `/Applications/iBacalao.app` was not replaced.
- Recipes already learned on this Mac in ~/.ibacalao/school/recipes.json came from the old buggy classifier for some pages; new users start clean.

## Not tested

- Native XCTest suite on a toolchain with XCTest available.
- Production Postgres execution of the new balance SQL.
- Any second user, another school, a clean Mac install, or a real authenticated Moodle assignment-to-draft flow.
- Submitting a draft back to school (by design nothing is submitted).

## Rules to keep

- Pushes: feature branches and dev only. Nothing reaches staging or main except through the PR flow (main only via a main-safe PR, because staging has Student Test files that break the production build guard).
- The user's own AI is the model. Never ask for a provider or key.
- Never print the agent token (agt_...). Never read the Keychain.
- No em dashes in copy.
