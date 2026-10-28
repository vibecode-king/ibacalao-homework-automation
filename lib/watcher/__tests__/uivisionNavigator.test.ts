import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveUivisionExtensionPath, uivisionManifestChecksum } from "../uivisionNavigator";

test("resolves null when the pinned extension artifact is absent (Phase 0 not shipped yet)", () => {
  const dir = mkdtempSync(join(tmpdir(), "uivision-runtime-"));
  try {
    assert.equal(resolveUivisionExtensionPath(dir), null);
    assert.equal(uivisionManifestChecksum(join(dir, "uivision", "extension")), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("resolves the extension dir and a stable checksum once the artifact is present", () => {
  const dir = mkdtempSync(join(tmpdir(), "uivision-runtime-"));
  try {
    const extDir = join(dir, "uivision", "extension");
    mkdirSync(extDir, { recursive: true });
    writeFileSync(join(extDir, "manifest.json"), JSON.stringify({ name: "UI.Vision", manifest_version: 3 }));
    const resolved = resolveUivisionExtensionPath(dir);
    assert.equal(resolved, extDir);
    const checksum = uivisionManifestChecksum(extDir);
    assert.equal(typeof checksum, "string");
    assert.equal(checksum, uivisionManifestChecksum(extDir));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
