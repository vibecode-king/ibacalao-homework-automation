# Spec — `BrandLogo` / `Bundle.module` launch crash

Date: 2026-07-25
Scope: `native/LiveExaminerOverlay` → `com.ibacalao.LiveExaminerOverlay`
Status: **resolved.** F1 applied: the `Bundle.module` fallback branch removed from `BrandTheme.swift` — verified no references remain in `Sources/`. F2 applied: `release_digital.sh` now hard-fails a release build if `Bundle.module` reappears in `Sources/` or `logo.png` is missing from the staged `.app`'s `Contents/Resources` (checks the built artifact, matching the D2/D3 repro in §3).
Incident: `95987040-8D9F-4D31-8ECD-F02A16CB080E`, v1.0.0 build 9, macOS 15.6.1 arm64

---

## 1. What the crash report says

| Field | Value | Reading |
|---|---|---|
| `exception.type` | `EXC_BREAKPOINT` / `SIGTRAP` | A Swift `fatalError`/`precondition` fired **on purpose**. Not memory corruption, not a nil deref. |
| top frame | `_assertionFailure(_:_:file:line:flags:)` | libswiftCore trap handler. |
| frame 1 | `closure #1 in variable initialization expression of static NSBundle.module` | The failing assertion is inside SwiftPM's generated `Bundle.module` initializer. |
| frame 2 | `one-time initialization function for module` + `_dispatch_once_callout` | It's a lazy static — this is its **first ever evaluation**. |
| frame 5 | `specialized static BrandLogo.loadLogo()` | Our code, `BrandTheme.swift:220`. |
| frame 6 | `closure #1 in BrandLogo.body.getter` | Triggered during SwiftUI view body evaluation. |
| bottom | `AppDelegate.setupDashboardWindow()` → `NSWindow.setContentView` → `NSHostingView.viewDidMoveToWindow` | First render of the dashboard window. |
| timing | `procLaunch 12:53:12.6878` → `captureTime 12:53:12.8716` | Dead **184 ms after launch**. App never becomes usable. |
| `procPath` | `/private/var/folders/*/iBacalao.app/...` | Running translocated / from a temp-extracted location (downloaded artifact, not `/Applications`). |

Chain in one line: **dashboard window is created → SwiftUI renders `BrandLogo` → `loadLogo()` touches `Bundle.module` → SwiftPM's generated accessor can't find its resource bundle → `fatalError` → SIGTRAP.**

---

## 2. Root cause (verified against artifacts, not inferred)

`Package.swift:12` declares `resources: [.process("Resources")]`. SwiftPM therefore generates:

```swift
// .build/arm64-apple-macosx/{debug,release}/LiveExaminerOverlay.build/DerivedSources/resource_bundle_accessor.swift
extension Foundation.Bundle {
    static nonisolated let module: Bundle = {
        let mainPath  = Bundle.main.bundleURL.appendingPathComponent("LiveExaminerOverlay_LiveExaminerOverlay.bundle").path
        let buildPath = "/Users/joaquin/Documents/iBacalao/native/LiveExaminerOverlay/.build/arm64-apple-macosx/release/LiveExaminerOverlay_LiveExaminerOverlay.bundle"
        guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else {
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }
        return bundle
    }()
}
```

Three verified facts make this fatal in the field:

1. **The `.bundle` is never shipped.** Neither `build_app.sh` nor `release_digital.sh` copies
   `LiveExaminerOverlay_LiveExaminerOverlay.bundle` into the `.app`. They `cp` individual files
   (`logo.png`, `AppIcon.icns`, `Assets.car`) straight into `Contents/Resources` instead.
   Verified — `build/release/iBacalao.app/Contents/Resources/` contains exactly:
   `AppIcon.icns`, `Assets.car`, `logo.png`. No `.bundle` anywhere in any `.app`.
   → `Bundle(path: mainPath)` **always** returns nil for shipped builds.

2. **The only fallback is a path on the developer's Mac.** Confirmed baked into the shipped binary:
   ```
   $ strings build/release/iBacalao.app/Contents/MacOS/iBacalao | grep LiveExaminerOverlay_
   /Users/joaquin/Documents/iBacalao/native/LiveExaminerOverlay/.build/arm64-apple-macosx/release/LiveExaminerOverlay_LiveExaminerOverlay.bundle
   ```
   → On Joaquin's Mac that path exists, so `Bundle.module` silently succeeds.
   → On **every other machine** it is nil, and the `guard` calls `fatalError`.

   **This is why the bug is invisible to local testing and 100% reproducible for customers.**
   It is not related to App Translocation, code signing, or notarization — those are red herrings.
   Translocation only explains the odd `procPath`; the crash would happen from `/Applications` too.

3. **`BrandLogo` is on the launch path.** `DashboardView.swift:114` renders `BrandLogo(height: 40)`,
   and the dashboard is the content view set in `AppDelegate.setupDashboardWindow()`. So the
   landmine is stepped on during the first frame, every launch, for every non-dev user.

### Current source is *latched*, not fixed

`BrandTheme.swift:220-240` has already been hardened (commit `3106a71ef`, "crash fix"):
the two `Bundle.main` candidates live in their own array literal, and `Bundle.module` sits
behind a separate `if` so it is only evaluated when both `Bundle.main` lookups miss.
The in-code comment correctly documents why: an array literal evaluates every element eagerly,
so putting `Bundle.module` in the same literal detonates it even when an earlier candidate
would have won.

