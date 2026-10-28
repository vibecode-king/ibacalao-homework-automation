import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyCollectionCompleteness, COLLECTION_CARD_CAP } from "../completeness";
import type { DomSnapshotObservation } from "../evidence";

function snapshot(text: string, cards = 3): DomSnapshotObservation {
  return {
    sourceKey: "vendor:learnbox",
    origin: "https://school.example",
    observedAt: "2026-09-13T15:00:00.000Z",
    payload: {
      kind: "dom-snapshot",
      path: "/assignments",
      pageRole: "collection",
      rows: [{ text }],
      cards: Array.from({ length: cards }, (_unused, index) => ({
        captureId: `c${index}`,
        selector: "tr",
        groupSelector: "tr",
        tag: "tr",
        text: `Assignment ${index}`,
        title: `Assignment ${index}`,
      })),
    },
  };
}

test("showing 1-20 of 85 is a partial collection", () => {
  const result = classifyCollectionCompleteness(snapshot("Showing 1-20 of 85"), { recordCount: 20 });
  assert.equal(result.state, "partial");
  assert.equal(result.state === "partial" && result.reason, "has_next");
});

test("showing 81-85 of 85 is complete", () => {
  const result = classifyCollectionCompleteness(snapshot("Showing 81-85 of 85"), { recordCount: 5 });
  assert.equal(result.state, "complete");
});

test("Next page without a range is still partial", () => {
  const result = classifyCollectionCompleteness(snapshot("Next page"), { recordCount: 12 });
  assert.equal(result.state, "partial");
});

test("an assignment titled next week is not pagination", () => {
  const result = classifyCollectionCompleteness(snapshot("Homework due next week"), { recordCount: 1 });
  assert.equal(result.state, "complete");
});

test("hitting the card cap means we truncated the list", () => {
  const result = classifyCollectionCompleteness(snapshot("Assignments"), { recordCount: COLLECTION_CARD_CAP });
  assert.equal(result.state, "partial");
  assert.equal(result.state === "partial" && result.reason, "truncated");
});

test("a page that says it is empty is a complete empty collection", () => {
  const result = classifyCollectionCompleteness(snapshot("No upcoming assignments"), {
    recordCount: 0,
    empty: { state: "valid_empty", marker: "No upcoming assignments" },
  });
  assert.equal(result.state, "complete");
  assert.equal(result.state === "complete" && result.reason, "explicit_empty");
});

test("a finite list with no pager is a single complete page", () => {
  const result = classifyCollectionCompleteness(snapshot("Biology IA due Friday"), { recordCount: 4 });
  assert.deepEqual(result, { state: "complete", reason: "single_page" });
});
