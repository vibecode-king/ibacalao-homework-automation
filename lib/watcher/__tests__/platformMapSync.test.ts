import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { openSchoolJournal } from "../../school/journal";
import { ensurePlatformGraphSchema, recordPlatformNode } from "../../school/platformGraph";
import { exportPlatformMap } from "../../school/platformMap";
import { loadRecipeBundle, recipeVersion, saveRecipeBundle, type StoredSchoolRecipe } from "../../school/recipeStore";
import type { SchoolRecipe } from "../../school/types";
import {
  downloadPlatformMapOnce,
  proposePlatformMap,
  reportCapabilityFailures,
  type PlatformMapTarget,
} from "../platformMapSync";

const ORIGIN = "https://ukschool.learnbox.com.ec";
const CONTAINER = "/modules/activity/fStudentCalendarActivity";

function stored(selector: string): StoredSchoolRecipe {
  const recipe: SchoolRecipe = { schemaVersion: 1, entity: "assignment", source: { kind: "observed-dom", container: CONTAINER, selector }, fields: {} };
  return {
    id: "r1",
    recipe,
    version: recipeVersion(recipe),
    confidence: 0.9,
    learnedAt: "2026-09-14T10:00:00.000Z",
    updatedAt: "2026-09-14T10:00:00.000Z",
    structuralSignature: { tag: "tr", classTokens: ["row"], attributeNames: [], childTags: ["td"] },
  };
}

function withTarget(sourceKey: string, run: (target: PlatformMapTarget) => Promise<void>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "platform-map-sync-"));
  const target: PlatformMapTarget = {
    platformId: "learnbox",
    recognized: true,
    origin: ORIGIN,
    sourceKey,
    journalFile: join(dir, "school.db"),
    recipeFile: join(dir, "recipes.json"),
  };
  return run(target).finally(() => rmSync(dir, { recursive: true, force: true }));
}

function fakeFetch(respond: (url: string, init?: RequestInit) => { status: number; body?: unknown }) {
  const calls: Array<{ url: string; body: unknown }> = [];
  const impl = async (url: string, init?: RequestInit) => {
    calls.push({ url, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    const { status, body } = respond(url, init);
    return new Response(JSON.stringify(body ?? {}), { status });
  };
  return { impl, calls };
}

test("the approved map is downloaded once and staged as a candidate, never activated", async () => {
  await withTarget("portal:download", async (target) => {
    saveRecipeBundle({ schemaVersion: 1, sourceKey: target.sourceKey, origin: ORIGIN, updatedAt: "x", recipes: [stored("table tbody > tr")] }, target.recipeFile);
    const shared = exportPlatformMap("learnbox", [], [], { schemaVersion: 1, sourceKey: "other", origin: "https://other", updatedAt: "x", recipes: [stored("div.row")] });
    const { impl, calls } = fakeFetch(() => ({ status: 200, body: { versionId: "v1", map: shared } }));

    assert.equal(await downloadPlatformMapOnce(target, "https://api.test", "wt_x", impl), 1);
    assert.equal(await downloadPlatformMapOnce(target, "https://api.test", "wt_x", impl), 0);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, "https://api.test/api/watcher/platform-map/learnbox");

    const [local] = loadRecipeBundle(target.sourceKey, ORIGIN, target.recipeFile).recipes;
    assert.equal(local.recipe.source.selector, "table tbody > tr");
    assert.equal(local.pendingRepair?.recipe.source.selector, "div.row");
    assert.equal(local.pendingRepair?.observations, 0);
  });
});

test("an unrecognized portal never talks to the map endpoints", async () => {
  await withTarget("portal:unknown", async (target) => {
    const { impl, calls } = fakeFetch(() => ({ status: 200 }));
    const unknown = { ...target, recognized: false };
    await downloadPlatformMapOnce(unknown, "https://api.test", "wt_x", impl);
    await proposePlatformMap(unknown, "https://api.test", "wt_x", impl);
    await reportCapabilityFailures(unknown, [{ capability: "assignments", state: "degraded", method: "active_crawl", consecutiveFailures: 1 }], "https://api.test", "wt_x", impl);
    assert.equal(calls.length, 0);
  });
});

test("a proposal is sent once per structure and a failed server is not fatal", async () => {
  await withTarget("portal:propose", async (target) => {
    const db = openSchoolJournal(target.journalFile);
    ensurePlatformGraphSchema(db);
    recordPlatformNode(db, target.sourceKey, { path: CONTAINER, pageRole: "collection", capability: "assignments", observedAt: "2026-09-14T10:00:00.000Z", succeeded: true });
    db.close();

    const down = fakeFetch(() => { throw new Error("offline"); });
    assert.equal(await proposePlatformMap(target, "https://api.test", "wt_x", down.impl), false);

    const { impl, calls } = fakeFetch(() => ({ status: 201, body: { id: "draft" } }));
    assert.equal(await proposePlatformMap(target, "https://api.test", "wt_x", impl), true);
    assert.equal(await proposePlatformMap(target, "https://api.test", "wt_x", impl), false);
    assert.equal(calls.length, 1);
    assert.equal(JSON.stringify(calls[0].body).includes("ukschool"), false);
  });
});

test("only unreadable capabilities are reported, once each", async () => {
  await withTarget("portal:failure", async (target) => {
    saveRecipeBundle({ schemaVersion: 1, sourceKey: target.sourceKey, origin: ORIGIN, updatedAt: "x", recipes: [stored("table tbody > tr")] }, target.recipeFile);
    const { impl, calls } = fakeFetch(() => ({ status: 201 }));
    const capabilities = [
      { capability: "assignments" as const, state: "degraded" as const, method: "active_crawl" as const, consecutiveFailures: 2 },
      { capability: "messages" as const, state: "healthy" as const, method: "active_crawl" as const, consecutiveFailures: 0 },
      { capability: "grades" as const, state: "empty" as const, method: "active_crawl" as const, consecutiveFailures: 0 },
    ];
    assert.equal(await reportCapabilityFailures(target, capabilities, "https://api.test", "wt_x", impl), 1);
    assert.equal(await reportCapabilityFailures(target, capabilities, "https://api.test", "wt_x", impl), 0);
    assert.equal(calls.length, 1);
    const body = calls[0].body as { failureKind: string; sanitizedExcerpt: string };
    assert.equal(body.failureKind, "zero_records");
    assert.deepEqual(JSON.parse(body.sanitizedExcerpt).childTags, ["td"]);
  });
});
