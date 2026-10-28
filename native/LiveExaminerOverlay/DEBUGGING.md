# LiveExaminerOverlay — debugging handoff

Native macOS overlay app (SwiftPM, no Xcode project) that captures the screen on
Ctrl+Return, OCRs it, diffs against the last capture, and sends only the new
text to iBacalao's existing `/api/live-feedback` endpoint for AI feedback.

## Current symptoms (as reported by the user, unresolved)

1. **Always shows "No new writing detected"**, regardless of what was actually
   typed on screen — not intermittent, every single trigger.
2. **macOS keeps re-asking for permissions** (Input Monitoring / Screen Recording)
   even after the user has granted them before.
3. Separately (may or may not be related): the app has intermittently hung at
   process launch, stuck inside `_dyld_start` before `main()` ever runs —
   confirmed via `sample <pid>` showing the whole call stack pinned there. This
   was *sometimes* fixed by re-signing with `--entitlements` (see below), but
   recurred on later rebuilds even with the identical signing command — i.e.
   it is not fully understood and may be OS/Gatekeeper state, not app code.

**Note:** This app does **not** use Accessibility (`AXIsProcessTrusted`). Only
**Input Monitoring** (global hotkey) and **Screen Recording** (screen capture)
matter. If macOS shows an Accessibility entry, it is unrelated to this app's
core flow — do not chase it unless something else breaks.

## Already implemented (do not re-add)

These were the original root-cause fixes for "blank capture looks like no new
text." They are **in the codebase now**:

- `ScreenCapture.isAuthorized` — wraps `CGPreflightScreenCaptureAccess()`.
- `ScreenCapture.requestPermission()` — wraps `CGRequestScreenCaptureAccess()`;
  only called from the "Grant…" button in `ContentView`, never at launch
  (same pattern as `HotkeyMonitor.requestPermission()`).
- `FeedbackEngine.screenRecordingTrusted` — polled every 2s alongside
  `hotkeyTrusted`; logged at start: `[Engine] screen recording authorized at start: …`
- `FeedbackEngine.handleTrigger()` — if Screen Recording is not granted, shows
  `.error("Screen Recording permission not granted — click Grant… below.")`
  **before** capture, not `.noNewText`.

If symptom #1 persists **while the UI shows both permissions granted**, the
bug is downstream of permission checks — use the decision tree below.

## Debugging "No new writing detected" (symptom #1)

The UI string comes from `FeedbackStage.noNewText` in two **distinct** code
paths in `FeedbackEngine.handleTrigger()`:

| Path | Condition | Log lines to look for |
|------|-----------|------------------------|
| **A — empty OCR** | `currentText.isEmpty` after OCR | `[Engine] OCR text length: 0` |
| **B — empty diff** | OCR non-empty but `TextDiff.newSuffix` returns `""` | `OCR text length: N` (N>0), then `[Engine] delta length: 0` |

Other outcomes that are **not** "No new writing detected":

| Symptom | Cause |
|---------|-------|
| Nothing happens on Ctrl+Return | Input Monitoring not granted → hotkey never fires (check `[Hotkey] Ctrl+Return detected`) |
| Silent no-op | Not signed in → `handleTrigger` returns early (`signedIn=false` in trigger log) |
| Red error text | Screen Recording denied, capture nil, OCR failure, API error, rate limit |
| Tip / mismatch / too short | Pipeline succeeded |

### Path A — empty OCR (permission granted)

If `[Engine] screen recording authorized at start: true` but OCR length is
always 0:

- Capture may still be blank or unreadable despite `CGPreflightScreenCaptureAccess()`
  returning true (TCC stale grant, wrong display, etc.). Check
  `[Engine] captured image WxH` — a tiny or zero-sized image is suspicious.
- Vision may fail to read the foreground app's text (low contrast, custom fonts,
  non-Latin scripts, PDF viewers, etc.).
- Full-screen capture includes menu bar, dock, and other windows; OCR noise is
  possible but usually still yields *some* text — persistent zero length points
  to capture or OCR failure, not diff logic.

### Path B — empty diff (OCR works, nothing "new")

`TextDiff.newSuffix` is a **line-set diff**: lines in the current capture that
were not in the previous capture, in current order. Empty delta means every
non-empty OCR line was already seen.

Common causes:

- First trigger after launch with static screen chrome only (menu bar, dock
  labels) — those lines become `lastFullText`; student text that OCR reads as
  the same line on the next trigger produces delta 0.
- OCR inconsistency between captures (same visual text, different line breaks or
  whitespace trimming → line appears "new" once, then never again — or the
  reverse, never appears as new).
- Student hasn't actually added new *lines* since the last check (edits in
  place on an existing line may not register as a new line).

**Primary hypothesis if permissions are confirmed granted:** start with Path B
(logs show OCR length > 0, delta length 0). Path A (blank capture without
permission denial UI) is the fallback if OCR length is always 0.

## Root cause of the permission churn (symptom #2)

