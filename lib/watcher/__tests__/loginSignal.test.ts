import assert from "node:assert/strict";
import { test } from "node:test";
import { loginSignalHoldsSteady, loginWallHoldsSteady } from "../loginSignal";

test("a single true reading is not enough to call it a login", () => {
  assert.equal(loginSignalHoldsSteady([true]), false);
});

test("a transient true reading that reverts to false never counts as steady", () => {
  // Mirrors the real 2026-09-12 bug: clicking 'forgot password' briefly hid
  // the password field (true), then the student went back to the login form
  // (false) — this must never be read as a successful login.
  assert.equal(loginSignalHoldsSteady([false, false, true, true, false, false]), false);
});

test("requires the configured number of CONSECUTIVE true readings, not just that many total", () => {
  const readings = [true, true, false, true, true, true];
  assert.equal(loginSignalHoldsSteady(readings, 4), false); // only 3 consecutive at the tail
  assert.equal(loginSignalHoldsSteady([...readings, true], 4), true); // now 4 consecutive
});

test("a real login that holds steady is accepted once the threshold is reached", () => {
  const readings = Array(6).fill(true);
  assert.equal(loginSignalHoldsSteady(readings), true);
});

test("a login wall must hold the same consecutive bar before we pause the LMS", () => {
  assert.equal(loginWallHoldsSteady([true, true]), false);
  assert.equal(loginWallHoldsSteady(Array(6).fill(true)), true);
  assert.equal(loginWallHoldsSteady([true, true, true, true, true, false]), false);
});
