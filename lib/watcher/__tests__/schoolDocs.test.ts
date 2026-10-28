import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, utimesSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pruneSchoolDocs, saveSchoolOriginal, schoolDocKey } from "../schoolDocs";

test("saves the original under a filesystem-safe key and strips path tricks from the name", () => {
  const root = mkdtempSync(join(tmpdir(), "school-docs-"));
  const path = saveSchoolOriginal("assignment:12/34", "../../evil.docx", new Uint8Array([1, 2, 3]), root);
  assert.equal(path, join(root, "originals", "assignment_12_34", "evil.docx"));
  assert.ok(existsSync(path));
  assert.equal(schoolDocKey("deadline:a b"), "deadline_a_b");
});

test("prunes only entries older than 30 days", () => {
  const root = mkdtempSync(join(tmpdir(), "school-docs-"));
  const fresh = saveSchoolOriginal("fresh", "a.pdf", new Uint8Array([1]), root);
  const stale = saveSchoolOriginal("stale", "b.pdf", new Uint8Array([1]), root);
  mkdirSync(join(root, "drafts"), { recursive: true });
  const staleDraft = join(root, "drafts", "stale.docx");
  writeFileSync(staleDraft, "x");
  const old = new Date(Date.now() - 31 * 24 * 60 * 60 * 1000);
  utimesSync(join(root, "originals", "stale"), old, old);
  utimesSync(staleDraft, old, old);

  assert.equal(pruneSchoolDocs(root), 2);
  assert.ok(existsSync(fresh));
  assert.ok(!existsSync(stale));
  assert.ok(!existsSync(staleDraft));
  assert.equal(pruneSchoolDocs(join(root, "missing")), 0);
});
