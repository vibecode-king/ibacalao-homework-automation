import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Backoff, DailyBudget, limitsFromEnv } from "../src/budget";

const file = () => join(mkdtempSync(join(tmpdir(), "ib-budget-")), "usage.json");

test("daily job cap blocks further claims and survives a restart", () => {
  const path = file();
  const limits = { maxJobsPerDay: 2, maxTokensPerDay: 1_000_000, maxAttemptsPerJob: 2 };
  const first = new DailyBudget(limits, path);
  assert.equal(first.blockedReason(), null);
  assert.ok(first.beginAttempt("a"));
  assert.ok(first.beginAttempt("b"));
  const restarted = new DailyBudget(limits, path);
  assert.match(restarted.blockedReason() ?? "", /daily job cap of 2/);
});

test("token cap blocks once spend reaches the limit", () => {
  const budget = new DailyBudget({ maxJobsPerDay: 50, maxTokensPerDay: 1_000, maxAttemptsPerJob: 2 }, file());
  budget.recordTokens(999);
  assert.equal(budget.blockedReason(), null);
  budget.recordTokens(1);
  assert.match(budget.blockedReason() ?? "", /token cap/);
});

test("one job id gets a bounded number of model attempts", () => {
  const budget = new DailyBudget({ maxJobsPerDay: 50, maxTokensPerDay: 1_000_000, maxAttemptsPerJob: 2 }, file());
  assert.ok(budget.beginAttempt("same"));
  assert.ok(budget.beginAttempt("same"));
  assert.equal(budget.beginAttempt("same"), false);
});

test("counters reset on a new local day", () => {
  let now = new Date(2026, 9, 28, 12);
  const budget = new DailyBudget({ maxJobsPerDay: 1, maxTokensPerDay: 10, maxAttemptsPerJob: 1 }, file(), () => now);
  budget.beginAttempt("x");
  assert.ok(budget.blockedReason());
  now = new Date(2026, 9, 29, 0, 1);
  assert.equal(budget.blockedReason(), null);
});

test("backoff doubles to a ceiling and resets on success", () => {
  const backoff = new Backoff(1_000, 8_000);
  assert.deepEqual([backoff.failure(), backoff.failure(), backoff.failure(), backoff.failure(), backoff.failure()], [1000, 2000, 4000, 8000, 8000]);
  backoff.success();
  assert.equal(backoff.failure(), 1000);
});

test("env limits are clamped and fall back on junk", () => {
  assert.deepEqual(limitsFromEnv({ IBACALAO_MAX_JOBS_PER_DAY: "x", IBACALAO_MAX_TOKENS_PER_DAY: "999999999999" }), { maxJobsPerDay: 20, maxTokensPerDay: 20_000_000, maxAttemptsPerJob: 2 });
});

test("unreadable usage state fails closed instead of resetting to zero", () => {
  const path = file();
  writeFileSync(path, "{not-json");
  const budget = new DailyBudget({ maxJobsPerDay: 20, maxTokensPerDay: 400_000, maxAttemptsPerJob: 2 }, path);
  assert.match(budget.blockedReason() ?? "", /could not be saved/);
  assert.equal(budget.beginAttempt("a"), false);
});

test("a usage file that cannot be written blocks further jobs", () => {
  const dir = mkdtempSync(join(tmpdir(), "ib-budget-ro-"));
  const path = join(dir, "usage.json");
  mkdirSync(path);
  const budget = new DailyBudget({ maxJobsPerDay: 20, maxTokensPerDay: 400_000, maxAttemptsPerJob: 2 }, path);
  assert.match(budget.blockedReason() ?? "", /could not be saved/);
  assert.equal(budget.beginAttempt("a"), false);
});
