# Platform verification, 2026-10-31

## macOS release

- Built local release artifact `native/marginalia/build/release/iBacalao-Digital-1.0.11-arm64.dmg` from the current checkout.
- Apple notarization submission `6333669a-1544-45fd-9597-4a61b4973c89` completed with status `Accepted`.
- Stapled and validated the ticket with `xcrun stapler`; `hdiutil verify` reported a valid image checksum.
- Mounted the image read-only and ran `spctl --assess --type execute` on the contained app. Gatekeeper returned `accepted`, source `Notarized Developer ID`.
- This verifies Gatekeeper acceptance on the build Mac. It does not verify a clean Mac download, installation, first launch, or a public release.

## Worker workflow

- The installed `com.ibacalao.homework-agent` LaunchAgent was running.
- Its local log recorded two claimed jobs saved as `ready_for_review`, followed by connected/idle polling. The worker log also states that the school platform was not changed.
- This verifies worker claim, draft generation, and completion on the configured machine. It does not verify first-time pairing, a new user's school login, or a student opening/reviewing the saved documents.

## Windows

- The native SwiftUI desktop app and bundled runtime target macOS Apple Silicon.
- Added `scripts/setup-homework-worker-windows.ps1` so a Windows user can pair the Node worker, secure the local `.env`, and run it at sign-in through Task Scheduler while using Homework in Edge or Chrome.
- `npm run check` passed typecheck and 339 tests on the build Mac.
- Added a Windows CI job for the Node checks and PowerShell parser. This checkout has not yet run that job or exercised Task Scheduler on a Windows machine.
