# Homework Agent: implementation and release status

Updated 2026-10-30 after the local implementation pass. Code status below is not release status.

## Previously verified production behavior

- Overview screen: finished steps collapse to a title with a check, "Create connection code" then "Copy prompt for AI", a copy toast. Live on production (PR #207, #208).
- Mac app stays signed in across launches (ProductShell.swift tri-state check).
- Draft pipeline on production: Start work, worker claims the job, the user's own AI CLI writes the draft, the Word file saves, status becomes ready_for_review (PR #210 moved Word storage to Neon, PR #211 fixed the bigint length check). Job 20aef7fa reached ready_for_review.
- Moodle assignment pages are now classified as assignments (lib/school/evidence.ts), Moodle error pages are filtered (lib/school/tableParse.ts).

## Items 1 to 6 from the original handoff

1. **Automatic assignment import: implemented locally, not released.** The bundled watcher now visits one Moodle assignment detail at a time through its local persistent Chromium profile, on a rate limit, with GET/HEAD requests only. It closes each temporary page. It does not use Safari. This follows the app's existing Playwright session architecture rather than the old handoff's proposed WKWebView architecture. No real school session test has been run.
2. **Assignment instructions and details: implemented locally, not released.** Detail extraction reads the brief, supported attachments, due date, and Moodle submission-status row. Enrichment uploads use bootstrap mode so reading details cannot create a homework job. No real assignment round trip has been run.
3. **Worker setup for other Macs: implemented locally, not released.** The app bundles a setup command that pairs privately, selects an installed Codex or Claude CLI, installs or refreshes the app-managed LaunchAgent, and migrates the old worker label without deleting its files. Homework Settings' model name is passed from the claimed job to `--model` for Claude or `-m` for Codex. A clean-Mac install has not been tested.
4. **Learning and Moodle deadlines/submissions: partially implemented locally.** The passive learning window remains open while capabilities are missing or partial. Moodle detail reads now record due-date and submission-status support as partial evidence, so the app no longer labels those reads as wholly missing. Cross-school learning and complete collection coverage remain unverified; assignment pages alone do not establish that every school section was captured.
5. **CAS and Supabase storage: retired from the Homework app.** The native shell now returns legacy product pages, including CAS and Dispatch, to Homework. No CAS storage migration was done because CAS is no longer part of this app. Legacy website CAS API routes remain in the separate website repo and are outside Homework.
6. **`/api/auth/me` 500: code-level cause addressed locally, runtime unverified.** The endpoint calls `remainingReviews`, which runs `REVIEW_BALANCE_SCRIPT` and `WEEKLY_SHELL_BALANCE_SCRIPT`. The Postgres key/value adapter did not translate either script, so it could throw on this request. Single-statement Postgres translations and a concurrent-migration retry are now added. Auth probe failures return 503 instead of a false signed-out response. No production database request was run.

## Verification from this pass

- Worker `npm run check`: typecheck passed and 336 tests passed.
- Worker bundle script created `homework-pair.cjs`, `homework-worker.cjs`, and `homework-setup.cjs` in `/tmp/ibacalao-homework-runtime-final-check`.
- Native `swift build -c debug` passed. `swift test` could not run because this Swift toolchain has no `XCTest` module.
- Website focused tests: 16 passed. Changed website files passed esbuild syntax bundling. The full website typecheck/build was not run because this worktree has no installed dependencies; no dependencies were installed.
- `git diff --check` passed in both repositories.

## Local commit and release state

- Worker repo: `bc2fcaf` (`feat(homework): finish Moodle worker setup flow`) is committed locally on `isolate/desktop-app-and-watcher`.
- Website repo: `c3c60e89e` (`fix(homework): harden status and database balances`) is committed locally on `fix/homework-native-worker`, rebased onto current `origin/dev`.
- Both commits remain local and unpushed. Existing unrelated dirty work in the website primary checkout was preserved.
- The installed `/Applications/iBacalao.app` was not replaced. `swift build` produced a local debug executable, not a packaged or installed app.
- Nothing was pushed, deployed, or published. These changes are not available to users yet.
- Recipes already learned on this Mac in ~/.ibacalao/school/recipes.json came from the old buggy classifier for some pages; new users start clean.

## Not tested

- Full website Next.js build and typecheck.
- Native XCTest suite on a toolchain with XCTest available.
- Production Postgres execution of the new balance SQL.
- Any second user, another school, a clean Mac install, or a real authenticated Moodle assignment-to-draft flow.
- Submitting a draft back to school (by design nothing is submitted).

## Rules to keep

- Pushes: feature branches and dev only. Nothing reaches staging or main except through the PR flow (main only via a main-safe PR, because staging has Student Test files that break the production build guard).
- The user's own AI is the model. Never ask for a provider or key.
- Never print the agent token (agt_...). Never read the Keychain.
- No em dashes in copy.