That ordering makes the crash **unreachable while `logo.png` is present in `Contents/Resources`** —
but the `fatalError` is still armed. It re-detonates the moment any of these happen:
- a build/release script stops copying `logo.png` (two independent scripts, both hand-rolled),
- someone reorders `loadLogo()` or inlines the candidates back into one literal,
- any *other* file in the target ever references `Bundle.module`,
- the resource is renamed and only one of the two scripts is updated.

**Conclusion: the reported crash is the pre-`3106a71ef` behaviour. The class of bug is still live.**

### Which build actually crashed — open question (D1)

| Binary | UUID | Version |
|---|---|---|
| crash report `slice_uuid` | `070d1ffd-c8fa-3dd2-bfaf-73ecbd9e9c54` | 1.0.0 (9) |
| `iBacalao.app` (repo root) | `0F193C3F-317B-3A20-A655-81D34167F477` | 1.0 (9) |
| `build/release/iBacalao.app` | `4B5CFB78-F5FB-3AA8-ABDF-E3D63CE82CBE` | 1.0.1 (9) |

The crashing binary matches **neither** local build — it is a distributed artifact (DMG/zip)
not currently in the tree. Must be identified before we can claim "already fixed in 1.0.1".

---

## 3. Diagnosis plan (do this before changing code)

**D1 — Identify the crashing artifact.**
Locate the v1.0.0 build 9 DMG/zip that was actually distributed (download page, Gumroad/store
asset, `build/release` history, git tags). Run `dwarfdump --uuid` on its embedded binary and
match `070d1ffd-c8fa-3dd2-bfaf-73ecbd9e9c54`. Then check whether that build predates `3106a71ef`.
*Exit criterion:* we can state which commit shipped as 1.0.0(9), and whether 1.0.1(9) contains the ordering fix.

**D2 — Reproduce deterministically on this Mac (no second machine needed).**
The whole bug is "the dev-machine fallback path exists." Remove it and this Mac behaves like a customer's:
```bash
cd native/LiveExaminerOverlay
mv .build/arm64-apple-macosx/release/LiveExaminerOverlay_LiveExaminerOverlay.bundle /tmp/leo-bundle-hidden
mv .build/arm64-apple-macosx/debug/LiveExaminerOverlay_LiveExaminerOverlay.bundle   /tmp/leo-bundle-hidden-debug
# then ALSO remove the individual asset so the Bundle.main candidates miss:
mv build/release/iBacalao.app/Contents/Resources/logo.png /tmp/
open build/release/iBacalao.app
```
*Expected on current source:* `fatalError("could not load resource bundle: ...")`, same
`EXC_BREAKPOINT`, same `BrandLogo.loadLogo()` frame. This is the **regression test** for the fix.
Restore all moved files afterwards.

**D3 — Confirm the currently-shipped 1.0.1 is safe.**
With the `.build` bundles hidden (D2) but `logo.png` **restored**, launch `build/release/iBacalao.app`.
*Expected:* dashboard renders with logo, no crash. This proves the latch holds for the shipped build.

**D4 — Sweep for other `Bundle.module` references.**
`grep -rn "Bundle.module" Sources/` — today only `BrandTheme.swift:236`. Confirm nothing else.

---

## 4. Fix plan

Climbing the ladder: *does the `Bundle.module` call need to exist at all?* **No.** Both build
scripts already place `logo.png` directly in `Contents/Resources`, so `Bundle.main` is the real
and only shipping lookup. `Bundle.module` is dead weight that can only ever fatal-error in production.

### F1 — Delete the `Bundle.module` branch (primary fix)
`BrandTheme.swift:220-240`: drop the `if let url = Bundle.module.url(...)` block and its comment.
Keep the two `Bundle.main` candidates and the existing `else` wordmark fallback in `body` —
that fallback already renders `iBacalao` as styled text when no image is found, so a missing
`logo.png` degrades gracefully instead of killing the app.

Net effect: `NSBundle.module` is never referenced → its lazy static never initializes →
the `fatalError` is unreachable **by construction**, not by ordering discipline.

*Diff size:* ~15 lines removed, 0 added.

### F2 — Guard the class of bug, not just this instance
Add to `check_release_ready.sh` (already exists, already runs pre-release):
- fail if `grep -rn "Bundle.module" Sources/` matches anything;
- fail if `iBacalao.app/Contents/Resources/logo.png` is missing from the staged app.

Cheapest possible insurance: two `grep`/`test` lines, and it catches the drift scenarios in §2.

### F3 — Considered and rejected
- **Ship the `.bundle` into the `.app`.** Would also work, but adds a copy step to *two*
  hand-rolled scripts, keeps a `fatalError` in the launch path, and still breaks if either
  script drifts. Strictly more moving parts than F1 for strictly less safety.
- **Drop `.process("Resources")` from `Package.swift`.** Not needed — the accessor is lazy, so
  an unreferenced `Bundle.module` costs nothing. Removing it would also break `Assets.car` /
  icon staging, which reads from `Sources/.../Resources/`. Leave it.

---

## 5. Acceptance criteria

1. D2's repro (both `.build` bundles hidden **and** `logo.png` removed from the `.app`) launches
   to a working dashboard showing the **text wordmark** fallback — no crash, no `EXC_BREAKPOINT`.
2. Same setup with `logo.png` present renders the image logo — no crash.
3. `grep -rn "Bundle.module" Sources/` returns nothing.
4. `check_release_ready.sh` fails if either guard in F2 is violated.
5. Version bumped (1.0.2) and a fresh DMG built; `dwarfdump --uuid` recorded so the next crash
   report can be matched to a commit without guesswork.

## 6. Out of scope

Permissions/TCC, tip-length and reasoning-leak issues, and the overlay `sharingType`
regression are tracked separately in `FIX_PLAN.md` (2026-07-24). This spec covers the
launch crash only.
