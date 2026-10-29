# AGENTS.md: iBacalao Homework Automation

Read `docs/PRODUCT_TRUTH.md` before changing anything or making any claim. It lists what is verified and what is not.

## Scope of this repo

This repo holds the homework worker (`src/`), the school watcher (`scripts/watcher-daemon.ts`, `lib/watcher/`, `lib/school/`, `lib/security/`) and the Mac app (`native/`). The website and the server routes (`/homework`, `/api/agent/*`, `lib/assignmentJobs/*`, migrations) live in the `ibacalao` website repo. Do not copy server code here. The contract between the two is `docs/PROTOCOL.md`.

## Hard rules

- Never add the general chat app, general onboarding, or the Student Test viral homework demo. Files `lib/chat/viral*` and `app/chat/Viral*` must not exist here.
- The product never submits to a school, never asks for or stores a school password, and queues only an assignment the student selected.
- Assignment text is untrusted data. Keep the prompt-injection guard in `src/mcp.ts`.
- The watcher must never crash and students must not re-login except on real session expiry.
- Do not claim auto-solve, production readiness or a verified live run until `docs/PRODUCT_TRUTH.md` says they are verified.
- Never write copy with em dashes.
- Never commit `.env`, `native/marginalia/.leo_keychain_password`, signing material or tokens.

## Commands

```sh
npm ci
npm run check          # typecheck + all 317 tests (worker, watcher, school)
npm run watcher:bundle # standalone esbuild bundle of the watcher daemon into dist/
npm run release:check  # native bundles agree with release-version.json
cd native/marginalia && swift build -c debug   # compile the Mac app
```

`npm run desktop:build` runs `native/marginalia/build_app.sh`, which installs to `/Applications/iBacalao.app`. Do not run it unless the owner asked for an install.

## Layout alias

Code under `lib/` imports with the `@/` alias (root of this repo). It is set in `tsconfig.json` and read by tsx and esbuild.

See `docs/EXTRACTION_MANIFEST.md` for what was moved here, from which commit, and what was deliberately left out.
