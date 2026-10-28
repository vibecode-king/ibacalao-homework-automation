import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { writeFileAtomic } from "../atomicFile";

test("writes the file and sweeps orphaned temp files from killed writers", () => {
  const dir = mkdtempSync(join(tmpdir(), "atomic-"));
  const file = join(dir, "entities.json");
  const stale = join(dir, "entities.json.12345.tmp");
  const fresh = join(dir, "entities.json.67890.tmp");
  const unrelated = join(dir, "recipes.json.12345.tmp");
  for (const path of [stale, fresh, unrelated]) writeFileSync(path, "{}");
  const hourAgo = (Date.now() - 60 * 60 * 1000) / 1000;
  utimesSync(stale, hourAgo, hourAgo);
  utimesSync(unrelated, hourAgo, hourAgo);

  writeFileAtomic(file, '{"ok":true}');

  assert.equal(readFileSync(file, "utf8"), '{"ok":true}');
  const left = readdirSync(dir).sort();
  assert.deepEqual(left, ["entities.json", "entities.json.67890.tmp", "recipes.json.12345.tmp"]);
});

test("a failed write leaves no temp file behind", () => {
  const dir = mkdtempSync(join(tmpdir(), "atomic-"));
  const file = join(dir, "missing-dir", "entities.json");
  assert.throws(() => writeFileAtomic(file, "{}"));
  assert.deepEqual(readdirSync(dir), []);
});
