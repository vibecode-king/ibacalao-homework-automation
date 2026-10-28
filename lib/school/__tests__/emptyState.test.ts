// "Nothing due" must be something the page said, not something we assumed.

import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyEmptyObservation, blocksRepairEvidence } from "../emptyState";
import type { DomSnapshotObservation } from "../evidence";
import type { SchoolPageRole } from "../types";

function snapshot(
  text: string,
  options: { pageRole?: SchoolPageRole; sanitizedHtml?: string } = {},
): DomSnapshotObservation {
  return {
    sourceKey: "vendor:managebac",
    origin: "https://school.example",
    observedAt: "2026-09-13T15:00:00.000Z",
    payload: {
      kind: "dom-snapshot",
      path: "/assignments",
      pageRole: options.pageRole ?? "collection",
      rows: [{ text }],
      ...(options.sanitizedHtml ? { sanitizedHtml: options.sanitizedHtml } : {}),
    },
  };
}

test("an explicit empty-state marker is a trustworthy zero", () => {
  for (const phrase of [
    "No upcoming assignments",
    "You're all caught up",
    "No hay tareas pendientes",
    "Nothing due this week",
  ]) {
    const result = classifyEmptyObservation(snapshot(phrase), "assignment");
    assert.equal(result.state, "valid_empty", `expected valid_empty for: ${phrase}`);
  }
});

test("a page that says nothing at all is never treated as empty", () => {
  assert.equal(classifyEmptyObservation(snapshot("Welcome back, Martin"), "assignment").state, "unproven");
});

test("a half-rendered page is not evidence of anything", () => {
  assert.equal(classifyEmptyObservation(snapshot("Loading your assignments"), "assignment").state, "loading");
  assert.equal(
    classifyEmptyObservation(snapshot("", { sanitizedHtml: '<div class="skeleton-row"></div>' }), "assignment").state,
    "loading",
  );
});

test("a loading page is checked before its words are trusted", () => {
  // Both markers present: "loading" wins, because the empty text may simply be
  // the placeholder that the spinner is about to replace.
  assert.equal(classifyEmptyObservation(snapshot("Loading... no assignments"), "assignment").state, "loading");
});

test("the grades page says nothing about the message inbox", () => {
  assert.equal(classifyEmptyObservation(snapshot("No results found", { pageRole: "grades" }), "message").state, "wrong_page");
  assert.equal(classifyEmptyObservation(snapshot("No messages", { pageRole: "messages" }), "message").state, "valid_empty");
});

test("only an unexplained zero may drive a repair", () => {
  assert.equal(blocksRepairEvidence({ state: "unproven" }), false);
  assert.equal(blocksRepairEvidence({ state: "valid_empty", marker: "No assignments" }), true);
  assert.equal(blocksRepairEvidence({ state: "loading" }), true);
  assert.equal(blocksRepairEvidence({ state: "wrong_page" }), true);
});
