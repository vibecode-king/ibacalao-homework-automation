import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { test } from "node:test";
import { zipSync } from "fflate";
import { evaluatePassiveSchoolSource } from "../passiveEngine";

const ORIGIN = "https://school.example";
const SOURCE_KEY = `portal:${createHash("sha256").update(ORIGIN).digest("hex").slice(0, 32)}`;
const NOW = Date.parse("2026-09-11T17:30:00.000Z");

function capture(payload: Record<string, unknown>, observedAt: string): string {
  return JSON.stringify({
    type: "school.capture",
    sourceSessionId: "integration:1",
    sourceKey: SOURCE_KEY,
    origin: ORIGIN,
    originFingerprint: SOURCE_KEY.slice("portal:".length),
    observedAt,
    receivedAt: observedAt,
    payload,
  });
}

test("calendar -> detail -> downloaded DOCX becomes one progressively enriched assignment", async () => {
  const root = mkdtempSync(join(tmpdir(), "school-stitching-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    const attachment = join(root, "Biology-Rubric.docx");
    writeFileSync(attachment, Buffer.from(zipSync({
      "word/document.xml": new TextEncoder().encode(
        '<w:document><w:body><w:p><w:r><w:t>Rubric: explain the dependent variable and include uncertainty.</w:t></w:r></w:p></w:body></w:document>',
      ),
    })));

    const listCard = {
      captureId: "c0",
      selector: '[data-assignment-id="a1"]',
      groupSelector: "article.assignment-card",
      tag: "article",
      text: "Assignment Biology formative Due Sep 15",
      title: "Biology formative",
      subject: "Biology",
      dueAt: "2026-09-15T23:59:00.000Z",
      path: "/assignments/52983",
      sourceRecordId: "a1",
      classTokens: ["assignment-card"],
      childTags: ["h3", "time", "a"],
      attributes: { class: "assignment-card", "data-assignment-id": "a1" },
    };
    const detailText = "Assignment Biology formative. Complete sections 1 through 4. Explain your method, include a graph, and submit the attached rubric with the report.";
    const detailCard = {
      captureId: "d0",
      selector: "main.assignment-detail",
      groupSelector: "main.assignment-detail",
      tag: "main",
      text: detailText,
      title: "Biology formative",
      subject: "Biology",
      dueAt: "2026-09-15T23:59:00.000Z",
      classTokens: ["assignment-detail"],
      childTags: ["h1", "p", "a"],
      attributes: { class: "assignment-detail" },
    };

    writeFileSync(captureFile, [
      capture({ kind: "dom-snapshot", path: "/calendar", pageRole: "collection", rows: [{ tag: "h2", text: "Assignments" }], cards: [listCard] }, "2026-09-11T17:28:00.000Z"),
      capture({ kind: "dom-snapshot", path: "/assignments/52983", pageRole: "detail", rows: [{ tag: "h1", text: "Biology formative" }], cards: [detailCard] }, "2026-09-11T17:28:30.000Z"),
      capture({
        kind: "attachment-download",
        sourcePagePath: "/assignments/52983",
        localPath: attachment,
        fileName: "Biology-Rubric.docx",
        mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      }, "2026-09-11T17:29:00.000Z"),
    ].join("\n") + "\n");

    const result = await evaluatePassiveSchoolSource({
      sourceKey: SOURCE_KEY,
      origin: ORIGIN,
      platformLabel: "Unknown School Portal",
    }, {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });

    assert.equal(result.records.length, 1, "list and detail must not become duplicate assignments");
    const record = result.records[0];
    assert.match(record.sourceRecordId ?? "", /^school_/);
    assert.match(record.detail ?? "", /Complete sections 1 through 4/);
    assert.match(record.detail ?? "", /dependent variable and include uncertainty/);
    assert.equal(record.changeKind, "new_entity");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
