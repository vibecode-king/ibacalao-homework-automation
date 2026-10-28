# Audit and debug handoff, 2026-10-28

**Verdict: NOT ready to ship to students.** The worker and watcher code is sound and tested, and the worker-to-server contract is proven. Launch is blocked by items that are not code in this repo (see "Blocking, outside this repo"). This audit covers the committed branch `isolate/desktop-app-and-watcher` (`5605796`). Read `docs/PRODUCT_TRUTH.md` first.

## For the debug agent: start here

```sh
cd /Users/joaquin/Documents/ibacalao-homework-automation
git checkout isolate/desktop-app-and-watcher
npm ci
npm run check                                  # expect: tsc clean, 306 pass, 0 fail
npm run watcher:bundle && ls -l dist/          # expect: watcher-daemon.cjs about 1.4 MB
npm run release:check                          # expect: Release version OK: iBacalao 1.0.11 (13)
cd native/marginalia && swift build -c debug   # expect: Build complete
```

Do not run `npm run desktop:build` (installs to `/Applications`). Do not push, merge or deploy anything. Do not touch the dirty `~/Documents/iBacalao` checkout.

## Verified by running

| Check | Result |
|---|---|
| Typecheck of worker, watcher, school code | clean |
| Tests (worker 11, watcher and school 295) | 306 of 306 pass |
| `npm audit` (prod and dev) | 0 vulnerabilities |
| Watcher daemon standalone esbuild bundle | builds, no website files needed |
| Mac app `swift build -c debug` | builds |
| Secret scan (keys, tokens, private keys) over native, lib, scripts, tools, data, docs | none found |
| Forbidden Student Test demo files | absent |
| **Contract test:** server's real `validateDocxPackage` (from website `staging`) run on the worker's real `buildDocxFromText` output for plain text, Markdown, Unicode and a 5,000 line document | all four accepted |
| Worker upload shape vs server `complete` route | matches: multipart with exactly two parts `document` and `metadata`, DOCX MIME type, `claimToken` of 20 to 500 chars |

## Findings

Severity is for a student launch. File references are in this repo.

### Medium

**M1. MCP prompt delimiter can be closed by the assignment text.** `src/mcp.ts:69-71` wraps the untrusted assignment between fixed markers `<<<ASSIGNMENT_BEGIN` and `ASSIGNMENT_END>>>`. Text containing `ASSIGNMENT_END>>>` ends the data block early and the rest is read as instructions to the host AI, which holds a claim token and may hold other tools. This weakens the prompt-injection guard that `docs/PRODUCT_TRUTH.md` rule 5 depends on. Fix: a random per-claim delimiter, or strip or escape the marker from `job.prompt`. Add a test.

