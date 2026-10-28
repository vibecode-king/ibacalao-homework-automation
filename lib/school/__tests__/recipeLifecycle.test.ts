// A promotion that turns out wrong must be undone, and never repeated.

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  detectRecipeRegression,
  fieldCompleteness,
  isQuarantinedVersion,
  rollbackToLastKnownGood,
} from "../recipeLifecycle";
import { stageRepairCandidate, type StoredSchoolRecipe } from "../recipeStore";
import type { ScrapedRecord } from "../../watcher/types";
import type { SchoolRecipe } from "../types";

const signature = { tag: "article", classTokens: ["card"], attributeNames: [], childTags: ["h3"] };

function record(over: Partial<ScrapedRecord> = {}): ScrapedRecord {
  return {
    sourceRecordId: "a1",
    kind: "assignment",
    title: "Biology IA",
    subject: "Biology",
    dueAt: "2026-09-20T23:59:00.000Z",
    status: "assigned",
    url: "https://school.example/assignments/1",
    detail: "Read chapter 4",
    ...over,
  };
}

function promoted(): StoredSchoolRecipe {
  return {
    id: "recipe-assignment",
    recipe: { entity: "assignment", source: { selector: "article.task-card" } } as unknown as SchoolRecipe,
    version: "v2",
    confidence: 0.9,
    learnedAt: "2026-09-01T00:00:00.000Z",
    updatedAt: "2026-09-13T14:00:00.000Z",
    structuralSignature: signature,
    lastKnownGood: {
      recipe: { entity: "assignment", source: { selector: "article.assignment-card" } } as unknown as SchoolRecipe,
      version: "v1",
      confidence: 1,
      updatedAt: "2026-09-01T00:00:00.000Z",
      structuralSignature: signature,
    },
  };
}

test("a promoted recipe that now reads nothing has regressed", () => {
  const regression = detectRecipeRegression([], [record(), record({ sourceRecordId: "a2" })]);
  assert.equal(regression?.reason, "zero_records");
});

test("an empty page is not blamed on the recipe", () => {
  assert.equal(detectRecipeRegression([], []), null);
});

test("losing most of a collection is a regression", () => {
  const before = Array.from({ length: 6 }, (_unused, index) => record({ sourceRecordId: `a${index}` }));
  assert.equal(detectRecipeRegression([record()], before)?.reason, "record_count_collapse");
});

test("extracting different items entirely is a regression", () => {
  const regression = detectRecipeRegression(
    [record({ sourceRecordId: "zz1", url: undefined, title: "Cafeteria menu" })],
    [record()],
  );
  assert.equal(regression?.reason, "identity_divergence");
});

test("same rows with the information stripped out is a regression", () => {
  const rich = [record(), record({ sourceRecordId: "a2" })];
  const bare = [
    { sourceRecordId: "a1", kind: "assignment", title: "Biology IA" } as ScrapedRecord,
    { sourceRecordId: "a2", kind: "assignment", title: "Biology IA" } as ScrapedRecord,
  ];
  const regression = detectRecipeRegression(bare, rich);
  assert.equal(regression?.reason, "field_completeness_drop");
  assert.ok(fieldCompleteness(rich) > fieldCompleteness(bare));
});

test("a working promotion is left alone", () => {
  const now = [record(), record({ sourceRecordId: "a2" })];
  assert.equal(detectRecipeRegression(now, [record()]), null);
});

test("rollback restores the old recipe and quarantines the bad version", () => {
  const restored = rollbackToLastKnownGood(promoted(), { reason: "zero_records", before: 4, after: 0 }, "2026-09-13T15:00:00.000Z");

  assert.equal(restored?.version, "v1");
  assert.equal((restored?.recipe as unknown as { source: { selector: string } }).source.selector, "article.assignment-card");
  assert.equal(restored?.lastKnownGood, undefined);
  assert.ok(isQuarantinedVersion(restored!, "v2"));
});

test("a quarantined version can never be promoted again", () => {
  const restored = rollbackToLastKnownGood(promoted(), { reason: "zero_records", before: 4, after: 0 }, "2026-09-13T15:00:00.000Z")!;
  const candidate = {
    recipe: promoted().recipe,
    version: "v2",
    confidence: 0.95,
    structuralSignature: signature,
  };

  // Even after the two independent sightings that normally promote a candidate.
  const first = stageRepairCandidate(undefined, candidate, "2026-09-13T16:00:00.000Z", { quarantined: restored.quarantined });
  const second = stageRepairCandidate(first.pendingRepair, candidate, "2026-09-13T16:05:00.000Z", { quarantined: restored.quarantined });

  assert.equal(first.promote, false);
  assert.equal(second.promote, false);
});

test("a recipe with no earlier strategy cannot roll back", () => {
  const { lastKnownGood: _lastKnownGood, ...withoutHistory } = promoted();
  assert.equal(rollbackToLastKnownGood(withoutHistory, { reason: "zero_records", before: 1, after: 0 }, "2026-09-13T15:00:00.000Z"), null);
});
