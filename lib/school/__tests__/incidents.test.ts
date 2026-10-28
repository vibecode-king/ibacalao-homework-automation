import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { blockerTransition, recordBlockerTransition } from "../incidents";

test("blocker transitions fire only on enter and leave", () => {
  assert.equal(blockerTransition(null, "healthy"), null);
  assert.equal(blockerTransition("healthy", "mac_not_syncing"), "enter");
  assert.equal(blockerTransition("mac_not_syncing", "mac_not_syncing"), null);
  assert.equal(blockerTransition("mac_not_syncing", "healthy"), "leave");
  assert.equal(blockerTransition("finish_setup", "school_signin_needed"), "enter");
});

test("writes one jsonl line per transition", () => {
  const dir = mkdtempSync(join(tmpdir(), "ibacalao-incidents-"));
  const file = join(dir, "incidents.jsonl");
  try {
    recordBlockerTransition({ previousCode: "healthy", nextCode: "mac_not_syncing", file, snapshot: { chain: "daemon_not_consuming" } });
    recordBlockerTransition({ previousCode: "mac_not_syncing", nextCode: "mac_not_syncing", file });
    recordBlockerTransition({ previousCode: "mac_not_syncing", nextCode: "healthy", file });
    const lines = readFileSync(file, "utf8").trim().split("\n");
    assert.equal(lines.length, 2);
    assert.equal(JSON.parse(lines[0]).direction, "enter");
    assert.equal(JSON.parse(lines[1]).direction, "leave");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
