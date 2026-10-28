// lib/school/capabilityHealth.ts
// Health per capability, not per connector.
//
// A broken Messages recipe used to make Assignments, Grades and Deadlines all
// look equally broken, which is both wrong and unactionable: the student is
// told to "reconnect school" when their assignments were syncing perfectly.
//
// Health here means the end-to-end chain succeeded recently for that specific
// capability — never merely that Chrome, the extension and the native host
// exist.

import type { EmptyObservation } from "./emptyState";
import type { CollectionCompleteness } from "./completeness";
import type { StoredSchoolRecipe } from "./recipeStore";
import type { SchoolActionCapability, SchoolRecipe } from "./types";

export type CapabilityState =
  /** Records extracted recently, and the collection looks complete. */
  | "healthy"
  /** Records extracted, but pagination/detail coverage is still bounded. */
  | "partial"
  /** The page positively said it is empty. Complete, just nothing to show. */
  | "empty"
  /** A repair candidate is accumulating evidence; last good recipe still active. */
  | "repairing"
  /** The session is dead for this capability. */
  | "reauth_required"
  /** CAPTCHA/challenge on this capability's page. */
  | "challenged"
  /** We could not read it and cannot explain why. */
  | "degraded"
  /** The student never browsed it, so we have no opinion. */
  | "unknown";

export type CapabilityHealth = {
  capability: SchoolActionCapability;
  state: CapabilityState;
  /** How this capability is being read today. Grows with the source ladder. */
  method: "dom_recipe" | "active_crawl" | "none";
  recipeVersion?: string;
  candidateVersion?: string;
  lastObservedAt?: string;
  lastExtractSuccessAt?: string;
  consecutiveFailures: number;
  emptyMarker?: string;
  completeness?: CollectionCompleteness["state"];
};

export const CAPABILITY_FOR_ENTITY: Record<SchoolRecipe["entity"], SchoolActionCapability> = {
  assignment: "assignments",
  message: "messages",
  grade: "grades",
  deadline: "deadlines",
  submission: "submissions",
};

export type CapabilityObservation = {
  recipe: StoredSchoolRecipe;
  /** Did any snapshot in this window belong to this recipe's page? */
  observed: boolean;
  recordCount: number;
  observedAt?: string;
  empty?: EmptyObservation;
  completeness?: CollectionCompleteness;
  barrier?: "auth_required" | "challenged";
  method?: CapabilityHealth["method"];
};

/** A capability is only as healthy as its weakest recipe. */
const SEVERITY: CapabilityState[] = [
  "reauth_required",
  "challenged",
  "degraded",
  "repairing",
  "unknown",
  "partial",
  "empty",
  "healthy",
];

function worse(left: CapabilityState, right: CapabilityState): CapabilityState {
  return SEVERITY.indexOf(left) <= SEVERITY.indexOf(right) ? left : right;
}

function stateFor(observation: CapabilityObservation): CapabilityState {
  if (observation.barrier === "auth_required") return "reauth_required";
  if (observation.barrier === "challenged") return "challenged";
  if (observation.recordCount > 0) {
    return observation.completeness?.state === "partial" ? "partial" : "healthy";
  }
  if (!observation.observed) return "unknown";
  if (observation.empty?.state === "valid_empty") return "empty";
  if (observation.empty?.state === "loading" || observation.empty?.state === "wrong_page") return "unknown";
  if (observation.recipe.pendingRepair) return "repairing";
  return "degraded";
}

/**
 * Folds this evaluation's per-recipe results into one row per capability.
 *
 * `previous` carries the failure streak forward: a single unreadable page is
 * noise, the same page failing every visit is a real problem, and that
 * difference is what decides whether the student should be interrupted.
 */
export function summarizeCapabilityHealth(
  observations: CapabilityObservation[],
  previous: CapabilityHealth[] = [],
): CapabilityHealth[] {
  const previousByCapability = new Map(previous.map((entry) => [entry.capability, entry]));
  const byCapability = new Map<SchoolActionCapability, CapabilityHealth>();

  for (const observation of observations) {
    const capability = CAPABILITY_FOR_ENTITY[observation.recipe.recipe.entity];
    const state = stateFor(observation);
    const existing = byCapability.get(capability);
    const before = previousByCapability.get(capability);
    const failed = state === "degraded" || state === "reauth_required" || state === "challenged";

    const merged: CapabilityHealth = {
      capability,
      state: existing ? worse(existing.state, state) : state,
      method: observation.method ?? "dom_recipe",
      recipeVersion: observation.recipe.version,
      ...(observation.recipe.pendingRepair ? { candidateVersion: observation.recipe.pendingRepair.version } : {}),
      ...(observation.observedAt ? { lastObservedAt: observation.observedAt } : {}),
      ...(observation.recordCount > 0 && observation.observedAt
        ? { lastExtractSuccessAt: observation.observedAt }
        : before?.lastExtractSuccessAt
          ? { lastExtractSuccessAt: before.lastExtractSuccessAt }
          : {}),
      consecutiveFailures: failed ? (before?.consecutiveFailures ?? 0) + 1 : 0,
      ...(observation.empty?.state === "valid_empty" ? { emptyMarker: observation.empty.marker } : {}),
      ...(observation.completeness ? { completeness: observation.completeness.state } : {}),
    };
    byCapability.set(capability, merged);
  }

  // A capability we did not observe this round keeps what we last knew about
  // it, so a student browsing only their inbox does not blank out everything.
  for (const [capability, before] of Array.from(previousByCapability.entries())) {
    if (!byCapability.has(capability)) byCapability.set(capability, { ...before, state: "unknown" });
  }

  return Array.from(byCapability.values()).sort((left, right) => left.capability.localeCompare(right.capability));
}

/** Capabilities the student should actually be told about. */
export function degradedCapabilities(health: CapabilityHealth[], minimumFailures = 2): SchoolActionCapability[] {
  return health
    .filter((entry) => entry.state === "degraded" && entry.consecutiveFailures >= minimumFailures)
    .map((entry) => entry.capability);
}

/** Capabilities the student can unstick with one bounded page capture. */
export function capabilitiesNeedingCapture(health: CapabilityHealth[]): SchoolActionCapability[] {
  const degraded = new Set(degradedCapabilities(health));
  for (const entry of health) {
    if (entry.completeness === "partial" || entry.state === "partial") degraded.add(entry.capability);
  }
  return Array.from(degraded).sort();
}

/** Overlay an active crawl on last-known health without blanking unobserved capabilities. */
export function overlayCapabilityHealth(
  previous: CapabilityHealth[] = [],
  next: CapabilityHealth[],
): CapabilityHealth[] {
  const byCapability = new Map(previous.map((entry) => [entry.capability, entry]));
  for (const entry of next) {
    if (entry.state === "unknown") {
      const before = byCapability.get(entry.capability);
      byCapability.set(entry.capability, before ? { ...before, lastObservedAt: entry.lastObservedAt ?? before.lastObservedAt } : entry);
      continue;
    }
    byCapability.set(entry.capability, entry);
  }
  return Array.from(byCapability.values()).sort((left, right) => left.capability.localeCompare(right.capability));
}
