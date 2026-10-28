# iBacalao.app — Diagnosis & Fix Plan

Date: 2026-07-24
Scope: `/Applications/iBacalao.app` (source: `native/LiveExaminerOverlay`)
Status: **diagnosis + plan only — no code changed**

---

## 1. Diagnosis

### Root cause: the app has never been granted screen-reading permission, and there is no way to grant it

Runtime evidence from `~/Library/Logs/LiveExaminerOverlay/live_examiner_debug.log`, every trigger today:

```
[Engine] started — axTrusted=false cgPreflight=false path=/Applications/iBacalao.app
[Agent] H-A handleTrigger:noPerms  ["axTrusted": false, "cgPreflight": false]
[Engine] couldNotRead reason=no-capture-perms — falling back to practice tip for demo
```

Neither Accessibility nor Screen Recording is granted. `FeedbackEngine.handleTrigger`
(`FeedbackEngine.swift:211`) bails at the permission gate before it ever touches the screen.

**Why it can't be fixed by the user in-app** — three compounding bugs:

| # | Bug | Location |
|---|-----|----------|
| A | `requestTrustIfNeeded()` and `openSettingsForGrant()` are **dead code — never called anywhere** in the codebase. | `AccessibilityTextExtractor.swift:19,33` |
| B | The one-shot prompt latch is already burned: `defaults read com.ibacalao.LiveExaminerOverlay accessibilityTrustPromptedOnce` → `1`. Even if (A) were wired, `requestTrustIfNeeded` returns early forever. | `AccessibilityTextExtractor.swift:21` |
| C | The dashboard shows a **passive text label**, not a button: `"Enable Accessibility in Settings so Check can read your document."` No action attached. | `DashboardView.swift:141` |

Contributing: TCC grants bind to bundle path + CDHash. The app was renamed
`LiveExaminerOverlay.app` → `iBacalao.app` (STATUS.md still references the old path),
so any historical grant was orphaned, and the burned latch meant it never re-prompted.

### Secondary: "test mode" is masking the failure

`reportCouldNotReadScreen()` (`FeedbackEngine.swift:348`) does not report the error — it
calls `runPracticeTip()`, which feeds the LLM a hardcoded Industrial Revolution paragraph.
The honest `.couldNotRead` message exists directly above it but is unused (marked
`ponytail: recording-demo override`). Result: the app looks like it works and every tip is
about a document the student never wrote. The log shows this firing 7+ times in a row.

### Tertiary: the tip output is unusable even when the LLM succeeds

Provider is `freellm` (local model at `127.0.0.1:3001`). Logged tip lengths: **1110, 1089,
1134, 1037 chars** against a ~200-char target. The model is emitting raw chain-of-thought:

```
*   Role: Concise writing coach.
*   Constraint 1: Detect language and reply in that same language...
*   Weaknesses: The transition from the general context...
```

Occasionally it emits a clean 178-char tip. Nondeterministic. There is no output
post-processing, no length guard, and no reasoning-block stripping in `LLMClient.consumeSSE`.

### Overlay is visible to screen capture ("invisible tab" regression)

`App.swift:146` sets `panel.sharingType = .readOnly`, with a comment saying `.none` was
traded away for demo/marketing recordings. `docs/DIGITAL_PRODUCT_ARCHITECTURE.md` specifies
`.none`. Consequence beyond stealth: `ScreenCapture.captureScreenLegacy()`
(`ScreenCapture.swift:132`) uses `CGDisplayCreateImage`, which does **not** exclude our own
window — so on the legacy fallback path OCR reads the overlay's own tip text back into the
"student's document", poisoning the diff and the next tip.

### Missing features (never built, not broken)

- **Subject detection.** `CoachingSubject` (`AppSettings.swift:23`) is a manual dropdown
  whose `.promptContext` string is appended to the system prompt. Nothing reads the screen
  to infer the subject, and nothing compares inferred vs. selected. Current value is
  `general` (no `coachingSubject` key in defaults), so even the manual context is absent.
- **Anchored feedback format.** `LLMClient.systemPrompt` asks for "one actionable tip in
  about 200 characters." It never asks the model to name *which section* the problem is in
  or *how* to fix it.
- **Spoken output is off.** `spokenTipsEnabled = 0` in defaults. `TipSpeaker` exists and is
  wired (`FeedbackEngine.swift:486`), it's just disabled.

---

## 2. Fix plan

Ordered by dependency. Phases 1–2 restore a working app; 3–5 build the requested behavior.

### Phase 1 — Make permissions grantable (unblocks everything)

1. **Reset the burned latch on version change.** Store the prompted-once flag keyed by
   bundle path + short version instead of a bare bool, so a rename or reinstall re-arms the
   system prompt. Clear the current stale key on first launch of the new build.
2. **Wire the dead code.** Call `requestTrustIfNeeded()` on first launch after the engine
   starts. Replace the passive label at `DashboardView.swift:141` with a real
   **"Grant Accessibility"** button calling `openSettingsForGrant()`, plus a live status row
   (green/red) for Accessibility and Screen Recording that re-polls on window focus.