The app is signed **ad-hoc** (`codesign --sign -`), which has no stable Team
Identifier. TCC (macOS's permission database) treats ad-hoc-signed binaries
less reliably than certificate-backed signatures — grants from one build may
not carry over to the next rebuild.

**Current signing command** (`build_app.sh`):
```bash
codesign --force --deep --sign - --identifier com.ibacalao.LiveExaminerOverlay \
  --entitlements .build/arm64-apple-macosx/debug/LiveExaminerOverlay-entitlement.plist \
  LiveExaminerOverlay.app
```

The binary is copied from `.build/debug/LiveExaminerOverlay`; entitlements come
from `.build/arm64-apple-macosx/debug/LiveExaminerOverlay-entitlement.plist`
(SwiftPM layout — paths differ by design).

**Fix:** create a local self-signed code-signing certificate once via Keychain
Access (Certificate Assistant → Create a Certificate → type: "Code Signing"),
then sign with that identity instead of `-`:
```bash
codesign --force --deep --sign "Your Cert Common Name" \
  --identifier com.ibacalao.LiveExaminerOverlay \
  --entitlements .build/arm64-apple-macosx/debug/LiveExaminerOverlay-entitlement.plist \
  LiveExaminerOverlay.app
```
This should make TCC grants persist across rebuilds instead of resetting.

**Also worth checking:** System Settings → Privacy & Security → **Input
Monitoring** and **Screen Recording** (not Accessibility). Look for duplicate
entries for "LiveExaminerOverlay" vs "Live Examiner Overlay" — `CFBundleName` and
`CFBundleDisplayName` in `Info.plist` differ, which *may* cause macOS to list
the app twice (unverified). Remove stale entries, rebuild with certificate-based
signing, launch once, grant fresh.

## The `_dyld_start` hang (symptom #3, lower priority)

Observed via `sample <pid>`:
```
Call graph:
    N Thread_xxxxx: Main Thread   DispatchQueue_<multiple>
      N _dyld_start  (in dyld) + 0
```
Process is alive (`ps`) but never reaches `main()` — no window, no logs.

- Reliably reproduced when the `.app` was signed **without** `--entitlements`
  (SwiftPM generates `LiveExaminerOverlay-entitlement.plist` with
  `com.apple.security.get-task-allow`; omitting `--entitlements` strips it).
- Intermittently afterward with the correct command — possibly stale Gatekeeper
  (`syspolicyd`) cache from rapid ad-hoc rebuild cycles.

**If this recurs:** (1) `sudo killall syspolicyd` then relaunch, (2) reboot,
(3) Apple Developer ID signing for a stable long-term identity.

Always launch via `open LiveExaminerOverlay.app`, not by executing the binary
inside the bundle directly.

## API / maintenance mode

- `LiveFeedbackClient.swift` POSTs to `https://ibacalao.com/api/live-feedback`
  with `?bypass=<MAINTENANCE_BYPASS_TOKEN>`.
- Production maintenance gating is intentional (`middleware.ts`:
  `MAINTENANCE_ALLOWED_PREFIXES` does not include `/api/live-feedback`;
  `hasBypass()` is the sanctioned escape hatch).
- **`MAINTENANCE_BYPASS_TOKEN` is read from the environment at runtime**, not
  baked into the `.app`. Set it before launch:
  ```bash
  export MAINTENANCE_BYPASS_TOKEN='…'   # same value as Vercel Production env
  open LiveExaminerOverlay.app
  ```
  Without it, API calls fail in maintenance mode — symptom is red error / API
  logs with non-2xx status, **not** "No new writing detected."

## Architecture reference

- `App.swift` — entry, floating window (`sharingType = .none`), wires
  `AuthManager` + `FeedbackEngine`.
- `AuthManager.swift` / `LoginView.swift` — session cookie via `WKWebView` login.
- `HotkeyMonitor.swift` — Ctrl+Return; **Input Monitoring** only
  (`IOHIDCheckAccess` / `IOHIDRequestAccess`), not Accessibility.
- `ScreenCapture.swift` — `CGPreflightScreenCaptureAccess`, whole-display
  `CGDisplayCreateImage(CGMainDisplayID())`.
- `OCR.swift` — Vision `VNRecognizeTextRequest`, lines joined with `\n`.
- `TextDiff.swift` — line-set diff via `newSuffix(previous:current:)` (name is
  historical; behavior is **not** prefix/suffix).
- `FeedbackEngine.swift` — trigger → permission check → capture → OCR → diff → API.
- `DebugLog.swift` — `dlog()` → `NSLog` + `/tmp/live_examiner_debug.log`.
- `build_app.sh` — **required** for a real `.app` bundle identity; bare
  `swift run` does not register TCC grants reliably.

## Diagnostic checklist

1. **Launch healthy?** `pgrep -fl LiveExaminerOverlay`, then `sample <pid>`.
   Expect `-[NSApplication run]` / `nextEventMatchingMask`, not `_dyld_start`.
2. **Tail the log:** `tail -f /tmp/live_examiner_debug.log` through one
   Ctrl+Return cycle. Map output to Path A vs B above.
3. **Permissions in log:** `[Engine] screen recording authorized at start:` and
   `[Hotkey] input monitoring at start:` (both logged at startup).
4. **Permissions in UI:** orange banners for Input Monitoring / Screen Recording
   should disappear after granting (polled every 2s).
5. **System Settings:** Input Monitoring + Screen Recording only; remove
   duplicate/stale entries; re-grant after certificate signing if needed.
6. **Rebuild:** run `./build_app.sh` (or equivalent: `swift build`, copy binary
   to `LiveExaminerOverlay.app/Contents/MacOS/`, copy `Info.plist`, re-codesign
   with `--entitlements`) → `open LiveExaminerOverlay.app`.
7. **API token:** confirm `MAINTENANCE_BYPASS_TOKEN` is exported if production
   is in maintenance mode.
