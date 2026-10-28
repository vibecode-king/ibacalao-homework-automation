import { test } from "node:test";
import assert from "node:assert/strict";
import {
  jitter,
  nextDelayMs,
  applyOutcome,
  BASE_INTERVAL_MS,
  MIN_INTERVAL_MS,
  MAX_INTERVAL_MS,
  JITTER_RATIO,
} from "../schedule";
import { emptyHealth } from "../types";

const healthy = { consecutiveFailures: 0, authRequired: false };
/** Deterministic "random" at the midpoint — jitter offset is exactly 0. */
const mid = () => 0.5;
const low = () => 0;
const high = () => 0.999999;

test("jitter stays inside the band and is centred on the input", () => {
  assert.equal(jitter(1000, mid), 1000);
  assert.equal(jitter(1000, low), 750);
  assert.ok(jitter(1000, high) <= 1250);
});

test("a healthy platform polls at the base interval", () => {
  assert.equal(nextDelayMs(healthy, {}, mid), BASE_INTERVAL_MS);
});

test("failures back off exponentially", () => {
  const one = nextDelayMs({ ...healthy, consecutiveFailures: 1 }, {}, mid);
  const two = nextDelayMs({ ...healthy, consecutiveFailures: 2 }, {}, mid);
  assert.equal(one, BASE_INTERVAL_MS * 2);
  assert.equal(two, BASE_INTERVAL_MS * 4);
  assert.ok(two > one);
});

test("a bot challenge backs off much harder than an ordinary failure", () => {
  const error = nextDelayMs({ ...healthy, consecutiveFailures: 1 }, {}, mid);
  const challenged = nextDelayMs({ ...healthy, consecutiveFailures: 1 }, { challenged: true }, mid);
  assert.ok(
    challenged > error,
    "retrying quickly after a captcha escalates 'challenged' into 'blocked'",
  );
});

test("backoff is capped", () => {
  assert.equal(nextDelayMs({ ...healthy, consecutiveFailures: 50 }, {}, mid), MAX_INTERVAL_MS);
});

test("never polls faster than the floor", () => {
  assert.equal(nextDelayMs(healthy, { baseMs: 1000 }, mid), MIN_INTERVAL_MS);
});

test("an explicit retry-after is honoured over the heuristic", () => {
  const delay = nextDelayMs(healthy, { retryAfterMs: 45 * 60 * 1000 }, mid);
  assert.equal(delay, 45 * 60 * 1000);
});

test("a retry-after below the floor is still floored", () => {
  assert.equal(nextDelayMs(healthy, { retryAfterMs: 1 }, mid), MIN_INTERVAL_MS);
});

test("a session needing re-auth waits at the ceiling", () => {
  // Polling cannot fix an expired login; only the student can.
  assert.equal(nextDelayMs({ consecutiveFailures: 0, authRequired: true }, {}, mid), MAX_INTERVAL_MS);
});

test("jitter ratio actually spreads two platforms apart", () => {
  const a = nextDelayMs(healthy, {}, low);
  const b = nextDelayMs(healthy, {}, high);
  assert.ok(b - a > BASE_INTERVAL_MS * JITTER_RATIO, "polls must not run in lockstep");
});

// ── health folding ────────────────────────────────────────────────────────

test("a success clears failures and the auth flag", () => {
  const failed = applyOutcome(emptyHealth("managebac"), {
    ok: false,
    reason: "auth_required",
  });
  const recovered = applyOutcome(failed, { ok: true }, "2026-09-07T10:00:00.000Z");
  assert.equal(recovered.consecutiveFailures, 0);
  assert.equal(recovered.authRequired, false);
  assert.equal(recovered.lastSuccessAt, "2026-09-07T10:00:00.000Z");
  assert.equal(recovered.lastError, null);
});

test("challenge count is cumulative and survives a success", () => {
  let health = applyOutcome(emptyHealth("managebac"), { ok: false, reason: "challenged" });
  health = applyOutcome(health, { ok: true });
  assert.equal(
    health.challengeCount,
    1,
    "one good crawl does not disprove that the platform is detecting us",
  );
});

test("consecutive failures accumulate", () => {
  let health = emptyHealth("classroom");
  health = applyOutcome(health, { ok: false, reason: "error", message: "timeout" });
  health = applyOutcome(health, { ok: false, reason: "error", message: "timeout" });
  assert.equal(health.consecutiveFailures, 2);
  assert.equal(health.lastError, "timeout");
});
