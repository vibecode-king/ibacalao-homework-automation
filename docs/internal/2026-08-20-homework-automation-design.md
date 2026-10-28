# Homework Automation — MVP Design

Status: approved for implementation planning
Date: 2026-08-20

## 1. Goal

Autonomous homework completion and submission for ibacalao students, starting
with one LMS. Detect new homework → extract it → generate the work → QA it →
enter it → submit it → prove it was submitted — with as little student
involvement as the platform and reliability bar allow.

Non-goal for v1: a packaged desktop installer, support for every LMS with
auto-submit, or defeating platform bot detection.

## 2. Decisions locked in this round

- **v1 LMS with a deterministic, auto-submitting adapter: ManageBac.**
  Matches ibacalao's existing IB user base. Consequence accepted knowingly:
  ManageBac has no self-serve submission API, so verification tops out at
  Tier B (fresh-reload confirmation + stored audit artifact), not a
  server-returned submission ID.
- **All other LMS platforms are reachable in v1** via the persistent-cookie
  session layer and a generic LLM-driven agent path, but that path never
  auto-submits — it stops at review-mode. "Works on all of them" is honest
  because reach (auth) and semantics (submission proof) are different axes;
  cookies solve the first, not the second.
- **Default autonomy on the ManageBac adapter: auto-submit**, not
  review-first. Accepted trade-off: the first false "Submitted ✓" can land
  on a real student's real deadline with no prior reliability data to lean
  on — mitigated by the verification standard in §5 and the hard-stop in §6,
  not eliminated.
- **Hard exception regardless of the auto-submit default:** any assignment
  classified one-attempt, timed, or assessment/summative always routes to
  review, never auto-submits. This is a static classification rule, not a
  confidence threshold, because model confidence and correctness are not the
  same signal.
- **No desktop app shell in v1.** Playwright's `launchPersistentContext`
  gives a bundled, persistent-profile Chromium directly — the "bundled
  browser as app dependency" from the original concept doc, without new
  packaging work. Existing web UI (`/homework`) talks to a local daemon over
  localhost HTTP.

## 3. Architecture

```
┌─ ibacalao web UI (Next.js, existing) ─┐
│  /homework — job list, review queue   │
└──────────────┬─────────────────────────┘
               │ localhost HTTP
┌──────────────▼─────────────────────────┐
│  homework-daemon (Node/tsx)             │
│  ├── session layer (Playwright          │
│  │     launchPersistentContext)         │
│  ├── watcher (jittered poll interval)   │
│  ├── pipeline workers (BullMQ, matches  │
│  │     existing content-engine-worker   │
│  │     pattern)                         │
│  └── SQLite job store (state machine)   │
└──────────────────────────────────────────┘
```

Reused from this repo rather than rebuilt: BullMQ + Upstash Redis (job
queue), `@anthropic-ai/sdk` (generation/QA calls), `@playwright/test`
(already a devDependency, `playwright.config.ts` exists), Neon Postgres
(`lib/db/`) for anything beyond per-job local state, PostHog/Sentry for
telemetry.

## 4. State machine

One row per assignment job, persisted before every transition (crash-safe,
idempotent on restart — a job found in `ACTION_TAKEN` on restart re-checks
observed LMS state before ever re-acting, never blindly replays).

```
DETECTED → EXTRACTED → GENERATED → QA_PASSED → ENTERED
                                                  │
                                    ┌──────────────┴───────────────┐
                              (auto-submit path)            (review required)
                                    │                               │
                              ACTION_TAKEN                  AWAITING_REVIEW
                                    │                               │
                       ┌─────────────┴──────────────┐                └──→ ACTION_TAKEN
                       ▼                            ▼
                SERVER_CONFIRMED              UNVERIFIED
                       │                    (notify student,
                       ▼                     never render "Submitted")
                    VERIFIED ✓
```

Rules enforced in code, not documentation:

- `content_hash` of the assignment is captured at `DETECTED` and re-diffed
  immediately before submit. A change (teacher edited/deleted, deadline
  moved) aborts the job and re-queues a fresh one rather than submitting
  against stale instructions.
- Idempotency key: `(assignment_id, attempt_n)`.
- Only the `VERIFIED` state may render "Submitted ✓" in the UI. This is a
  type-level constraint (see §5), not a UI convention — no code path can
  print the checkmark without an `Evidence` record backing it.

