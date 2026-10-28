import assert from "node:assert/strict";
import { test } from "node:test";
import { planCapabilityPath } from "../crawlPlan";
import type { PlatformNode } from "../platformGraph";

function node(overrides: Partial<PlatformNode>): PlatformNode {
  return {
    nodeId: "n",
    sourceKey: "portal:x",
    routeTemplate: "/modules/activity/list",
    pageRole: "collection",
    capability: "assignments",
    activeRecipeId: "r1",
    candidateRecipeId: null,
    observationCount: 5,
    successCount: 5,
    failureCount: 0,
    stableIdRatio: 1,
    fieldCompleteness: 0.5,
    lastObservedAt: null,
    lastSuccessAt: null,
    lastFailureAt: null,
    ...overrides,
  };
}

test("no graph evidence means the bundled path", () => {
  assert.deepEqual(planCapabilityPath([], "assignments", "/bundled"), { path: "/bundled", source: "bundled" });
});

test("a reliable, well-observed page wins", () => {
  assert.deepEqual(
    planCapabilityPath([node({ observationCount: 3, successCount: 3 })], "assignments", "/bundled"),
    { path: "/modules/activity/list", source: "graph" },
  );
});

test("thin or flaky evidence falls back", () => {
  assert.equal(planCapabilityPath([node({ observationCount: 2, successCount: 2 })], "assignments", "/b").source, "bundled");
  assert.equal(planCapabilityPath([node({ observationCount: 10, successCount: 7 })], "assignments", "/b").source, "bundled");
});

test("a template containing :id is never chosen for a collection", () => {
  assert.equal(planCapabilityPath([node({ routeTemplate: "/assignments/:id" })], "assignments", "/b").source, "bundled");
});

test("a JSON endpoint no recipe ever read is never a crawl target", () => {
  assert.equal(planCapabilityPath([node({ activeRecipeId: null })], "assignments", "/b").source, "bundled");
});

test("another capability's page is ignored", () => {
  assert.equal(planCapabilityPath([node({ capability: "messages" })], "assignments", "/b").source, "bundled");
});
