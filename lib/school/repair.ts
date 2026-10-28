import type { SchoolRecipe } from "./types";

/**
 * Opaque Scrapling-compatible signature returned by its adaptive storage layer.
 * Keeping it JSON-only makes the Python experiment replaceable by a Node port.
 */
export type ElementSignature = Record<string, unknown>;

export type RepairEvidence = {
  matchedFeatures?: number;
  candidateCount: number;
  visibleTextAgreement?: boolean;
  stableIdAgreement?: boolean;
  captureId?: string;
};

export type AdaptiveDomRepairInput = {
  oldRecipe: SchoolRecipe;
  oldElementSignature?: ElementSignature;
  currentHtml: string;
  currentUrl: string;
  expectedEntity: SchoolRecipe["entity"];
};

export type AdaptiveDomRepairResult =
  | {
      ok: true;
      candidateRecipe: SchoolRecipe;
      confidence: number;
      evidence: RepairEvidence;
    }
  | {
      ok: false;
      reason: "no_candidate" | "ambiguous" | "insufficient_evidence" | "parser_error" | "timeout";
    };

export type AdaptiveDomRepairer = (
  input: AdaptiveDomRepairInput,
) => Promise<AdaptiveDomRepairResult>;

export const AUTO_REPAIR_CONFIDENCE = 0.9;
export const OBSERVE_REPAIR_CONFIDENCE = 0.75;

export type RepairDisposition = "activate" | "observe" | "manual_learning";

export function repairDisposition(result: AdaptiveDomRepairResult): RepairDisposition {
  if (!result.ok) return "manual_learning";
  if (result.evidence.candidateCount !== 1) return "manual_learning";
  if (result.confidence >= AUTO_REPAIR_CONFIDENCE) return "activate";
  if (result.confidence >= OBSERVE_REPAIR_CONFIDENCE) return "observe";
  return "manual_learning";
}
