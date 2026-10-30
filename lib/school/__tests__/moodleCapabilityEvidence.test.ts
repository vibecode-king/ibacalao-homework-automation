import assert from "node:assert/strict";
import { test } from "node:test";
import { applyMoodleCapabilityEvidence } from "../moodleCapabilityEvidence";
import type { SchoolConnectionStatus } from "../types";

const base: SchoolConnectionStatus = {
  sourceKey: "vendor:moodle",
  platformLabel: "Moodle",
  connected: true,
  syncMode: "passive_browser",
  actionReason: "manual_learning_required",
  missingCapabilities: ["assignments", "deadlines", "submissions"],
};

test("successful Moodle detail reads record deadlines and submissions as partial evidence", () => {
  const status = applyMoodleCapabilityEvidence(base, [
    {
      kind: "assignment",
      record: { kind: "assignment", dueAt: "2026-11-03" },
      sourceDetail: "Explain the water cycle.\nSubmission status: No submissions have been made yet",
      updatedAt: "2026-10-30T12:00:00.000Z",
    },
  ]);

  assert.deepEqual(status.missingCapabilities, ["assignments"]);
  assert.deepEqual(status.incompleteCapabilities, ["deadlines", "submissions"]);
  assert.deepEqual(status.capabilities?.map(({ capability, state, method }) => ({ capability, state, method })), [
    { capability: "deadlines", state: "partial", method: "active_crawl" },
    { capability: "submissions", state: "partial", method: "active_crawl" },
  ]);
  assert.equal(status.actionReason, "manual_learning_required");
});

test("partial Moodle evidence clears missing flags but keeps Learn open until coverage is complete", () => {
  const status = applyMoodleCapabilityEvidence({
    ...base,
    missingCapabilities: ["deadlines", "submissions"],
  }, [
    {
      kind: "assignment",
      record: { kind: "assignment", dueAt: "2026-11-03" },
      sourceDetail: "Submission status: Submitted for grading",
      updatedAt: "2026-10-30T12:00:00.000Z",
    },
  ]);

  assert.deepEqual(status.missingCapabilities, []);
  assert.deepEqual(status.incompleteCapabilities, ["deadlines", "submissions"]);
  assert.equal(status.actionReason, "none");
});

test("title-only assignments do not count as learned deadline or submission support", () => {
  const status = applyMoodleCapabilityEvidence(base, [
    { kind: "assignment", record: { kind: "assignment" }, sourceDetail: "Instructions only", updatedAt: "2026-10-30T12:00:00.000Z" },
  ]);
  assert.equal(status, base);
});
