import type { SchoolActionCapability, SchoolConnectionStatus } from "./types";

type MoodleDetailEntity = {
  kind: string;
  record: { kind?: string; dueAt?: string };
  sourceDetail?: string;
  updatedAt: string;
};

/** Reflect successful read-only Moodle detail extraction without claiming
 *  collection completeness. The Learn window stays available while any
 *  capability is still partial. */
export function applyMoodleCapabilityEvidence(
  status: SchoolConnectionStatus,
  entities: MoodleDetailEntity[],
): SchoolConnectionStatus {
  const observedAt = new Map<SchoolActionCapability, string>();
  for (const entity of entities) {
    if (entity.kind !== "assignment" || entity.record.kind !== "assignment") continue;
    if (entity.record.dueAt) observedAt.set("deadlines", entity.updatedAt);
    if (/\bSubmission status:\s*\S/i.test(entity.sourceDetail ?? "")) {
      observedAt.set("submissions", entity.updatedAt);
    }
  }
  if (observedAt.size === 0) return status;

  const capabilities = [...(status.capabilities ?? [])];
  const incomplete = new Set(status.incompleteCapabilities ?? []);
  const missing = new Set(status.missingCapabilities ?? []);
  for (const [capability, at] of observedAt) {
    const prior = capabilities.find((item) => item.capability === capability);
    if (prior?.state === "healthy" || prior?.state === "empty") {
      missing.delete(capability);
      incomplete.delete(capability);
      continue;
    }
    const next = {
      capability,
      state: "partial" as const,
      method: "active_crawl" as const,
      recipeVersion: "moodle-detail-v1",
      lastObservedAt: at,
      lastExtractSuccessAt: at,
      consecutiveFailures: 0,
      completeness: "partial" as const,
    };
    const index = capabilities.findIndex((item) => item.capability === capability);
    if (index < 0) capabilities.push(next);
    else capabilities[index] = next;
    incomplete.add(capability);
    missing.delete(capability);
  }

  const missingCapabilities = [...missing].sort();
  const actionReason = status.actionReason === "manual_learning_required" && missingCapabilities.length === 0
    ? "none"
    : status.actionReason;
  return {
    ...status,
    actionReason,
    capabilities: capabilities.sort((left, right) => left.capability.localeCompare(right.capability)),
    missingCapabilities,
    incompleteCapabilities: [...incomplete].sort(),
  };
}
