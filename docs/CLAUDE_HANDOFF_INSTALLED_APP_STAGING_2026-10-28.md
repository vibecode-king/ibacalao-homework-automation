# Claude handoff: installed iBacalao app on staging

Date: 2026-10-28

## Objective

Continue the owner's existing task in the **installed Mac app**, using the app's existing connection to the iBacalao website's **staging deployment**. Use the existing Homework authentication flow and backend. Test the real Homework flow against Moodle at https://moodle.colstephenhawking.edu.ec/my/. The requested Git promotion is the website repo's dev → staging → main path, limited to this task.

Do not make the owner repeat the task. The exact owner messages are quoted under “Owner's instructions.”

## Owner's instructions, quoted from this conversation

- **[U1] Staging is the target:** “that "stqgin" flow is the main one”
- **[U2] Use the working sign-in and do not use the owner's screen:** “work on the background why are you using my screen that is not the auth screen that works ive laeryd explained it a million times i think why do you made anotherone if we alredy had one”
- **[U3] Use the Cloudflare-backed existing flow:** “or if its easy just set up the backend of the one that works with cloudflare there simple as fuckiugn that”
- **[U4] Test platform:** “the the platform to test is this one https://moodle.colstephenhawking.edu.ec/my/”
- **[U5] Exact scope and branch request:** “commit dev stagin main i swear to god if i see something i didnt asked or like oooo myyyyy gooooooood ive told you a million times i dont think you need a million and one”
- **[U6] Target clarification:** “ok but its the installed app pointing to that repo and branch”
- **[U7] Restart instruction:** “uh do it”
- **[U8] This handoff request:** “read this again im tired of making hnadoffs of whats wrong this is hte last handoff for claude a great handoff with cites of what i fuckign said im fuckign itde of you ask if you dont fuckign get it”

## Correct interpretation

The target is the **installed native app**, whose web shell is already configured to load the staging Vercel deployment. Do not treat the separate native-source GitHub repo as the website deployment or backend.

The existing sign-in route is /login?redirect=%2Fhomework. It is the website's existing sign-in UI and server flow. Do not make another auth screen, another gate, a separate auth service, or a Cloudflare Worker. Cloudflare is currently used for Turnstile; the website server handles authentication.

The owner wants real end-to-end verification in the installed app and the existing staging service, followed by the requested website-repo promotion. Do not substitute a browser-only test or a page-load check for authenticated app and Moodle verification.

## Verified live and installed-app state

- Installed app: /Applications/iBacalao.app, build 13 (version 1.0.11).
- Its saved ShellBaseURLOverride is https://ibacalao-git-staging-vanos-projects-91d1222a.vercel.app.
- Its saved ShellLaunchPathOverride is /login?redirect=%2Fhomework.
- The app was restarted after the owner said “uh do it.” The app process was observed running afterward. No screenshot or visual inspection was performed.
- The installed binary supports ShellLaunchPathOverride. Native source permits it only for the trusted iBacalao Vercel preview pattern. See native/marginalia/Sources/LiveExaminerOverlayCore/ProductShell.swift:1150-1166 and NativeHostPolicy.swift:3-11.
- Cloudflare's existing managed Turnstile widget “ibacalao” now allows both ibacalao.com and the staging Vercel hostname. Cloudflare API readback returned HTTP 200 and confirmed the domains. This verifies widget configuration only; it does not prove an authenticated login.
- Live staging route checks: GET /login?redirect=%2Fhomework returned HTTP 200; GET /api/auth/get-session returned null with HTTP 200; POST /api/auth/login with an empty body returned HTTP 401 invalid_credentials; GET /api/homework/assignments without a session returned HTTP 401 Unauthorized. These prove route reachability and unauthenticated rejection only.
- No authenticated sign-in, Moodle assignment import, worker pairing, draft creation, or draft round trip has been verified. Do not claim an end-to-end pass.

## Repository and commit state

There are two different repositories:

