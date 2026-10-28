import assert from "node:assert/strict";
import { test } from "node:test";
import { classifySchoolPage } from "../pageClassifier";
import type { DomSnapshotObservation } from "../evidence";

function snapshot(path: string, cards: DomSnapshotObservation["payload"]["cards"]): DomSnapshotObservation {
  return {
    sourceKey: "portal:abc",
    origin: "https://school.example",
    observedAt: "2026-09-11T17:00:00Z",
    payload: { kind: "dom-snapshot", path, rows: [], cards },
  };
}

test("repeated card structure is a collection", () => {
  const card = (id: string) => ({
    captureId: id,
    selector: `#${id}`,
    groupSelector: "article.task",
    tag: "article",
    text: "Assignment Biology",
  });
  assert.equal(classifySchoolPage(snapshot("/calendar", [card("a"), card("b")])), "collection");
});

test("one academic card on an id-bearing route is a detail page", () => {
  assert.equal(classifySchoolPage(snapshot("/assignments/52983", [{
    captureId: "a",
    selector: "main",
    groupSelector: "main.assignment",
    tag: "main",
    text: "Assignment Biology instructions",
  }])), "detail");
});

test("message and grade topology are recognized without portal-specific selectors", () => {
  assert.equal(classifySchoolPage(snapshot("/student/inbox", [])), "messages");
  assert.equal(classifySchoolPage(snapshot("/student/grades", [])), "grades");
});