**M2. A rejected completion is never released, and the worker regenerates.** `src/ping.ts:93` sends the DOCX and, on a 4xx (for example the server's 400 `invalid_docx`), throws without calling `/fail`. The job stays leased until the 15 minute lease expires, then is claimed again and a new model call is made. With a persistent rejection this loops and spends the student's own API key each time (cap is 8,000 tokens per draft by default). Needs a bounded retry budget confirmed on the server, or a `/fail` on non-retryable 4xx.

**M3. Mac shell treats every `*.vercel.app` host as the iBacalao origin.** `ProductShell.swift:346`, `:396`, `:710`, `:1140` and `KeyStore.swift:102` use `host.hasSuffix(".vercel.app")`. Anyone can host `https://anything.vercel.app`. In the navigation policy (`:396`) such a link is treated as an own host and can trigger native routing (Dispatch, native feature routes). Fix: pin the exact preview hostnames (or `ibacalao-git-*-vanos-projects-91d1222a.vercel.app`) instead of the suffix.

**M4. Watcher daemon has no process-level crash handlers.** `scripts/watcher-daemon.ts` registers only `SIGINT` and `SIGTERM` (`:1121-1122`) and a `main().catch` (`:1216`). There is no `uncaughtException` or `unhandledRejection` handler. A stray rejection in a Playwright callback ends the process. The Mac supervisor restarts it with a budget and a circuit breaker (`SchoolWatcherService.swift` around `:459-472`), which limits the damage, but the owner's rule is that the watcher must never crash. Add handlers that log, mark the sync failed and keep the loop alive, with a test.

**M5. The worker never runs against a real server, school or model in any test here.** All 306 tests are unit tests. No live pair, claim, draft, complete run exists (see Blocking).

### Low

- **L1. Hostname sent to the server.** `src/ping.ts:20` and `src/mcp.ts:15` build `agentId` from `os.hostname()`, which often contains the student's name. Send a random installed id instead.
- **L2. Model output can set `engine`, `model` and `qaResult` metadata.** `src/agentRunner.ts:35-37` forwards values the model wrote. The server slices strings, but a model can claim an engine or a self-check result. Prefer fixed engine and model from config, and record `qaResult` only as a self-check.
- **L3. DOCX has no `styles.xml`.** `src/docx.ts:29-31` references `Heading1` to `Heading3` and `ListParagraph` but the package defines no styles part, and lists are literal `• ` and `▪ ` characters. The server accepts it (contract test), but Word will likely show headings as plain body text. Not opened in Word here, so this is unverified.
- **L4. HTML guard rejects legitimate text.** `src/docx.ts` and `src/agentRunner.ts` refuse any draft containing a tag such as `<p>` or `<table>`, so a computer science or web design assignment that must quote HTML fails and takes the M2 path.
- **L5. No graceful release on exit.** `src/ping.ts` and `src/mcp.ts` do not trap `SIGINT` or `SIGTERM` to call `/fail` for an active job.
- **L6. `.env` is not loaded by the scripts.** `npm run pair` writes `.env` but `npm start` does not read it (README documents the manual `set -a` step). Node 20.6+ `--env-file` would remove the step.
- **L7. `tsx` is a devDependency but `npm start` needs it.** `npm ci --omit=dev` breaks `start`, `once`, `pair` and `mcp`.
- **L8. Watcher daemon inherits the full parent environment.** `SchoolWatcherService.swift:497` copies `ProcessInfo.processInfo.environment` into the Node child. Pass an allowlist instead.
- **L9. Default model is hardcoded.** `src/agentRunner.ts:48` falls back to `gpt-4o-mini`.
- **L10. Force casts in accessibility code.** `AccessibilityTextExtractor.swift:131,138,143` use `as! AXUIElement`. Low risk, but they are crash points in an app that must not crash.
- **L11. Copied type-only modules pull server code.** `lib/dispatch.ts` and `lib/redis.ts` (and `@upstash/redis`) are in this repo only so `tsc` passes. Replace with a type-only module.
- **L12. Swift tests were not run.** `swift test` fails with `no such module 'XCTest'` on this machine (Command Line Tools without the Xcode toolchain). `native/marginalia/Tests` (2 targets) is unexecuted.

### Observed good (keep)

HTTPS only with loopback exception, no URL credentials, redirects refused and responses size-limited (`src/network.ts`, `src/client.ts`); pairing token format check and owner-only `.env` (`src/pair.ts`); local CLI execution disabled (`src/agentRunner.ts`); `fail` and `complete` use job-scoped claim tokens; `.env` and keychain password file are git-ignored; the watcher never types or stores a school password (`lib/watcher/session.ts`, `uivisionNavigator.ts`); school URLs are validated to HTTPS (`SchoolWatcherService.swift` `validateSchoolURL`); restart budget and circuit breaker exist for the daemon.

## Blocking, outside this repo

1. **No live end-to-end run has ever succeeded.** Needed: pair, claim, draft, complete, `ready_for_review` on staging with a consenting test account (`docs/PRODUCT_TRUTH.md`).
2. **Website production `main` is restored to `8d9838ca5` and does not contain Better Auth or the OAuth callback fix.** Google sign-in is still unproven in the installed app. Promotion must be a main-safe cherry-pick set, not a staging merge (the first cherry-pick `0d9059c2b` conflicts).
3. **Sign-in infrastructure:** the audit recorded the Upstash Redis request quota exhausted (HTTP 500 and 503 on login and OAuth start), and a staging admin-email check (`admin@ibacalao.com`) that returns 403 to normal students.
4. **Installed `/Applications/iBacalao.app` is a debug build from restored `main`** (no `/homework`, no Better Auth), and its `ShellBaseURLOverride` is currently `https://app.ibacalao.com`. The readiness handoff names the staging `/homework` route as the target. Decide which URL it should use before any sign-in test.
5. **Release:** no signed and notarized build of this code, no clean-Mac download test, repo still private while the README and website hero say open source.
6. **Auto-queue on arrival and an agent daemon do not exist.** Do not claim "entirely automatic".

## Not audited

Full line-by-line review of `lib/school/*` and the 5,000+ line `scripts/watcher-daemon.ts` was by grep and tests only. The 78 Swift files under `native/marginalia/Sources` were reviewed for process spawning, trust boundaries, entitlements and crash patterns only. `native/LiveExaminerOverlay` and `native/safari-school-bridge` were not reviewed beyond building. Server routes (website repo) were checked only for the claim and complete contract.

## Suggested order for the debug pass

1. M1, M2, M4 (small, testable, in this repo).
2. M3 and L8 (Mac app).
3. Blocking items 1 to 4 with the owner present.