1. **Website and backend:** /Users/joaquin/Documents/iBacalao. This is the repo with the website auth, Homework routes, and the dev → staging → main promotion flow.
2. **Worker and native Mac app source:** /Users/joaquin/Documents/ibacalao-homework-automation. Its AGENTS.md says the website and server routes stay in the website repo; see docs/PRODUCT_TRUTH.md:36-48.

The previous assistant mistakenly pushed native-source commit b869457529d7b705fbdc96f250177a301f0375cb, “fix(desktop): open staging Homework sign-in,” to **ibacalao-homework-automation origin/main**. That is not a deployment of the website staging branch and does not satisfy the owner's dev/staging/main request. Do not describe it as website promotion. The native repo has no origin/staging branch; its origin/dev is 5b2d73e and origin/main is b869457. Its local dev also contains three unpushed commits. Do not push those unrelated commits.

The native source branch is isolate/desktop-app-and-watcher, with the route change in:

- native/marginalia/Sources/LiveExaminerOverlayCore/ProductShell.swift
- native/marginalia/Tests/LiveExaminerOverlayCoreTests/NativeWorkspaceNavigationTests.swift

The native repo's pre-existing untracked native/marginalia/iBacalao.app/ bundle was preserved and must stay out of commits.

The website checkout is currently on chore/next-15-upgrade with 2,960 dirty entries. No website files were changed in this task. Its scripts/agent-preflight.sh is missing from the checked-out tree. The website AGENTS.md requires an isolated task worktree, passing preflight before edits, then task branch → dev → staging → main; it also forbids sweeping unrelated dirty work into commits. The older audit handoff explicitly says not to touch the dirty website checkout (docs/AUDIT_AND_DEBUG_HANDOFF_2026-10-28.md:17). Do not bypass the missing guard or modify that dirty checkout. Find a valid existing clean task worktree/guard path first.

The old audit handoff's statement that the installed app uses https://app.ibacalao.com is stale. Its lines 68-75 are historical audit state. Current installed preferences above were read directly after the app restart and supersede that statement.

## Required end-to-end scope and boundaries

1. Use the installed app with its existing staging URL and the existing /login?redirect=%2Fhomework flow. Do not use the owner's screen or create a substitute auth page.
2. Confirm the actual authentication path and current Turnstile behavior from the staging deployment. Widget domain configuration alone is not proof that the app renders or validates Turnstile.
3. Use the owner-specified Moodle site. Moodle auto-sync is not enabled; the product truth says Moodle uses a manual import fallback (docs/PRODUCT_TRUTH.md:38-44). The student selects one assignment.
4. If an authenticated test account/session is available, verify one real flow through the existing worker to a reviewable draft. The student reviews and submits manually; never auto-submit to Moodle. Never request or store the Moodle password. See docs/PRODUCT_TRUTH.md:36-48 and 58-63.
5. Report each stage separately as verified or unverified: installed-app route, sign-in, Moodle import, pairing, claim, model draft, server completion, draft review.
6. Promote only the requested website changes through the website repo's dev → staging → main process. Preserve every unrelated dirty change. Do not push or merge a branch whose exact diff has not been reviewed.
7. Do not claim the task is complete until the real installed-app path is verified. Do not ask the owner to restate this handoff. If a required account action is unavailable, finish all independent work and state the precise blocker only.

## Source references

- Audit and prior findings: docs/AUDIT_AND_DEBUG_HANDOFF_2026-10-28.md:1-18, 68-75, 98-106.
- Product architecture, Moodle manual-import boundary, and unverified live E2E: docs/PRODUCT_TRUTH.md:36-48, 58-67.
- Native route selection and preview-only launch override: native/marginalia/Sources/LiveExaminerOverlayCore/ProductShell.swift:27-49, 1150-1166.
- Base URL preference: native/marginalia/Sources/LiveExaminerOverlayCore/LLMClient.swift:169-186.
- Trusted Vercel preview host pattern: native/marginalia/Sources/LiveExaminerOverlayCore/NativeHostPolicy.swift:3-11.
- Website branch/worktree/promotion rules: /Users/joaquin/Documents/iBacalao/AGENTS.md, especially “Mandatory preflight,” “Worktree isolation,” and “Promotion workflow.”