## 5. Verification evidence

```ts
type Evidence =
  | { tier: 'A'; submissionId: string; apiResponse: unknown; at: Date }
  | { tier: 'B'; freshLoadState: 'submitted'; screenshot: string; htmlSnapshot: string; at: Date }
  | { tier: 'C'; reason: string }   // always resolves to UNVERIFIED
```

Tier B's "fresh load" means a genuine new page navigation after submit, not
a read of the post-click DOM state — verifying via the same action path that
performed the action proves nothing, since a client-side-only "Saved" toast
would pass that check even when the server received nothing.

ManageBac in v1 operates at Tier B only. Tier A is reserved for a future
platform with a real submission-confirmation API (Canvas was evaluated and
rejected for v1 per §2, not because it lacks an API, but to keep the IB-user
fit).

## 6. Adapters

```ts
interface AssignmentSource {
  list(): Promise<AssignmentStub[]>
  extract(id: string): Promise<Assignment>   // instructions, attachments, rubric, deadline, taskClass
  enter(id: string, work: GeneratedWork): Promise<void>
  submit(id: string): Promise<void>
  verify(id: string): Promise<Evidence>
}
```

- **ManageBac adapter** — full deterministic implementation of all five
  methods, auto-submit eligible.
- **Generic agent adapter** — implements `list`/`extract` via an LLM-driven
  Playwright agent for any other LMS reachable through the shared session
  layer. `submit` is intentionally unimplemented (throws), so every job on
  a non-ManageBac platform routes to `AWAITING_REVIEW` by construction —
  this is what makes "reachable everywhere, auto-submits on one platform"
  true by design rather than by discipline.
- `taskClass` (one-attempt / timed / assessment / ordinary) is produced
  during `extract()` and consumed by the state machine's hard-stop in §2.

## 7. Generation & QA

Generation via `@anthropic-ai/sdk` (already integrated). QA is a second,
independent model call against a structured, per-assignment checklist
derived from the extracted rubric/instructions — not a freeform "is this
good?" prompt. QA returns a typed pass/fail per criterion (every question
answered, word count in range, required file type present, rubric criteria
covered, citations present if required). Any failing criterion sends the
job back to generation once; a second QA failure routes to
`AWAITING_REVIEW` regardless of the auto-submit setting.

## 8. Testing strategy

A fake LMS: a handful of routes in this Next.js app that mimic ManageBac's
list → detail → upload → submit → confirm flow, deliberately including the
failure modes real platforms produce — a submit button that silently
no-ops, an upload endpoint that 500s after accepting the file, a "Saved"
toast that renders regardless of server state, a page that only reflects
true state after reload. The executor and verifier run against this harness
in Playwright tests. This is the only practical way to test the
false-success guarantee, since a live ManageBac account can't be made to
fail on demand.

**Gate for shipping auto-submit:** zero false "Submitted ✓" results against
the fake LMS's failure-mode cases. If the executor can't clear that against
a harness built specifically to fool it, auto-submit does not ship — the
pipeline falls back to review-mode until it does.

## 9. Milestones

| # | Deliverable | Proves |
|---|---|---|
| M0 | Session layer + fake LMS harness | Persistent login survives daemon restart; harness reproduces the target failure modes |
| M1 | Watcher + ManageBac extractor | New homework detected, normalized, `taskClass` correctly assigned |
| M2 | Generator + QA | Generated output satisfies the structured rubric checklist |
| M3 | Executor + verifier + state machine | Zero false "Submitted ✓" against the fake LMS's lying-toast/silent-failure cases |
| M4 | `/homework` UI, kill switch, auto-submit gating | End-to-end unattended run on ManageBac, review-mode fallback everywhere else |

M3 is the hard gate described in §8, not a soft milestone.

## 10. Explicitly out of scope for this spec

- Packaged desktop installer / native shell beyond the existing
  `native/LiveExaminerOverlay` and `native/marginalia` precedents.
- Auto-submit on any platform other than ManageBac.
- CAPTCHA-solving automation (ping-and-resume only, per original concept
  doc §5).
- Any bot-detection-evasion tooling (e.g. Scrapling-style stealth
  scraping) — explicitly rejected; see prior analysis discussion.
