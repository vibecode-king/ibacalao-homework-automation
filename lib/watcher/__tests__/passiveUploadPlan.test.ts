import assert from "node:assert/strict";
import { test } from "node:test";
import { passiveUploadPlan } from "../passiveUploadPlan";

test("imports assignments without enabling incremental auto-queue", () => {
  const assignment = { kind: "assignment" as const, sourceRecordId: "a", title: "Work", changeKind: "enriched" as const };
  const retry = { kind: "assignment" as const, sourceRecordId: "c", title: "Retry", changeKind: "unchanged" as const };
  const newAssignment = { kind: "assignment" as const, sourceRecordId: "b", title: "New work", changeKind: "new_entity" as const };
  const message = { kind: "message" as const, sourceRecordId: "m", title: "Notice" };
  assert.deepEqual(passiveUploadPlan([assignment, message, newAssignment, retry], "incremental"), [
    { records: [assignment, retry], mode: "bootstrap" },
    { records: [message, newAssignment], mode: "incremental" },
  ]);
  assert.deepEqual(passiveUploadPlan([], "incremental"), []);
});
