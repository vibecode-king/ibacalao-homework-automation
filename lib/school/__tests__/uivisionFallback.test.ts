import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  goalsForFallback,
  logNavigationAttempt,
  startNavigationAttempt,
  uivisionFallbackEnabled,
} from "../uivisionFallback";

test("kill switch defaults off", () => {
  assert.equal(uivisionFallbackEnabled({ ...process.env }), false);
  assert.equal(uivisionFallbackEnabled({ ...process.env, IBACALAO_SCHOOL_UIVISION_FALLBACK: "0" }), false);
  assert.equal(uivisionFallbackEnabled({ ...process.env, IBACALAO_SCHOOL_UIVISION_FALLBACK: "1" }), true);
});

test("only runs when actionReason is manual_learning_required", () => {
  assert.deepEqual(goalsForFallback({ actionReason: "none" }, ["assignments"]), []);
  assert.deepEqual(goalsForFallback({ actionReason: "reauth_required" }, ["assignments"]), []);
  assert.deepEqual(
    goalsForFallback({ actionReason: "manual_learning_required" }, ["assignments", "grades"]),
    ["assignments", "grades"],
  );
});

test("logs one bounded JSONL line per attempt, never page text or credentials", () => {
  const dir = mkdtempSync(join(tmpdir(), "uivision-log-"));
  const file = join(dir, "uivision-navigation.jsonl");
  try {
    const attempt = startNavigationAttempt("assignments");
    logNavigationAttempt(attempt, { goal: "assignments", state: "reached_candidate", observedUrl: "https://school.example.com/a" }, file);
    const lines = readFileSync(file, "utf8").trim().split("\n");
    assert.equal(lines.length, 1);
    const parsed = JSON.parse(lines[0]);
    assert.equal(parsed.correlationId, attempt.correlationId);
    assert.equal(parsed.goal, "assignments");
    assert.equal(parsed.state, "reached_candidate");
    assert.equal(parsed.observedUrl, "https://school.example.com/a");
    assert.equal("pageText" in parsed, false);
    assert.equal("html" in parsed, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
