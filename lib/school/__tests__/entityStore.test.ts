import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { test } from "node:test";
import { enrichCanonicalEntityFromAttachment, loadCanonicalSchoolEntities, reconcileSchoolRecords } from "../entityStore";
import type { AttachmentDownloadObservation, NavigationEdgeObservation } from "../evidence";

const SOURCE = "portal:abc123";
const ORIGIN = "https://school.example";

test("list and detail observations stitch into one canonical assignment by stable detail URL", () => {
  const root = mkdtempSync(join(tmpdir(), "school-entity-"));
  const file = join(root, "entities.json");
  try {
    const result = reconcileSchoolRecords(SOURCE, ORIGIN, [
      {
        sourceRecordId: "a1",
        kind: "assignment",
        title: "Biology formative",
        subject: "Biology",
        dueAt: "2026-09-15T23:59:00Z",
        url: "https://school.example/assignments/52983",
      },
      {
        sourceRecordId: "synthetic-detail",
        kind: "assignment",
        title: "Biology formative",
        subject: "Biology",
        dueAt: "2026-09-15T23:59:00Z",
        detail: "Write the lab report and answer questions 1 through 4.",
        url: "https://school.example/assignments/52983",
      },
    ], { file, observedAt: "2026-09-11T17:00:00Z" });

    assert.equal(result.records.length, 1);
    assert.match(result.records[0].sourceRecordId ?? "", /^school_/);
    assert.match(result.records[0].detail ?? "", /questions 1 through 4/);
    assert.equal(loadCanonicalSchoolEntities(SOURCE, file).length, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a shared collection URL never merges two different assignments", () => {
  const root = mkdtempSync(join(tmpdir(), "school-entity-weak-"));
  const file = join(root, "entities.json");
  try {
    const result = reconcileSchoolRecords(SOURCE, ORIGIN, [
      { sourceRecordId: "a1", kind: "assignment", title: "Biology", url: "https://school.example/assignments" },
      { sourceRecordId: "a2", kind: "assignment", title: "History", url: "https://school.example/assignments" },
    ], { file });
    assert.equal(result.records.length, 2);
    assert.equal(loadCanonicalSchoolEntities(SOURCE, file).length, 2);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a natural navigation edge can promote an otherwise weak detail URL", () => {
  const root = mkdtempSync(join(tmpdir(), "school-entity-edge-"));
  const file = join(root, "entities.json");
  try {
    const edge: NavigationEdgeObservation = {
      sourceKey: SOURCE,
      origin: ORIGIN,
      observedAt: "2026-09-11T17:00:00Z",
      payload: {
        kind: "navigation-edge",
        fromPath: "/calendar",
        toPath: "/assignment/view",
        relationship: "detail",
        sourceRecordId: "a1",
      },
    };
    const result = reconcileSchoolRecords(SOURCE, ORIGIN, [
      { sourceRecordId: "a1", kind: "assignment", title: "Biology", url: "https://school.example/assignment/view" },
      { sourceRecordId: "detail-x", kind: "assignment", title: "Biology", detail: "Full instructions", url: "https://school.example/assignment/view" },
    ], { file, navigationEdges: [edge] });
    assert.equal(result.records.length, 1);
    assert.equal(result.records[0].detail, "Full instructions");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("later sparse observations do not erase progressively learned detail", () => {
  const root = mkdtempSync(join(tmpdir(), "school-entity-progress-"));
  const file = join(root, "entities.json");
  try {
    const first = reconcileSchoolRecords(SOURCE, ORIGIN, [{
      sourceRecordId: "a1",
      kind: "assignment",
      title: "Biology",
      detail: "Detailed rubric instructions",
    }], { file });
    const second = reconcileSchoolRecords(SOURCE, ORIGIN, [{
      sourceRecordId: "a1",
      kind: "assignment",
      title: "Biology",
    }], { file });
    assert.equal(first.records[0].changeKind, "new_entity");
    assert.equal(second.records[0].detail, "Detailed rubric instructions");
    assert.equal(second.records[0].changeKind, "unchanged");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("stale detail evidence cannot override a newer list value or manufacture a change", () => {
  const root = mkdtempSync(join(tmpdir(), "school-entity-order-"));
  const file = join(root, "entities.json");
  try {
    reconcileSchoolRecords(SOURCE, ORIGIN, [{
      sourceRecordId: "a1",
      kind: "assignment",
      title: "Biology",
      dueAt: "2026-09-20T23:59:00Z",
      url: "https://school.example/assignments/52983",
      observedAt: "2026-09-11T17:10:00Z",
    }], { file });

    const result = reconcileSchoolRecords(SOURCE, ORIGIN, [
      {
        sourceRecordId: "detail-old",
        kind: "assignment",
        title: "Biology",
        dueAt: "2026-09-15T23:59:00Z",
        detail: "Full instructions",
        url: "https://school.example/assignments/52983",
        observedAt: "2026-09-11T17:05:00Z",
      },
      {
        sourceRecordId: "a1",
        kind: "assignment",
        title: "Biology",
        dueAt: "2026-09-20T23:59:00Z",
        url: "https://school.example/assignments/52983",
        observedAt: "2026-09-11T17:12:00Z",
      },
    ], { file });

    assert.equal(result.records.length, 1);
    assert.equal(result.records[0].dueAt, "2026-09-20T23:59:00Z");
    assert.equal(result.records[0].detail, "Full instructions");
    assert.equal(result.records[0].changeKind, "enriched");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a replacement attachment at the same URL replaces its old extracted instructions", () => {
  const root = mkdtempSync(join(tmpdir(), "school-entity-attachment-revision-"));
  const file = join(root, "entities.json");
  try {
    reconcileSchoolRecords(SOURCE, ORIGIN, [{
      sourceRecordId: "52983",
      kind: "assignment",
      title: "Biology lab report",
      detail: "Write a lab report using the attached rubric.",
      url: "https://school.example/assignments/52983",
    }], { file });
    const observation: AttachmentDownloadObservation = {
      sourceKey: SOURCE,
      origin: ORIGIN,
      observedAt: "2026-09-12T12:00:00Z",
      payload: {
        kind: "attachment-download",
        sourcePagePath: "/assignments/52983",
        sourceUrlPath: "/downloads/lab-rubric.pdf",
        localPath: "/fixture/lab-rubric.pdf",
        fileName: "lab-rubric.pdf",
        mimeType: "application/pdf",
      },
    };
    const first = enrichCanonicalEntityFromAttachment(SOURCE, ORIGIN, observation, {
      ok: true,
      kind: "pdf",
      sha256: "a".repeat(64),
      bytes: 100,
      text: "Rubric v1: include photosynthesis.",
    }, file);
    assert.match(first?.detail ?? "", /Rubric v1/);

    // Existing local stores predate sourceDetail. Exercise the compatibility
    // path so a replacement can remove the previously appended section.
    const store = JSON.parse(readFileSync(file, "utf8")) as {
      sources: Record<string, { entities: Array<Record<string, unknown>> }>;
    };
    delete store.sources[SOURCE].entities[0].sourceDetail;
    writeFileSync(file, JSON.stringify(store));

    const replacement = enrichCanonicalEntityFromAttachment(SOURCE, ORIGIN, {
      ...observation,
      observedAt: "2026-09-12T12:05:00Z",
    }, {
      ok: true,
      kind: "pdf",
      sha256: "b".repeat(64),
      bytes: 120,
      text: "Rubric v2: include cellular respiration.",
    }, file);

    assert.match(replacement?.detail ?? "", /Write a lab report/);
    assert.doesNotMatch(replacement?.detail ?? "", /Rubric v1/);
    assert.match(replacement?.detail ?? "", /Rubric v2/);
    assert.equal(loadCanonicalSchoolEntities(SOURCE, file)[0].attachments.length, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
