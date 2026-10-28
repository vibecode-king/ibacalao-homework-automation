import { test } from "node:test";
import assert from "node:assert/strict";
import { repairDisposition, type AdaptiveDomRepairResult } from "../repair";
import { validateAdaptiveRepair } from "../validation";
import { activateValidatedRepair } from "../recipe";

function result(confidence: number, candidateCount = 1): AdaptiveDomRepairResult {
  return {
    ok: true,
    confidence,
    evidence: { candidateCount },
    candidateRecipe: {
      schemaVersion: 1,
      entity: "assignment",
      source: { kind: "observed-dom", selector: ".assignment" },
      fields: { title: ".title" },
    },
  };
}

test("90 percent or higher is eligible for automatic activation", () => {
  assert.equal(repairDisposition(result(0.9)), "activate");
  assert.equal(repairDisposition(result(0.99)), "activate");
});

test("75 to 89 percent stays observational", () => {
  assert.equal(repairDisposition(result(0.75)), "observe");
  assert.equal(repairDisposition(result(0.89)), "observe");
});

test("ambiguous duplicates never auto-repair", () => {
  assert.equal(repairDisposition(result(0.98, 2)), "manual_learning");
});

test("zero records can never validate as a successful repair", () => {
  const validation = validateAdaptiveRepair({
    result: result(0.99),
    recordCount: 0,
    hasExpectedFields: true,
    visibleDataAgrees: true,
  });
  assert.equal(validation.accepted, false);
  assert.ok(validation.reasons.includes("zero_records"));
});

test("visible-data disagreement fails closed even with high confidence", () => {
  const validation = validateAdaptiveRepair({
    result: result(0.99),
    recordCount: 4,
    hasExpectedFields: true,
    visibleDataAgrees: false,
  });
  assert.equal(validation.accepted, false);
  assert.equal(validation.disposition, "manual_learning");
});

test("only a validated automatic repair can become the active recipe", () => {
  const candidate = result(0.95);
  const accepted = validateAdaptiveRepair({
    result: candidate,
    recordCount: 3,
    hasExpectedFields: true,
    visibleDataAgrees: true,
  });
  assert.equal(activateValidatedRepair(candidate, accepted)?.source.selector, ".assignment");

  const rejected = validateAdaptiveRepair({
    result: candidate,
    recordCount: 0,
    hasExpectedFields: true,
    visibleDataAgrees: true,
  });
  assert.equal(activateValidatedRepair(candidate, rejected), null);
});
