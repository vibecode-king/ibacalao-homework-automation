import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { reconcileSchoolRecords, loadCanonicalSchoolEntities } from "../entityStore";
import { loadRecipeBundle, saveRecipeBundle, type SchoolRecipeBundle } from "../recipeStore";

const SOURCE = "portal:0123456789abcdef0123456789abcdef";
const ORIGIN = "https://school.example";

function recipeBundle(updatedAt: string): SchoolRecipeBundle {
  return {
    schemaVersion: 1,
    sourceKey: SOURCE,
    origin: ORIGIN,
    updatedAt,
    recipes: [],
  };
}

test("recipe store restores last valid backup instead of silently becoming empty", () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-recipe-store-"));
  try {
    const file = join(root, "recipes.json");
    const first = recipeBundle("2026-09-13T12:00:00.000Z");
    const second = recipeBundle("2026-09-13T13:00:00.000Z");
    saveRecipeBundle(first, file);
    saveRecipeBundle(second, file);
    writeFileSync(file, "{broken-json");

    const restored = loadRecipeBundle(SOURCE, ORIGIN, file);
    assert.equal(restored.updatedAt, first.updatedAt);
    assert.match(readFileSync(`${file}.bak`, "utf8"), /2026-09-13T12:00:00.000Z/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("recipe store fails closed when current and backup are both corrupt", () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-recipe-corrupt-"));
  try {
    const file = join(root, "recipes.json");
    writeFileSync(file, "broken");
    writeFileSync(`${file}.bak`, "also-broken");
    assert.throws(() => loadRecipeBundle(SOURCE, ORIGIN, file), /school_recipe_store_corrupt/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("entity store restores backup and fails closed rather than resetting identity", () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-entity-store-"));
  try {
    const file = join(root, "entities.json");
    const record = {
      sourceRecordId: "assignment-1",
      kind: "assignment" as const,
      title: "Biology IA",
      url: `${ORIGIN}/assignments/1`,
      dueAt: "2026-09-20T23:59:00.000Z",
    };
    reconcileSchoolRecords(SOURCE, ORIGIN, [record], { file, observedAt: "2026-09-13T12:00:00.000Z" });
    reconcileSchoolRecords(SOURCE, ORIGIN, [{ ...record, status: "assigned" }], { file, observedAt: "2026-09-13T13:00:00.000Z" });
    writeFileSync(file, "broken");

    const restored = loadCanonicalSchoolEntities(SOURCE, file);
    assert.equal(restored.length, 1);
    assert.equal(restored[0].record.title, "Biology IA");

    writeFileSync(`${file}.bak`, "broken-too");
    assert.throws(() => loadCanonicalSchoolEntities(SOURCE, file), /school_entity_store_corrupt/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
