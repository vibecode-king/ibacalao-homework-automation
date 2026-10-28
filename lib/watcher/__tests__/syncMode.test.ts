import { test } from "node:test";
import assert from "node:assert/strict";
import { classifySync, CATCHUP_GAP_MS } from "../syncMode";

// P0.1: confirmed live before this module existed — a first-ever crawl of 3
// pre-existing tasks classified all 3 as "added" with nothing distinguishing
// "this is a baseline" from "this is real new work".

test("no previous fingerprints -> bootstrap, regardless of lastSuccessAt", () => {
  assert.equal(classifySync(false, null), "bootstrap");
  assert.equal(classifySync(false, new Date().toISOString()), "bootstrap");
});

test("has fingerprints, recent success -> incremental", () => {
  const now = Date.parse("2026-09-08T12:00:00.000Z");
  const lastSuccessAt = "2026-09-08T11:45:00.000Z"; // 15 minutes ago
  assert.equal(classifySync(true, lastSuccessAt, now), "incremental");
});

test("has fingerprints, gap at or beyond the threshold -> catchup", () => {
  const now = Date.parse("2026-09-08T12:00:00.000Z");
  const lastSuccessAt = new Date(now - CATCHUP_GAP_MS).toISOString();
  assert.equal(classifySync(true, lastSuccessAt, now), "catchup");
});

test("has fingerprints but no recorded success -> incremental, not a guessed catchup", () => {
  assert.equal(classifySync(true, null), "incremental");
});

test("has fingerprints but an unparseable lastSuccessAt -> incremental, never crashes", () => {
  assert.equal(classifySync(true, "not a date"), "incremental");
});
