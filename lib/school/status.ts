import type {
  SchoolActionCapability,
  SchoolActionReason,
  SchoolConnectionStatus,
  SchoolRecipeState,
  SchoolSyncMode,
} from "./types";
import type { CapabilityHealth, CapabilityState } from "./capabilityHealth";
import { parseSchoolSourceKey } from "./source";
import type { ChainState } from "./chainTelemetry";

export const SCHOOL_ACTION_PRIORITY: readonly SchoolActionReason[] = [
  "reauth_required",
  "challenge_paused",
  "connector_stale",
  "manual_learning_required",
  "recipe_repairing",
  "none",
] as const;

const SYNC_MODES = new Set<SchoolSyncMode>([
  "official_api",
  "verified_background",
  "passive_browser",
  "manual_page",
  "visual_fallback",
]);

const ACTION_REASONS = new Set<SchoolActionReason>(SCHOOL_ACTION_PRIORITY);
const RECIPE_STATES = new Set<SchoolRecipeState>(["missing", "healthy", "repairing", "stale"]);
const ACTION_CAPABILITIES = new Set<SchoolActionCapability>([
  "assignments",
  "messages",
  "grades",
  "deadlines",
  "submissions",
]);
const CAPABILITY_STATES = new Set<CapabilityState>([
  "healthy",
  "partial",
  "empty",
  "repairing",
  "reauth_required",
  "challenged",
  "degraded",
  "unknown",
]);
const HEALTH_METHODS = new Set<CapabilityHealth["method"]>(["dom_recipe", "active_crawl", "none"]);
const CHAIN_STATES = new Set<ChainState>([
  "healthy",
  "browser_not_observed",
  "bridge_disconnected",
  "daemon_not_consuming",
  "extraction_failing",
  "upload_failing",
]);

function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed || undefined;
}

function optionalConfidence(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) && value >= 0 && value <= 1
    ? value
    : undefined;
}

function parseCapabilityHealth(value: unknown): CapabilityHealth | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.capability !== "string" || !ACTION_CAPABILITIES.has(raw.capability as SchoolActionCapability)) return null;
  if (typeof raw.state !== "string" || !CAPABILITY_STATES.has(raw.state as CapabilityState)) return null;
  if (typeof raw.method !== "string" || !HEALTH_METHODS.has(raw.method as CapabilityHealth["method"])) return null;
  if (typeof raw.consecutiveFailures !== "number" || !Number.isFinite(raw.consecutiveFailures) || raw.consecutiveFailures < 0) {
    return null;
  }
  const completeness = raw.completeness === "complete" || raw.completeness === "partial" || raw.completeness === "unknown"
    ? raw.completeness
    : undefined;
  return {
    capability: raw.capability as SchoolActionCapability,
    state: raw.state as CapabilityState,
    method: raw.method as CapabilityHealth["method"],
    consecutiveFailures: Math.floor(raw.consecutiveFailures),
    ...(optionalString(raw.recipeVersion) ? { recipeVersion: optionalString(raw.recipeVersion) } : {}),
    ...(optionalString(raw.candidateVersion) ? { candidateVersion: optionalString(raw.candidateVersion) } : {}),
    ...(optionalString(raw.lastObservedAt) ? { lastObservedAt: optionalString(raw.lastObservedAt) } : {}),
    ...(optionalString(raw.lastExtractSuccessAt) ? { lastExtractSuccessAt: optionalString(raw.lastExtractSuccessAt) } : {}),
    ...(optionalString(raw.emptyMarker) ? { emptyMarker: optionalString(raw.emptyMarker) } : {}),
    ...(completeness ? { completeness } : {}),
  };
}

/**
 * Treat status.json as an untrusted process boundary. The watcher owns the file,
 * but the web UI and native shell must never render malformed fields blindly.
 */
