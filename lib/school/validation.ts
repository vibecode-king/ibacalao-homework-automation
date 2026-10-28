import type { AdaptiveDomRepairResult, RepairDisposition } from "./repair";
import { repairDisposition } from "./repair";

export type RepairValidationInput = {
  result: AdaptiveDomRepairResult;
  recordCount: number;
  hasExpectedFields: boolean;
  visibleDataAgrees: boolean;
};

export type RepairValidationResult = {
  accepted: boolean;
  disposition: RepairDisposition;
  reasons: string[];
};

/**
 * Academic data is fail-closed: a candidate can only activate when the parser
 * produced real records and the visible fields agree with what the student sees.
 */
export function validateAdaptiveRepair(input: RepairValidationInput): RepairValidationResult {
  const reasons: string[] = [];
  if (!input.result.ok) reasons.push(input.result.reason);
  if (input.recordCount <= 0) reasons.push("zero_records");
  if (!input.hasExpectedFields) reasons.push("missing_expected_fields");
  if (!input.visibleDataAgrees) reasons.push("visible_data_mismatch");

  const disposition = input.result.ok ? repairDisposition(input.result) : "manual_learning";
  if (disposition !== "activate") reasons.push(`repair_${disposition}`);

  return {
    accepted: reasons.length === 0,
    disposition: reasons.length === 0 ? "activate" : disposition === "activate" ? "manual_learning" : disposition,
    reasons,
  };
}
