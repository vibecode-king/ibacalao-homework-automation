import { test } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { runScraplingRepair, runScraplingSignature } from "../scraplingSidecar";

const recipe = {
  schemaVersion: 1 as const,
  entity: "assignment" as const,
  source: { kind: "observed-dom" as const, selector: ".old-task" },
  fields: { title: ".title" },
};

test("sidecar refuses repair without a historical element signature", async () => {
  const result = await runScraplingRepair({
    oldRecipe: recipe,
    currentHtml: "<article><h3>Biology IA</h3></article>",
    currentUrl: "https://school.example/tasks",
    expectedEntity: "assignment",
  });
  assert.deepEqual(result, { ok: false, reason: "insufficient_evidence" });
});

test("sidecar fails closed on malformed helper output", async () => {
  const result = await runScraplingRepair(
    {
      oldRecipe: recipe,
      oldElementSignature: { tag: "article" },
      currentHtml: "<article><h3>Biology IA</h3></article>",
      currentUrl: "https://school.example/tasks",
      expectedEntity: "assignment",
    },
    {
      python: process.execPath,
      script: "-e",
      timeoutMs: 25,
    },
  );
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.reason, "parser_error");
});

test("sidecar hard-kills a helper that exceeds the configured ceiling and reports timeout", async () => {
  const started = Date.now();
  const result = await runScraplingRepair(
    {
      oldRecipe: recipe,
      oldElementSignature: { tag: "article" },
      currentHtml: "<article><h3>Biology IA</h3></article>",
      currentUrl: "https://school.example/tasks",
      expectedEntity: "assignment",
    },
    {
      python: process.execPath,
      script: join(process.cwd(), "lib", "school", "__tests__", "fixtures", "slow-child.cjs"),
      timeoutMs: 30,
    },
  );
  assert.equal(result.ok, false);
  if (!result.ok) assert.equal(result.reason, "timeout");
  assert.ok(Date.now() - started < 500);
});

test("an explicit cold-start timeout above 3 seconds is honored", async () => {
  const started = Date.now();
  const result = await runScraplingSignature(
    {
      currentHtml: '<main><ibacalao-card data-capture-id="c0"><article>Task</article></ibacalao-card></main>',
      currentUrl: "https://school.example/tasks",
      captureId: "c0",
    },
    {
      python: process.execPath,
      script: join(process.cwd(), "lib", "school", "__tests__", "fixtures", "slow-success-child.cjs"),
      timeoutMs: 5_000,
    },
  );
  assert.equal(result.ok, true);
  assert.ok(Date.now() - started >= 3_000);
  assert.ok(Date.now() - started < 5_000);
});

test("signature helper fails closed on malformed helper output", async () => {
  const result = await runScraplingSignature(
    {
      currentHtml: '<main><ibacalao-card data-capture-id="c0"><article>Task</article></ibacalao-card></main>',
      currentUrl: "https://school.example/tasks",
      captureId: "c0",
    },
    { python: process.execPath, script: "-e", timeoutMs: 25 },
  );
  assert.equal(result.ok, false);
});
