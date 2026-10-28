import assert from "node:assert/strict";
import { test } from "node:test";
import { resolveConfiguredAdapter, sourceKeyForConnection } from "../adapterSelection";
import type { PlatformAdapter } from "../types";

function fakeAdapter(platform: string): PlatformAdapter {
  return { platform: platform as PlatformAdapter["platform"], label: platform, async crawl() { return { ok: true, records: [] }; } };
}

test("no connection configured -> no adapter (daemon runs every static adapter)", () => {
  assert.equal(resolveConfiguredAdapter(null, { managebac: fakeAdapter("managebac") }), undefined);
});

test("learnbox is built per-connection from the discovered origin, not looked up in the static map", () => {
  const adapter = resolveConfiguredAdapter({ platformId: "learnbox", origin: "https://ukschool.learnbox.com.ec" }, {});
  assert.ok(adapter);
  assert.equal(adapter?.platform, "learnbox");
});

test("ManageBac is built per-connection from the school-specific origin", () => {
  const managebac = fakeAdapter("managebac");
  const adapter = resolveConfiguredAdapter({ platformId: "managebac", origin: "https://school.managebac.com" }, { managebac });
  assert.ok(adapter);
  assert.equal(adapter?.platform, "managebac");
  assert.notEqual(adapter, managebac);
});

test("a platform with no bundled adapter (any kind) resolves to undefined, routing to the passive fallback", () => {
  const adapter = resolveConfiguredAdapter({ platformId: "canvas", origin: "https://school.instructure.com" }, { managebac: fakeAdapter("managebac") });
  assert.equal(adapter, undefined);
});

test("Learnbox ingest key stays portal-hashed so extension captures merge with the active crawl", () => {
  const origin = "https://ukschool.learnbox.com.ec";
  const key = sourceKeyForConnection({ platformId: "learnbox", origin, recognized: true }, { managebac: {} });
  assert.match(key, /^portal:[0-9a-f]{32}$/);
  assert.equal(
    key,
    sourceKeyForConnection({ platformId: "learnbox", origin, recognized: false }, { managebac: {} }),
  );
});

test("a recognized static adapter owns a vendor source key", () => {
  assert.equal(
    sourceKeyForConnection(
      { platformId: "managebac", origin: "https://school.managebac.com", recognized: true },
      { managebac: {} },
    ),
    "vendor:managebac",
  );
});
