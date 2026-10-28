> **This is Marginalia only — one feature, not the Mac app.** The official
> iBacalao Desktop app is the website (`app/` at the repo root), currently
> being wrapped as a native macOS shell that Marginalia will live inside
> (see `docs/app-launch/MAC_APP_STORE_BUILD_PLAN.md` and the root `CLAUDE.md`
> "Mac app terminology" section). A first version of that shell now exists
> (`ProductShell.swift` — webview, sign-in handoff, first-launch gate, offline
> view; the site's own `AppSidebar` provides navigation, no native sidebar).
> Untested against a real signed-in account, and DMG signing/notarizing
> hasn't been run — don't read this file as "the Mac app is shippable."

# Live Examiner Overlay — Status

Last updated: 2026-07-20 (after `./launch_app.sh --rebuild`)

## Goal

**Live Examiner** is a standalone macOS app (BYOK — bring your own key) that coaches students while they write. The product intent:

- **Mac-first native overlay** — floats above any writing app (Google Docs, Word, Pages, etc.).
- **⌘Return hotkey** — student presses ⌘Return when they want feedback on what they just wrote.
- **Reads the draft on screen** — prefers Accessibility APIs (no screen recording); falls back to OCR if needed.
- **One actionable tip** — streams ~200 chars of coaching from the user's chosen LLM.
- **Overlay chat** — follow-up questions in the same floating panel.
- **User's own API keys** — Anthropic, OpenAI, or local FreeLLM. No ibacalao.com account required for the Free BYOK path.
- **No web dependency for BYOK** — calls provider APIs directly from the Mac app.

Future (spec'd, not built): an **IB Specialist** edition that routes through ibacalao.com with subscription, rubric prompts, and usage limits (`docs/DIGITAL_BYOK_PROVIDER_CLIENT_SPEC.md`).

---

## What works now

Grounded in current source + debug log evidence from 2026-07-20:

- **Stable local code signing** — dedicated `LiveExaminer.keychain-db` + self-signed `"LiveExaminer Overlay"` identity. Rebuilds no longer force ad-hoc CDHash churn (see codesign proof below).
- **Build & install pipeline** — `build_app.sh` compiles, signs, and updates `/Applications/LiveExaminerOverlay.app` in place (preserves TCC path association).
- **Carbon ⌘Return hotkey** — no Input Monitoring permission needed (`HotkeyMonitor.swift`).
- **Accessibility-first capture** — reads frontmost app text via AX before attempting screen capture (`AccessibilityTextExtractor.swift`, `FeedbackEngine.swift`).
- **BYOK LLM client** — streams tips and chat to Anthropic, OpenAI, or FreeLLM (`LLMClient.swift`). FreeLLM URL normalization strips `/models/chat` and appends `/v1/chat/completions` correctly.
- **API key persistence** — keys saved to Application Support (`~/Library/Application Support/iBacalao/api-keys.json`, mode 0600); old Keychain items migrated silently, no password dialogs (`KeyStore.swift`).
- **Smarter text diff** — line-set diff + overlap ratio + first-capture forcing reduces false "no new text" (`TextDiff.swift`).
- **Keyable overlay chat** — `KeyableOverlayWindow` + Edit menu enables ⌘V paste and typing in the overlay (`App.swift`, `OverlayView.swift`).
- **Liquid Glass overlay UI** — `NSGlassEffectView` host with dashboard settings window (`GlassBackground.swift`, `DashboardView.swift`).
- **Debug logging** — `~/Library/Logs/LiveExaminerOverlay/live_examiner_debug.log`.

**Last known successful end-to-end (older build, localhost dev server):** OCR captured 3599 chars → streamed tip via `http://localhost:3001/api/live-feedback` (dev stub). That path used the pre-BYOK web API and is superseded by direct LLM calls in current source.

---

## What's missing

Ship blockers and product gaps for a buyable product:

| Gap | Notes |
|-----|-------|
| **Apple Developer ID + notarization** | Current cert is local self-signed (`TeamIdentifier=not set`). Real users need Gatekeeper-trusted distribution. |
| **Distribution DMG / auto-update** | No installer, no Sparkle/update channel. |
| **Polished onboarding** | No first-run walkthrough for Accessibility grant, provider pick, or test connection. |
| **One-permission UX** | Ideal: Accessibility only. Screen Recording still needed for OCR fallback in apps AX can't read (PDF viewers, some web editors). |
| **IB Specialist edition** | Subscription sign-in, server routing, rubric prompts — spec'd but not implemented. |
| **Tip quality validation** | No systematic eval of tip relevance across Google Docs / Word / Pages / PDF. |
| **Chat reliability QA** | Streaming, error recovery, and context window behavior not validated across providers. |
| **Accessibility grant UX** | One-time prompt exists but no in-app progress indicator; user must find System Settings manually. |
| **Windows / cross-platform** | Mac only by design for v1. |
| **Dock icon fills Tahoe plate** *(pending)* | macOS 26 jails `.icns`-only apps in a dark squircle. Prep done (`AppIcon.icon`, `compile_app_icon.sh`, `CFBundleIconName`). Needs Xcode once → `./compile_app_icon.sh` then `./launch_app.sh --rebuild` to ship `Assets.car`. |

---

## Errors / known failures

Concrete issues from debug logs and recent debug work. Current truth as of this build:

### Fixed (in current source)

| Issue | Status |
|-------|--------|
| **Ad-hoc TCC loop** | Fixed — stable `"LiveExaminer Overlay"` signing; rebuild no longer ad-hoc by default. |
| **"Little new text" false tips** | Improved — `TextDiff.textForFeedback()` uses overlap ratio, suffix fallback, first-capture forcing. May still misfire on OCR-only path with static chrome. |
| **Chat not keyable** | Fixed — `KeyableOverlayWindow.canBecomeKey = true` + Edit menu. |
| **FreeLLM wrong URL `/models/chat`** | Fixed — `LLMClient.normalizedOpenAIBase()` strips UI paths; appends `/v1/chat/completions`. |
| **Keychain password dialogs** | Fixed — keys moved to Application Support; Keychain only used for silent migration. |
| **Input Monitoring re-prompts** | Fixed — switched from global event monitor to Carbon hotkey. |

### Still broken or flaky

| Issue | Evidence | Notes |
|-------|----------|-------|
| **ScreenCaptureKit -3801** | Log: `SCStreamErrorDomain Code=-3801 "The user declined TCCs…"` on most recent triggers | SCK fails; app falls back to `legacyFullScreen` OCR. Not fatal if AX works. |
| **`cgPreflight=false`** | Recent starts: `cgPreflight=false path=/Applications/LiveExaminerOverlay.app` | Screen Recording not granted (or stale grant after CDHash change). AX path should still work. |
| **`axTrusted=false` (local build)** | Log 17:19: `axTrusted=false path=…/native/LiveExaminerOverlay/LiveExaminerOverlay.app` | Running repo-local `.app` is a *different binary* than `/Applications` — needs its own Accessibility grant. |
| **`noNewText` still firing** | Log 17:01, 17:26: `stage=noNewText` with SCK -3801 + legacy OCR | Likely OCR path with high line overlap or empty AX; needs repro with Accessibility granted on the *installed* app. |
| **`tooShort` stage** | Log 16:36: `stage=tooShort` | Text extracted but below coaching threshold after diff gating. |
| **Old `/Applications` vs local binary confusion** | User ran `./launch_app.sh --local` or opened repo copy | TCC grants bind to bundle path + CDHash. Always use `/Applications/LiveExaminerOverlay.app` for stable permissions. |
| **Untrusted cert during dev** | `build_app.sh` refuses ad-hoc install to `/Applications` unless `ALLOW_ADHOC=1` | Run `./setup_codesign.sh` once; trust cert in Keychain Access if marked `NOT_TRUSTED`. |
| **Pre-BYOK ibacalao.com errors** | Log 14:10: maintenance bypass rejected on `https://www.ibacalao.com/api/live-feedback` | Old code path; current BYOK build does not call ibacalao.com for tips. |
| **OCR returns 0 chars** | Log 14:10–14:11 with legacy capture | When AX unavailable and screen capture produces unreadable frames. |

### Codesign proof (this build)

```
Identifier=com.ibacalao.LiveExaminerOverlay
CDHash=3097f53bf76b8d66884be04dd2a7d66391f63a8a
Signature size=1739
Authority=LiveExaminer Overlay
TeamIdentifier=not set
```

Not ad-hoc. Not Developer ID.

---

## How to run today

From `native/LiveExaminerOverlay/`:

```bash
# Launch installed app WITHOUT rebuilding (keeps TCC grants)
./launch_app.sh

# Rebuild, sign, install to /Applications, and launch
./launch_app.sh --rebuild

# Launch repo-local build (separate TCC identity — dev only)
./launch_app.sh --local
```

One-time signing setup (if rebuild fails on cert):

```bash
./setup_codesign.sh
# Then trust "LiveExaminer Overlay" in Keychain Access → Trust → Code Signing: Always Trust
```

Emergency ad-hoc (TCC will re-prompt every rebuild):

```bash
swift build && ALLOW_ADHOC=1 ./build_app.sh
```

**Before first tip:**

1. Open **Settings** in the dashboard — pick provider, paste API key, Test Connection.
2. Grant **Accessibility** for iBacalao in System Settings → Privacy & Security → Accessibility.
3. Click **Launch** to show the overlay, focus your document, press **⌘Return**.

Logs: `~/Library/Logs/LiveExaminerOverlay/live_examiner_debug.log`

---

## Honest verdict

This is a **working dev prototype**, not a shippable product. The BYOK architecture is in place — local LLM calls, overlay UI, Carbon hotkey, AX-first capture, stable signing — and the build pipeline succeeds. But end-to-end tip delivery still depends on Accessibility being granted to the *installed* `/Applications` copy, and recent logs show `noNewText` / ScreenCaptureKit -3801 failures when permissions or capture path are wrong.

**Next single priority:** validate one clean end-to-end path on the installed app (Accessibility granted → Google Docs → ⌘Return → streamed tip via FreeLLM or Anthropic). If that works reliably, the next ship blocker is **Developer ID signing + notarization + DMG** for anyone who isn't you.
