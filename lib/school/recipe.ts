import type { SchoolRecipe } from "./types";
import type { RepairValidationResult } from "./validation";
import type { AdaptiveDomRepairResult } from "./repair";

/**
 * The only boundary allowed to promote an adaptive candidate into a recipe.
 * Persistence belongs to the future universal recipe runner; this helper keeps
 * the activation rule explicit and fail-closed in the meantime.
 */
export function activateValidatedRepair(
  result: AdaptiveDomRepairResult,
  validation: RepairValidationResult,
): SchoolRecipe | null {
  if (!result.ok || !validation.accepted || validation.disposition !== "activate") return null;
  return result.candidateRecipe;
}
