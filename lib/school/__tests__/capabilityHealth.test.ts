// One broken capability must not condemn the others.

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  capabilitiesNeedingCapture,
  degradedCapabilities,
  overlayCapabilityHealth,
  summarizeCapabilityHealth,
  type CapabilityHealth,
  type CapabilityObservation,
} from "../capabilityHealth";
import type { StoredSchoolRecipe } from "../recipeStore";
import type { SchoolRecipe } from "../types";

function recipe(entity: SchoolRecipe["entity"], over: Partial<StoredSchoolRecipe> = {}): StoredSchoolRecipe {
  return {
    id: `recipe-${entity}`,
    recipe: { entity } as SchoolRecipe,
    version: `v1-${entity}`,
    confidence: 1,
    learnedAt: "2026-09-01T00:00:00.000Z",
    updatedAt: "2026-09-01T00:00:00.000Z",
    structuralSignature: { tag: "article", classTokens: [], attributeNames: [], childTags: [] },
    ...over,
  };
}

const observation = (over: Partial<CapabilityObservation> & { recipe: StoredSchoolRecipe }): CapabilityObservation => ({
  observed: true,
  recordCount: 0,
  observedAt: "2026-09-13T15:00:00.000Z",
  ...over,
});

test("a truncated list is not reported as fully healthy coverage", () => {
  const health = summarizeCapabilityHealth([
    observation({ recipe: recipe("assignment"), recordCount: 40, completeness: { state: "partial", reason: "truncated" } }),
  ]);
  assert.equal(health[0].state, "partial");
  assert.equal(health[0].completeness, "partial");
  assert.deepEqual(capabilitiesNeedingCapture(health), ["assignments"]);
});

test("capabilities are reported independently", () => {
  const health = summarizeCapabilityHealth([
    observation({ recipe: recipe("assignment"), recordCount: 3 }),
    observation({ recipe: recipe("message"), empty: { state: "unproven" } }),
    observation({ recipe: recipe("grade"), empty: { state: "valid_empty", marker: "No grades" } }),
  ]);

  assert.deepEqual(
    health.map((entry) => [entry.capability, entry.state]),
    [["assignments", "healthy"], ["grades", "empty"], ["messages", "degraded"]],
  );
});

test("a page the student never opened is unknown, not broken", () => {
  const health = summarizeCapabilityHealth([
    observation({ recipe: recipe("message"), observed: false, observedAt: undefined }),
  ]);
  assert.equal(health[0].state, "unknown");
  assert.equal(health[0].consecutiveFailures, 0);
});

test("a staged repair candidate reads as repairing, not degraded", () => {
  const pending = recipe("assignment", {
    pendingRepair: {
      recipe: {} as SchoolRecipe,
      version: "v2-candidate",
      confidence: 0.9,
      firstObservedAt: "2026-09-13T14:00:00.000Z",
      lastObservedAt: "2026-09-13T14:30:00.000Z",
      observations: 1,
      structuralSignature: { tag: "li", classTokens: [], attributeNames: [], childTags: [] },
    },
  });
  const health = summarizeCapabilityHealth([observation({ recipe: pending, empty: { state: "unproven" } })]);

  assert.equal(health[0].state, "repairing");
  assert.equal(health[0].candidateVersion, "v2-candidate");
});

test("failure streaks accumulate across polls and reset on success", () => {
  let health: CapabilityHealth[] = [];
  for (let poll = 0; poll < 3; poll += 1) {
    health = summarizeCapabilityHealth(
      [observation({ recipe: recipe("message"), empty: { state: "unproven" } })],
      health,
    );
  }
  assert.equal(health[0].consecutiveFailures, 3);
  assert.deepEqual(degradedCapabilities(health), ["messages"]);

  const recovered = summarizeCapabilityHealth(
    [observation({ recipe: recipe("message"), recordCount: 2 })],
    health,
  );
  assert.equal(recovered[0].state, "healthy");
  assert.equal(recovered[0].consecutiveFailures, 0);
  assert.deepEqual(degradedCapabilities(recovered), []);
});

test("a single bad read does not yet deserve the student's attention", () => {
  const health = summarizeCapabilityHealth([observation({ recipe: recipe("grade"), empty: { state: "unproven" } })]);
  assert.equal(health[0].state, "degraded");
  assert.deepEqual(degradedCapabilities(health), []);
});

test("what we knew about an unobserved capability is not blanked out", () => {
  const before = summarizeCapabilityHealth([observation({ recipe: recipe("grade"), recordCount: 4 })]);
  const after = summarizeCapabilityHealth([observation({ recipe: recipe("assignment"), recordCount: 1 })], before);

  const grades = after.find((entry) => entry.capability === "grades");
  assert.equal(grades?.state, "unknown");
  assert.equal(grades?.lastExtractSuccessAt, "2026-09-13T15:00:00.000Z");
});

test("the weakest recipe decides a capability shared by several", () => {
  const health = summarizeCapabilityHealth([
    observation({ recipe: recipe("assignment", { id: "a" }), recordCount: 5 }),
    observation({ recipe: recipe("assignment", { id: "b" }), empty: { state: "unproven" } }),
  ]);
  assert.equal(health[0].state, "degraded");
});

test("an active crawl overlays passive health without blanking unobserved capabilities", () => {
  const previous = summarizeCapabilityHealth([observation({ recipe: recipe("deadline"), recordCount: 2 })]);
  const next = summarizeCapabilityHealth([
    observation({ recipe: recipe("assignment"), recordCount: 3, method: "active_crawl" }),
    observation({ recipe: recipe("message"), recordCount: 10, completeness: { state: "partial", reason: "has_next" } }),
  ]);
  const merged = overlayCapabilityHealth(previous, next);
  assert.equal(merged.find((entry) => entry.capability === "deadlines")?.state, "healthy");
  assert.equal(merged.find((entry) => entry.capability === "assignments")?.method, "active_crawl");
  assert.equal(merged.find((entry) => entry.capability === "messages")?.state, "partial");
});

test("a login wall on one capability is reauth, not a healthy empty list", () => {
  const health = summarizeCapabilityHealth([
    observation({ recipe: recipe("grade"), barrier: "auth_required" }),
  ]);
  assert.equal(health[0].state, "reauth_required");
});
