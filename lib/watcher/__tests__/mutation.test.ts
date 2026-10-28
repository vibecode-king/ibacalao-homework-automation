import assert from "node:assert/strict";
import { test } from "node:test";
import { shouldRecordSchoolHistory } from "../mutation";
import type { ScrapedRecord } from "../types";

function record(changeKind?: ScrapedRecord["changeKind"]): ScrapedRecord {
  return { sourceRecordId: "a1", kind: "assignment", title: "Biology", ...(changeKind ? { changeKind } : {}) };
}

test("progressive enrichment updates current state without manufacturing school history", () => {
  assert.equal(shouldRecordSchoolHistory(record("enriched")), false);
  assert.equal(shouldRecordSchoolHistory(record("unchanged")), false);
  assert.equal(shouldRecordSchoolHistory(record("new_entity")), true);
  assert.equal(shouldRecordSchoolHistory(record("source_changed")), true);
});

test("legacy watcher records without mutation metadata retain event behavior", () => {
  assert.equal(shouldRecordSchoolHistory(record()), true);
});
