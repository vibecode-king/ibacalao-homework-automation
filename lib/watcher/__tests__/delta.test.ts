import { test } from "node:test";
import assert from "node:assert/strict";
import { computeDelta, fingerprint, hasUploadableChanges } from "../delta";
import type { ScrapedRecord } from "../types";

function rec(overrides: Partial<ScrapedRecord> = {}): ScrapedRecord {
  return {
    sourceRecordId: "a1",
    kind: "assignment",
    title: "Biology IA draft",
    subject: "Biology",
    dueAt: "2026-09-20T23:59:00.000Z",
    ...overrides,
  };
}

test("first crawl reports everything as added", () => {
  const delta = computeDelta([rec(), rec({ sourceRecordId: "a2" })]);
  assert.equal(delta.added.length, 2);
  assert.equal(delta.changed.length, 0);
  assert.deepEqual(delta.removedIds, []);
});

test("an unchanged re-crawl produces nothing to upload", () => {
  const first = computeDelta([rec()]);
  const second = computeDelta([rec()], first.fingerprints);
  assert.equal(second.added.length, 0);
  assert.equal(second.changed.length, 0);
  assert.ok(!hasUploadableChanges(second), "a quiet poll must not upload");
});

test("a moved deadline is a change", () => {
  const first = computeDelta([rec()]);
  const second = computeDelta([rec({ dueAt: "2026-09-25T23:59:00.000Z" })], first.fingerprints);
  assert.equal(second.changed.length, 1);
  assert.ok(hasUploadableChanges(second));
});

test("a posted grade is a change", () => {
  const first = computeDelta([rec({ kind: "grade" })]);
  const second = computeDelta([rec({ kind: "grade", grade: "6" })], first.fingerprints);
  assert.equal(second.changed.length, 1);
});

test("cosmetic re-rendering is not a change", () => {
  // Whitespace, casing and a rotating tracking param must not read as news —
  // spurious changes turn the delta back into a full upload.
  const first = computeDelta([rec({ url: "https://x?session=old" })]);
  const second = computeDelta(
    [rec({ title: "  biology   ia   DRAFT ", url: "https://x?session=abc123" })],
    first.fingerprints,
  );
  assert.equal(second.changed.length, 0);
  assert.equal(second.added.length, 0);
});

test("the same instant in a different offset is not a change", () => {
  const first = computeDelta([rec({ dueAt: "2026-09-20T00:00:00.000Z" })]);
  const second = computeDelta(
    [rec({ dueAt: "2026-09-20T02:00:00.000+02:00" })],
    first.fingerprints,
  );
  assert.equal(second.changed.length, 0);
});

test("a disappeared record is reported but is not on its own uploadable", () => {
  const first = computeDelta([rec(), rec({ sourceRecordId: "a2" })]);
  const second = computeDelta([rec()], first.fingerprints);
  assert.deepEqual(second.removedIds, ["a2"]);
  assert.ok(
    !hasUploadableChanges(second),
    "an item vanishing from a list is usually pagination, not an academic fact",
  );
});

test("duplicates within one crawl keep the first and do not flip-flop", () => {
  const delta = computeDelta([rec({ title: "First" }), rec({ title: "Second" })]);
  assert.equal(delta.added.length, 1);
  assert.equal(delta.added[0].title, "First");
});

test("records without a stable id are ignored", () => {
  const delta = computeDelta([rec({ sourceRecordId: "" })]);
  assert.equal(delta.added.length, 0);
  assert.deepEqual(delta.fingerprints, {});
});

test("assignment URL changes are tracked after removing volatile navigation details", () => {
  const before = fingerprint(rec({ url: "https://school.example/assignment?view=old&session=old&b=2&a=1#overview" }));
  const sessionRotated = fingerprint(rec({ url: "https://school.example/assignment?a=1&b=2&session=new&view=old#rubric" }));
  const replacement = fingerprint(rec({ url: "https://school.example/assignment?view=new&b=2&a=1" }));
  assert.equal(before, sessionRotated);
  assert.notEqual(before, replacement);
});

test("non-assignment navigation URLs do not create academic changes", () => {
  assert.equal(
    fingerprint(rec({ kind: "grade", url: "https://a" })),
    fingerprint(rec({ kind: "grade", url: "https://b" })),
    "grade source navigation is not assignment content",
  );
});

test("fingerprint distinguishes kind", () => {
  assert.notEqual(fingerprint(rec({ kind: "assignment" })), fingerprint(rec({ kind: "deadline" })));
});
