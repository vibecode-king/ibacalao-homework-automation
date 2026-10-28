# Extraction manifest

Date: 2026-10-28. Source: `vibecode-king/ibacalao` branch `staging` at `9bef05c72`, exported with `git archive` (tracked files only, so no local secrets or ignored files). Base of this branch: this repo's `origin/main` at `d624fc1`.

## Moved here

| What | Paths |
|---|---|
| Mac app | `native/marginalia/`, `native/LiveExaminerOverlay/`, `native/safari-school-bridge/`, `release-version.json` |
| Watcher daemon and its full dependency closure (53 files, computed with an esbuild metafile) | `scripts/watcher-daemon.ts`, `lib/watcher/**`, `lib/school/**`, `lib/security/**` |
| Type-only dependencies the closure needs for `tsc` | `lib/school/types.ts`, `lib/school/uivisionTypes.ts`, `lib/school/freshness.ts`, `lib/dispatch.ts`, `lib/redis.ts` |
| Extra modules whose tests are self-contained | `lib/watcher/mutation.ts`, `lib/school/messageUrgency.ts` |
| Tests that run without the website | `lib/watcher/__tests__/`, `lib/school/__tests__/` |
| Build and release scripts | `scripts/package-watcher-runtime.sh`, `scripts/build-scrapling-helper.sh`, `scripts/watcher-runtime-manifest.mjs`, `scripts/check-release-version.cjs`, `tools/scrapling-repair/` |
| Docs | `docs/homework-agent-setup.md`, `docs/moodle-homework-connection.md`, `docs/internal/*`, `data/public-claims.json` |

## Left in the website repo on purpose

`/homework` pages, `/api/agent/*`, `lib/assignmentJobs/*`, migrations `015`, `035`, `036`, Better Auth, the landing site and downloads page, and everything under `app/chat` and `lib/chat`.

## Deliberately excluded

- The Student Test viral homework demo (`lib/chat/viral*`, `app/chat/Viral*`). Verified absent.
- Server-coupled tests dropped because they import website modules: `platformStrategy`, `freshness`, `schoolTasks`, `planShadow.fixtures`, `platformMap.route`, `serverCapabilityHealth`, `studentReport`, `normalize`, and the matching sources `lib/watcher/platformStrategy.ts`, `lib/watcher/normalize.ts`, `lib/school/schoolTasks.ts`.
- Built DMGs. `public/downloads/digital` stays in the website repo.

## Changes made to copied files

- `scripts/check-release-version.js` renamed to `.cjs` (this repo is `type: module`), and it no longer checks the website `package.json` version.
- `native/marginalia/release_digital.sh`: `DIST_DIR` defaults to `dist/digital` (override with `IB_DIST_DIR`); renamed check script reference.
- Root config: `tsconfig.json` gains the `@/*` alias and `lib`, `scripts` includes. `package.json` gains `fflate`, `pdfjs-dist`, `playwright`, `@upstash/redis` and dev dependencies `esbuild`, `fast-check`, plus scripts `watcher:bundle`, `release:check`, `desktop:build`. `test` now covers worker, watcher and school tests. `.gitignore` covers native build output and the keychain password file.

## Verified

- `npm run check`: typecheck clean, 306 of 306 tests pass.
- `npm run watcher:bundle`: standalone 1.4 MB bundle builds with no website files.
- `swift build -c debug` in `native/marginalia`: build complete.
- `npm run release:check`: passes for 1.0.11 (13).

## Not verified

- `build_app.sh` full run, signing, notarization and DMG packaging from this repo (it installs to `/Applications`, so it was not run).
- Scrapling helper build and watcher runtime packaging (needs network and Python).
- Anything against a live server, school or model.
- `lib/dispatch.ts` and `lib/redis.ts` are copied for types only and pull `@upstash/redis`; trimming them to a type-only module is a follow-up.