3. **Manual one-time step for the user** (required regardless of code — macOS won't let the
   app grant itself): System Settings → Privacy & Security → Accessibility → add
   `/Applications/iBacalao.app`. Verify with a rebuild-free `./launch_app.sh` so the CDHash
   doesn't change and void the grant.

**Verification:** log line shows `axTrusted=true`; ⌘Return in Google Docs logs
`source=accessibility len=<N>` instead of `noPerms`.

### Phase 2 — Delete test mode, restore honest failure

4. Change `reportCouldNotReadScreen()` to set `stage = .couldNotRead` with the existing
   `couldNotReadMessage` (already written, just unused). Speak `couldNotReadSpoken` when
   spoken tips are on.
5. Keep `runPracticeTip()` reachable **only** from the explicit Practice button. Remove the
   `ponytail:` demo-override comment block.
6. Restore `panel.sharingType = .none` (`App.swift:146`). Also exclude our own window from
   `captureScreenLegacy()` so OCR can never read our tip back — belt and braces, since the
   legacy path bypasses SCK's window exclusion.

**Verification:** with permissions revoked, ⌘Return shows the "Couldn't understand your
screen" card — never an Industrial Revolution tip. Screenshot of the desktop does not
contain the overlay.

### Phase 3 — Subject detection + mismatch check

7. Add a **classification pass** in `FeedbackEngine.processExtractedText`, before the tip
   request: one short LLM call (or one combined call — see note) that returns structured
   JSON `{ subject, confidence, evidence }` constrained to the `CoachingSubject` case list.
8. Compare against `settings.subject`:
   - match, or selected == `.general` → proceed silently
   - mismatch with high confidence → surface a non-blocking banner in the overlay:
     *"This looks like Chemistry, but you selected Biology — switch?"* with a one-tap switch
     that writes `settings.subject`.
   - low confidence → proceed silently, no nag.
9. Cache the classification per document (keyed off `lastFullText` similarity) so it doesn't
   re-run on every ⌘Return — one classification per writing session, not per keystroke burst.

**Note on cost:** prefer folding classification into the tip call as a two-field JSON
response (`{subject, tip}`) rather than a second round-trip. One request, no extra latency.

### Phase 4 — Rewrite the feedback contract (problem → section → fix)

10. Replace `LLMClient.systemPrompt` with a structured contract:
    - name the **problem**, quote/name the **section** it's in, give the **concrete fix**
    - return JSON `{ problem, section, fix }` so the overlay can render the three parts and
      `TipSpeaker` can speak a natural sentence built from them
    - hard length ceiling per field
11. Inject the (now detected or confirmed) subject's `promptContext` and its IB rubric
    criteria so the "problem" is graded against the real IB rubric, not generic writing advice.
12. Feed section anchoring: AX extraction already walks the accessibility tree
    (`AccessibilityTextExtractor.collectText`) — preserve heading/paragraph boundaries in the
    extracted text instead of flattening to `dedupeAndJoin` lines, so the model can name
    "your Methodology section" rather than "paragraph 3".

### Phase 5 — Output reliability + speech

13. **Strip reasoning leakage** in `LLMClient`: parse the JSON response and discard anything
    outside it; if the model returns prose, fall back to first-sentence extraction with a
    hard char cap. This kills the 1100-char chain-of-thought dumps.
14. **Re-enable spoken tips** (`spokenTipsEnabled = true`) and speak the composed sentence:
    *"In your Methodology section, your variables aren't operationalized — state exactly how
    you measured reaction rate."*
15. **Reconsider the provider.** The local FreeLLM model is the direct cause of the leakage
    and the nondeterminism. Recommend defaulting to Anthropic for the tip path (structured
    output is reliable) and keeping FreeLLM as an opt-in free tier. This is a settings-level
    decision, not a code rewrite.

---

## 3. What to verify before calling it fixed

One clean end-to-end run, logged:

1. Real document open in Google Docs with a Biology IA draft; subject set to Biology.
2. ⌘Return → log shows `source=accessibility len=<N>` with N matching the real draft length.
3. Tip names a real section from that draft, in problem → section → fix form, under the
   length cap, spoken aloud.
4. Switch the doc to a Chemistry draft → mismatch banner appears.
5. Screenshot the desktop → overlay absent from the image.
6. Revoke Accessibility → ⌘Return shows the honest error, not a practice tip.

---

## 4. Open questions for the user

- **Provider:** default the tip path to Anthropic (reliable structured output, costs money)
  or keep FreeLLM as default and fight the leakage with parsing? (Phase 5.15)
- **Mismatch UX:** banner-with-switch (proposed) vs. auto-switch silently vs. block until
  the student confirms?
- **`.none` vs `.readOnly`:** restoring `.none` means the overlay is invisible in your own
  demo/marketing screen recordings. Acceptable, or do you need a debug toggle?