export function normalizeSchoolConnectionStatus(value: unknown): SchoolConnectionStatus | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  const sourceKey = parseSchoolSourceKey(raw.sourceKey);
  const platformLabel = optionalString(raw.platformLabel);
  if (!sourceKey || !platformLabel || typeof raw.connected !== "boolean") return null;
  if (!SYNC_MODES.has(raw.syncMode as SchoolSyncMode)) return null;
  if (!ACTION_REASONS.has(raw.actionReason as SchoolActionReason)) return null;

  let recipe: SchoolConnectionStatus["recipe"];
  if (raw.recipe && typeof raw.recipe === "object" && !Array.isArray(raw.recipe)) {
    const candidate = raw.recipe as Record<string, unknown>;
    if (!RECIPE_STATES.has(candidate.state as SchoolRecipeState)) return null;
    recipe = {
      state: candidate.state as SchoolRecipeState,
      ...(optionalString(candidate.version) ? { version: optionalString(candidate.version) } : {}),
      ...(optionalConfidence(candidate.confidence) !== undefined
        ? { confidence: optionalConfidence(candidate.confidence) }
        : {}),
    };
  }

  const missingCapabilities = Array.isArray(raw.missingCapabilities)
    ? raw.missingCapabilities.filter(
        (item): item is SchoolActionCapability =>
          typeof item === "string" && ACTION_CAPABILITIES.has(item as SchoolActionCapability),
      )
    : undefined;
  const incompleteCapabilities = Array.isArray(raw.incompleteCapabilities)
    ? raw.incompleteCapabilities.filter(
        (item): item is SchoolActionCapability =>
          typeof item === "string" && ACTION_CAPABILITIES.has(item as SchoolActionCapability),
      )
    : undefined;
  const capabilities = Array.isArray(raw.capabilities)
    ? raw.capabilities.flatMap((item) => {
        const parsed = parseCapabilityHealth(item);
        return parsed ? [parsed] : [];
      })
    : undefined;

  return {
    sourceKey,
    platformLabel,
    connected: raw.connected,
    syncMode: raw.syncMode as SchoolSyncMode,
    actionReason: raw.actionReason as SchoolActionReason,
    ...(optionalString(raw.schoolLabel) ? { schoolLabel: optionalString(raw.schoolLabel) } : {}),
    ...(optionalString(raw.lastSuccessAt) ? { lastSuccessAt: optionalString(raw.lastSuccessAt) } : {}),
    ...(optionalString(raw.lastObservedAt) ? { lastObservedAt: optionalString(raw.lastObservedAt) } : {}),
    ...(recipe ? { recipe } : {}),
    ...(missingCapabilities && missingCapabilities.length > 0 ? { missingCapabilities } : {}),
    ...(incompleteCapabilities && incompleteCapabilities.length > 0 ? { incompleteCapabilities } : {}),
    ...(capabilities && capabilities.length > 0 ? { capabilities } : {}),
    ...(typeof raw.chainState === "string" && CHAIN_STATES.has(raw.chainState as ChainState)
      ? { chainState: raw.chainState as ChainState }
      : {}),
  };
}

export function higherPriorityAction(
  left: SchoolActionReason,
  right: SchoolActionReason,
): SchoolActionReason {
  return SCHOOL_ACTION_PRIORITY.indexOf(left) <= SCHOOL_ACTION_PRIORITY.indexOf(right) ? left : right;
}

/**
 * Passive captures (extension journal, no LMS session) must not hide a
 * human-actionable active-crawl barrier. After Learnbox `auth_required`, the
 * daemon pauses the adapter and still runs the passive engine — that path
 * otherwise overwrites `reauth_required` with `connector_stale`.
 */
export function overlayPassiveStatus(
  previous: SchoolConnectionStatus | null,
  next: SchoolConnectionStatus,
): SchoolConnectionStatus {
  if (previous?.actionReason === "reauth_required" || previous?.actionReason === "challenge_paused") {
    return previous;
  }
  return next;
}

export function statusNeedsLearningAction(status: SchoolConnectionStatus): boolean {
  if (status.actionReason === "manual_learning_required") return true;

  // Preserve higher-priority states: re-auth, challenge pauses, and active
  // recipe repair must resolve before asking the student to teach pages.
  if (status.actionReason !== "none") return false;

  return (status.missingCapabilities?.length ?? 0) > 0;
}

export function statusNeedsStudentAction(status: SchoolConnectionStatus): boolean {
  const capabilityNeedsAttention = (status.capabilities ?? []).some((entry) =>
    entry.state === "reauth_required" || entry.state === "challenged",
  );
  return ["reauth_required", "challenge_paused", "connector_stale"].includes(status.actionReason)
    || statusNeedsLearningAction(status)
    || (status.incompleteCapabilities?.length ?? 0) > 0
    || capabilityNeedsAttention;
}
