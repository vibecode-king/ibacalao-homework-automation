import { dirname, join } from "node:path";
import { homedir } from "node:os";
import type { ScrapedRecord } from "../watcher/types";
import {
  detectPassiveBarrier,
  PASSIVE_HEALTH_FRESHNESS_MS,
  attachmentDownloadsFromCaptures,
  jsonShapesFromCaptures,
  navigationEdgesFromCaptures,
  readRecentCaptures,
  snapshotsFromCaptures,
  type DomSnapshotObservation,
  type NavigationEdgeObservation,
  type StoredCapture,
} from "./evidence";
import { extractSchoolAttachment } from "./attachments";
import type { DatabaseSync } from "node:sqlite";
import {
  CAPABILITY_FOR_ENTITY,
  summarizeCapabilityHealth,
  type CapabilityHealth,
  type CapabilityObservation,
} from "./capabilityHealth";
import {
  ensurePlatformGraphSchema,
  recordPlatformEdges,
  recordPlatformNode,
  type PlatformNodeObservation,
} from "./platformGraph";
import { classifyCollectionCompleteness } from "./completeness";
import { blocksRepairEvidence, classifyEmptyObservation } from "./emptyState";
import { detectRecipeRegression, fieldCompleteness, rollbackToLastKnownGood } from "./recipeLifecycle";
import { mirrorCapturesToJournal, openSchoolJournal, readJournalCaptures } from "./journal";
import { hypothesizeStructuredEndpoint } from "./structuredResponse";
import { enrichCanonicalEntityFromAttachment, reconcileSchoolRecords } from "./entityStore";
import {
  bestStructuralRepairCandidate,
  inferDomRecipes,
  runDomRecipe,
} from "./genericRunner";
import { activateValidatedRepair } from "./recipe";
import type { AdaptiveDomRepairResult } from "./repair";
import { repairDisposition } from "./repair";
import {
  loadRecipeBundle,
  recipeId,
  recipeVersion,
  saveRecipeBundle,
  stageRepairCandidate,
  structuralSignature,
  type SchoolRecipeBundle,
  type StoredSchoolRecipe,
} from "./recipeStore";
import { runScraplingRepair, runScraplingSignature, type ScraplingSidecarOptions } from "./scraplingSidecar";
import type { SchoolActionCapability, SchoolConnectionStatus, SchoolRecipe } from "./types";
import { validateAdaptiveRepair } from "./validation";

const DEFAULT_CAPTURE_FILE = join(homedir(), ".ibacalao", "school-bridge", "captures.ndjson");
const REQUIRED_CAPABILITIES: SchoolActionCapability[] = [
  "assignments",
  "messages",
  "grades",
  "deadlines",
  "submissions",
];

export type PassiveSchoolSource = {
  sourceKey: string;
  origin: string;
  platformLabel: string;
  schoolLabel?: string;
};

export type PassiveLearningWindow = {
  startedAt: string;
  missingCapabilities: SchoolActionCapability[];
};

export type PassiveEngineOptions = {
  captureFile?: string;
  recipeFile?: string;
  entityFile?: string;
  nowMs?: number;
  scrapling?: ScraplingSidecarOptions;
  /** Production passes null unless native Learn explicitly armed a session. */
  learningWindow?: PassiveLearningWindow | null;
  /** Shadow mode: mirror NDJSON into SQLite, then prefer the journal for
   *  extraction so ACK/checkpoint semantics can be tested without a live LMS. */
  journalFile?: string;
  /** Last known per-capability health, so failure streaks survive a poll where
   *  the student never opened that part of the portal. */
  previousCapabilities?: CapabilityHealth[];
};

export type PassiveEvaluation = {
  records: ScrapedRecord[];
  status: SchoolConnectionStatus;
  learnedRecipes: number;
  repairedRecipes: number;
  observedCaptures: number;
};

function strongerChangeKind(
  left: ScrapedRecord["changeKind"],
  right: ScrapedRecord["changeKind"],
): ScrapedRecord["changeKind"] {
  const rank = { unchanged: 0, enriched: 1, source_changed: 2, new_entity: 3 } as const;
  if (!left) return right;
  if (!right) return left;
  return rank[right] > rank[left] ? right : left;
}

function latestSnapshotForRecipe(
  snapshots: DomSnapshotObservation[],
  recipe: SchoolRecipe,
): DomSnapshotObservation | undefined {
  const path = recipe.source.container;
  if (!path) return undefined;
  return [...snapshots].reverse().find((snapshot) => snapshot.payload.path === path);
}

function capabilitiesFor(bundle: SchoolRecipeBundle): Set<SchoolActionCapability> {
  const result = new Set<SchoolActionCapability>();
  for (const stored of bundle.recipes) {
    switch (stored.recipe.entity) {
      case "assignment": result.add("assignments"); break;
      case "message": result.add("messages"); break;
      case "grade": result.add("grades"); break;
      case "deadline": result.add("deadlines"); break;
      case "submission": result.add("submissions"); break;
    }
    if (stored.recipe.fields.dueAt) result.add("deadlines");
  }
  return result;
}

function capabilitiesForRecipe(recipe: SchoolRecipe): Set<SchoolActionCapability> {
  const result = new Set<SchoolActionCapability>();
  switch (recipe.entity) {
    case "assignment": result.add("assignments"); break;
    case "message": result.add("messages"); break;
    case "grade": result.add("grades"); break;
    case "deadline": result.add("deadlines"); break;
    case "submission": result.add("submissions"); break;
  }
  if (recipe.fields.dueAt) result.add("deadlines");
  return result;
}

function snapshotsForLearning(
  snapshots: DomSnapshotObservation[],
  window: PassiveEngineOptions["learningWindow"],
): DomSnapshotObservation[] {
  if (window === undefined) return snapshots;
  if (window === null) return [];
  const startedAtMs = Date.parse(window.startedAt);
  if (!Number.isFinite(startedAtMs)) return [];
  return snapshots.filter((snapshot) => Date.parse(snapshot.observedAt) >= startedAtMs);
}

async function enrichWithScraplingSignature(
  stored: StoredSchoolRecipe,
  snapshot: DomSnapshotObservation | undefined,
  captureId: string,
  options: PassiveEngineOptions,
): Promise<StoredSchoolRecipe> {
  if (!snapshot?.payload.sanitizedHtml) return stored;
  const result = await runScraplingSignature({
    currentHtml: snapshot.payload.sanitizedHtml,
    currentUrl: new URL(snapshot.payload.path, snapshot.origin).toString(),
    captureId,
  }, options.scrapling);
  return result.ok ? { ...stored, scraplingSignature: result.signature } : stored;
}

function candidateRepairResult(
  stored: StoredSchoolRecipe,
  selector: string,
  confidence: number,
  candidateCount: number,
  captureId?: string,
): Extract<AdaptiveDomRepairResult, { ok: true }> {
  return {
    ok: true,
    confidence,
    evidence: { candidateCount, ...(captureId ? { captureId } : {}) },
    candidateRecipe: {
      ...stored.recipe,
      source: { ...stored.recipe.source, selector },
    },
  };
}

function updateStoredRecipe(
  stored: StoredSchoolRecipe,
  recipe: SchoolRecipe,
  card: Parameters<typeof structuralSignature>[0],
  confidence: number,
  now: string,
): StoredSchoolRecipe {
  const nextVersion = recipeVersion(recipe);
  const changedVersion = nextVersion !== stored.version;
  const { pendingRepair: _pendingRepair, ...base } = stored;
  return {
    ...base,
    ...(changedVersion ? {
      lastKnownGood: {
        recipe: stored.recipe,
        version: stored.version,
        confidence: stored.confidence,
        updatedAt: stored.updatedAt,
        structuralSignature: stored.structuralSignature,
        ...(stored.scraplingSignature ? { scraplingSignature: stored.scraplingSignature } : {}),
      },
    } : {}),
    recipe,
    version: nextVersion,
    confidence,
    updatedAt: now,
    structuralSignature: structuralSignature(card),
  };
}

async function tryRepair(
  stored: StoredSchoolRecipe,
  snapshot: DomSnapshotObservation,
  snapshots: DomSnapshotObservation[],
  source: PassiveSchoolSource,
  options: PassiveEngineOptions,
): Promise<{ stored: StoredSchoolRecipe; repaired: boolean; changed: boolean; disposition: "activate" | "observe" | "manual_learning" }> {
  const stageValidatedCandidate = async (
    recipe: SchoolRecipe,
    card: Parameters<typeof structuralSignature>[0],
    confidence: number,
  ): Promise<{ stored: StoredSchoolRecipe; repaired: boolean; changed: boolean; disposition: "activate" | "observe" }> => {
    const previous = stored.pendingRepair;
    const { promote, pendingRepair } = stageRepairCandidate(
      previous,
      { recipe, version: recipeVersion(recipe), confidence, structuralSignature: structuralSignature(card) },
      snapshot.observedAt,
      { ...(stored.quarantined ? { quarantined: stored.quarantined } : {}) },
    );
    if (promote) {
      const promoted = await enrichWithScraplingSignature(
        updateStoredRecipe(stored, recipe, card, confidence, new Date(options.nowMs ?? Date.now()).toISOString()),
        snapshot,
        card.captureId,
        options,
      );
      return { stored: promoted, repaired: true, changed: true, disposition: "activate" };
    }
    const changed = JSON.stringify(previous) !== JSON.stringify(pendingRepair);
    return { stored: { ...stored, pendingRepair }, repaired: false, changed, disposition: "observe" };
  };
  const structural = bestStructuralRepairCandidate(stored, snapshot);
  if (structural) {
    const result = candidateRepairResult(
      stored,
      structural.card.groupSelector,
      structural.confidence,
      structural.candidateCount,
      structural.card.captureId,
    );
    if (repairDisposition(result) === "activate") {
      const provisional = updateStoredRecipe(stored, result.candidateRecipe, structural.card, result.confidence, new Date(options.nowMs ?? Date.now()).toISOString());
      const run = runDomRecipe(provisional, snapshots, source.origin);
      const validation = validateAdaptiveRepair({
        result,
        recordCount: run.records.length,
        hasExpectedFields: run.hasExpectedFields,
        visibleDataAgrees: run.visibleDataAgrees,
      });
      const recipe = activateValidatedRepair(result, validation);
      if (recipe) {
        return stageValidatedCandidate(recipe, structural.card, result.confidence);
      }
    }
  }

  if (stored.scraplingSignature && snapshot.payload.sanitizedHtml) {
    const scrapling = await runScraplingRepair({
      oldRecipe: stored.recipe,
      oldElementSignature: stored.scraplingSignature,
      currentHtml: snapshot.payload.sanitizedHtml,
      currentUrl: new URL(snapshot.payload.path, source.origin).toString(),
      expectedEntity: stored.recipe.entity,
    }, options.scrapling);
    if (scrapling.ok && scrapling.evidence.captureId) {
      const card = (snapshot.payload.cards ?? []).find((candidate) => candidate.captureId === scrapling.evidence.captureId);
      if (card) {
        const result = candidateRepairResult(stored, card.groupSelector, scrapling.confidence, scrapling.evidence.candidateCount, card.captureId);
        const provisional = updateStoredRecipe(stored, result.candidateRecipe, card, result.confidence, new Date(options.nowMs ?? Date.now()).toISOString());
        const run = runDomRecipe(provisional, snapshots, source.origin);
        const validation = validateAdaptiveRepair({
          result,
          recordCount: run.records.length,
          hasExpectedFields: run.hasExpectedFields,
          visibleDataAgrees: run.visibleDataAgrees,
        });
        const recipe = activateValidatedRepair(result, validation);
        if (recipe) {
          return stageValidatedCandidate(recipe, card, result.confidence);
        }
        return { stored, repaired: false, changed: false, disposition: validation.disposition };
      }
    }
    if (scrapling.ok) return { stored, repaired: false, changed: false, disposition: repairDisposition(scrapling) };
  }

  if (structural) {
    const fallback = candidateRepairResult(stored, structural.card.groupSelector, structural.confidence, structural.candidateCount);
    return { stored, repaired: false, changed: false, disposition: repairDisposition(fallback) };
  }
  return { stored, repaired: false, changed: false, disposition: "manual_learning" };
}

/**
 * Records what this evaluation learned about the portal's shape. Best effort:
 * the graph is accumulated evidence, and losing a round of it costs nothing the
 * next page view will not re-teach.
 */
export function refinePlatformGraph(
  journalFile: string | undefined,
  sourceKey: string,
  nodes: PlatformNodeObservation[],
  edges: NavigationEdgeObservation[],
): void {
  if (!journalFile || (nodes.length === 0 && edges.length === 0)) return;
  let db: DatabaseSync | null = null;
  try {
    const journal = openSchoolJournal(journalFile);
    db = journal;
    ensurePlatformGraphSchema(journal);
    for (const node of nodes) recordPlatformNode(journal, sourceKey, node);
    recordPlatformEdges(journal, sourceKey, edges);
  } catch (error) {
    console.warn("[school] platform graph update failed:", error instanceof Error ? error.message : error);
  } finally {
    db?.close();
  }
}

/**
 * Shadow-runs the last known good recipe next to the active one and undoes the
 * promotion if the active one has regressed. Returns null when nothing is wrong
 * or when there is no earlier strategy to fall back to.
 */
function rollbackIfRegressed(
  stored: StoredSchoolRecipe,
  snapshots: DomSnapshotObservation[],
  origin: string,
  at: string,
): StoredSchoolRecipe | null {
  const lastKnownGood = stored.lastKnownGood;
  if (!lastKnownGood) return null;

  const active = runDomRecipe(stored, snapshots, origin);
  if (!active.observed) return null;
  const shadow = runDomRecipe(
    { ...stored, recipe: lastKnownGood.recipe, version: lastKnownGood.version, structuralSignature: lastKnownGood.structuralSignature },
    snapshots,
    origin,
  );

  const regression = detectRecipeRegression(active.records, shadow.records);
  if (!regression) return null;
  const restored = rollbackToLastKnownGood(stored, regression, at);
  if (restored) {
    console.warn(`[school] rolled back recipe ${stored.id}: ${regression.reason} (${regression.before} → ${regression.after})`);
  }
  return restored;
}

function loadObservationCaptures(
  captureFile: string,
  captureOptions: { sourceKey: string; origin: string; nowMs: number },
  journalFile?: string,
): StoredCapture[] {
  if (journalFile) {
    let db;
    try {
      db = openSchoolJournal(journalFile);
      const fromJournal = readJournalCaptures(db, captureOptions);
      if (fromJournal.length > 0) return fromJournal;
    } catch {
      // Journal is still a shadow of NDJSON; a read failure must not skip extraction.
    } finally {
      db?.close();
    }
  }
  return readRecentCaptures(captureFile, captureOptions);
}

export async function evaluatePassiveSchoolSource(
  source: PassiveSchoolSource,
  options: PassiveEngineOptions = {},
): Promise<PassiveEvaluation> {
  const nowMs = options.nowMs ?? Date.now();
  const now = new Date(nowMs).toISOString();
  const captureFile = options.captureFile ?? DEFAULT_CAPTURE_FILE;
  const captureOptions = {
    sourceKey: source.sourceKey,
    origin: source.origin,
    nowMs,
  };
  mirrorCapturesToJournal(captureFile, captureOptions, options.journalFile);
  const captures = loadObservationCaptures(captureFile, captureOptions, options.journalFile);
  const snapshots = snapshotsFromCaptures(captures);
  const navigationEdges = navigationEdgesFromCaptures(captures);
  const attachmentDownloads = attachmentDownloadsFromCaptures(captures);
  const jsonShapes = jsonShapesFromCaptures(captures);
  let bundle = loadRecipeBundle(source.sourceKey, source.origin, options.recipeFile);
  const barrier = detectPassiveBarrier(captureFile, captureOptions);
  if (barrier) {
    const learnedCapabilities = capabilitiesFor(bundle);
    const missingCapabilities = REQUIRED_CAPABILITIES.filter((capability) => !learnedCapabilities.has(capability));
    const confidences = bundle.recipes.map((stored) => stored.confidence);
    const recipeConfidence = confidences.length ? Math.min(...confidences) : undefined;
    return {
      records: [],
      learnedRecipes: 0,
      repairedRecipes: 0,
      observedCaptures: snapshots.length,
      status: {
        sourceKey: source.sourceKey,
        platformLabel: source.platformLabel,
        ...(source.schoolLabel ? { schoolLabel: source.schoolLabel } : {}),
        connected: barrier.reason !== "reauth_required",
        syncMode: "passive_browser",
        actionReason: barrier.reason,
        lastObservedAt: barrier.observedAt,
        recipe: bundle.recipes.length > 0
          ? {
              state: "stale",
              ...(recipeConfidence !== undefined ? { confidence: recipeConfidence } : {}),
              version: bundle.updatedAt,
            }
          : { state: "missing" },
        ...(missingCapabilities.length ? { missingCapabilities } : {}),
      },
    };
  }
  let changed = false;
  let learnedRecipes = 0;
  let repairedRecipes = 0;

  // New recipes are learned only from the explicitly armed local Learn window.
  // Existing recipes still run and repair from ordinary passive browsing.
  const learningSnapshots = snapshotsForLearning(snapshots, options.learningWindow);
  const requestedCapabilities = options.learningWindow && options.learningWindow !== null
    ? new Set(options.learningWindow.missingCapabilities)
    : null;

  // Learning is only allowed when there is no existing recipe for the same
  // entity/page. A selector change on an existing recipe must pass repair
  // validation rather than sneaking in as a newly inferred recipe.
  for (const inferred of inferDomRecipes(learningSnapshots)) {
    if (requestedCapabilities) {
      const inferredCapabilities = capabilitiesForRecipe(inferred.recipe);
      if (!Array.from(inferredCapabilities).some((capability) => requestedCapabilities.has(capability))) continue;
    }
    if (bundle.recipes.some((stored) =>
      stored.recipe.entity === inferred.recipe.entity
      && stored.recipe.source.container === inferred.recipe.source.container
    )) continue;
    const stored: StoredSchoolRecipe = {
      id: recipeId(inferred.recipe),
      recipe: inferred.recipe,
      version: recipeVersion(inferred.recipe),
      confidence: inferred.confidence,
      learnedAt: now,
      updatedAt: now,
      structuralSignature: structuralSignature(inferred.card),
    };
    const verification = runDomRecipe(stored, learningSnapshots, source.origin);
    if (
      verification.records.length <= 0
      || !verification.hasExpectedFields
      || !verification.visibleDataAgrees
    ) {
      continue;
    }
    const snapshot = [...learningSnapshots].reverse().find((candidate) =>
      candidate.payload.path === inferred.recipe.source.container
      && (candidate.payload.cards ?? []).some((card) => card.captureId === inferred.card.captureId)
    );
    bundle.recipes.push(await enrichWithScraplingSignature(stored, snapshot, inferred.card.captureId, options));
    learnedRecipes += 1;
    changed = true;
  }

  let unresolvedDisposition: "none" | "observe" | "manual_learning" = "none";
  const capabilityObservations: CapabilityObservation[] = [];
  const graphObservations: PlatformNodeObservation[] = [];
  for (const shape of jsonShapes) {
    const hypothesis = hypothesizeStructuredEndpoint(shape.endpointTemplate, shape.schema);
    if (!hypothesis) continue;
    graphObservations.push({
      path: shape.endpointTemplate,
      pageRole: "collection",
      capability: hypothesis.capability,
      observedAt: shape.observedAt,
      succeeded: true,
    });
  }
  for (let index = 0; index < bundle.recipes.length; index += 1) {
    let stored = bundle.recipes[index];
    // Every promoted recipe keeps being judged against the one it replaced. If
    // the newer strategy has started reading nothing, a fraction of the page,
    // or different items entirely, go back and refuse that version for good.
    const rolledBack = rollbackIfRegressed(stored, snapshots, source.origin, now);
    if (rolledBack) {
      bundle.recipes[index] = rolledBack;
      stored = rolledBack;
      changed = true;
    }
    const run = runDomRecipe(stored, snapshots, source.origin);
    const observedSnapshot = latestSnapshotForRecipe(snapshots, stored.recipe);
    if (observedSnapshot) {
      graphObservations.push({
        path: observedSnapshot.payload.path,
        pageRole: observedSnapshot.payload.pageRole ?? "unknown",
        capability: CAPABILITY_FOR_ENTITY[stored.recipe.entity],
        activeRecipeId: stored.id,
        candidateRecipeId: stored.pendingRepair?.version ?? null,
        observedAt: observedSnapshot.observedAt,
        succeeded: run.records.length > 0,
        fieldCompleteness: fieldCompleteness(run.records),
      });
    }
    const empty = run.observed && run.records.length === 0 && observedSnapshot
      ? classifyEmptyObservation(observedSnapshot, stored.recipe.entity)
      : undefined;
    capabilityObservations.push({
      recipe: stored,
      observed: run.observed,
      recordCount: run.records.length,
      ...(observedSnapshot ? { observedAt: observedSnapshot.observedAt } : {}),
      ...(empty ? { empty } : {}),
      ...(observedSnapshot
        ? { completeness: classifyCollectionCompleteness(observedSnapshot, { recordCount: run.records.length, ...(empty ? { empty } : {}) }) }
        : {}),
    });
    if (run.records.length > 0 && stored.pendingRepair) {
      const { pendingRepair: _pendingRepair, ...withoutPending } = stored;
      bundle.recipes[index] = withoutPending;
      changed = true;
      continue;
    }
    if (!run.observed || run.records.length > 0) continue;
    const snapshot = latestSnapshotForRecipe(snapshots, stored.recipe);
    if (!snapshot) continue;
    // Zero records is only evidence of a broken recipe when the page cannot
    // explain itself. A page that says it is empty, is still loading, or is not
    // this capability's page at all must not drive a repair.
    const emptyObservation = classifyEmptyObservation(snapshot, stored.recipe.entity);
    if (blocksRepairEvidence(emptyObservation)) {
      if (emptyObservation.state !== "valid_empty" && unresolvedDisposition === "none") {
        unresolvedDisposition = "observe";
      }
      continue;
    }
    const repair = await tryRepair(stored, snapshot, snapshots, source, options);
    if (repair.repaired) {
      bundle.recipes[index] = repair.stored;
      repairedRecipes += 1;
      changed = true;
    } else if (repair.changed) {
      bundle.recipes[index] = repair.stored;
      changed = true;
      if (repair.disposition === "observe" && unresolvedDisposition === "none") unresolvedDisposition = "observe";
    } else if (repair.disposition === "manual_learning") {
      unresolvedDisposition = "manual_learning";
    } else if (repair.disposition === "observe" && unresolvedDisposition === "none") {
      unresolvedDisposition = "observe";
    }
  }

  if (changed) {
    bundle = { ...bundle, updatedAt: now };
    saveRecipeBundle(bundle, options.recipeFile);
  }

  refinePlatformGraph(options.journalFile, source.sourceKey, graphObservations, navigationEdges);

  const records = bundle.recipes.flatMap((stored) => runDomRecipe(stored, snapshots, source.origin).records);
  const entityFile = options.entityFile ?? (options.recipeFile ? join(dirname(options.recipeFile), "entities.json") : undefined);
  const reconciled = reconcileSchoolRecords(source.sourceKey, source.origin, records, {
    ...(entityFile ? { file: entityFile } : {}),
    observedAt: now,
    navigationEdges,
  });
  const byCanonicalId = new Map<string, ScrapedRecord>();
  for (const record of reconciled.records) {
    const id = record.sourceRecordId ?? record.platformId;
    if (id) byCanonicalId.set(id, record);
  }
  for (const download of attachmentDownloads) {
    const extraction = await extractSchoolAttachment(download.payload.localPath);
    const enriched = enrichCanonicalEntityFromAttachment(
      source.sourceKey,
      source.origin,
      download,
      extraction,
      entityFile,
    );
    const id = enriched?.sourceRecordId ?? enriched?.platformId;
    if (!enriched || !id) continue;
    const existing = byCanonicalId.get(id);
    byCanonicalId.set(id, existing
      ? { ...existing, ...enriched, changeKind: strongerChangeKind(existing.changeKind, enriched.changeKind) }
      : enriched);
  }
  const uniqueRecords = Array.from(byCanonicalId.values());
  const learnedCapabilities = capabilitiesFor(bundle);
  const missingCapabilities = REQUIRED_CAPABILITIES.filter((capability) => !learnedCapabilities.has(capability));
  const confidences = bundle.recipes.map((stored) => stored.confidence);
  const recipeConfidence = confidences.length ? Math.min(...confidences) : undefined;
  const lastSnapshot = snapshots.at(-1);
  const lastObservedAt = lastSnapshot?.observedAt;
  const lastReceivedMs = lastSnapshot
    ? Date.parse(lastSnapshot.receivedAt ?? lastSnapshot.observedAt)
    : Number.NEGATIVE_INFINITY;
  const snapshotFresh = Number.isFinite(lastReceivedMs)
    && nowMs - lastReceivedMs >= 0
    && nowMs - lastReceivedMs <= PASSIVE_HEALTH_FRESHNESS_MS;
  const actionReason: SchoolConnectionStatus["actionReason"] = !snapshotFresh
    ? "connector_stale"
    : unresolvedDisposition === "manual_learning"
      ? "manual_learning_required"
      : unresolvedDisposition === "observe"
        ? "recipe_repairing"
        : missingCapabilities.length > 0
          ? "manual_learning_required"
          : "none";

  const capabilityHealth = summarizeCapabilityHealth(capabilityObservations, options.previousCapabilities);
  const incompleteCapabilities = capabilityHealth
    .filter((entry) => entry.completeness === "partial")
    .map((entry) => entry.capability);

  return {
    records: uniqueRecords,
    learnedRecipes,
    repairedRecipes,
    observedCaptures: snapshots.length,
    status: {
      sourceKey: source.sourceKey,
      platformLabel: source.platformLabel,
      ...(source.schoolLabel ? { schoolLabel: source.schoolLabel } : {}),
      connected: snapshotFresh,
      syncMode: "passive_browser",
      actionReason,
      ...(uniqueRecords.length > 0 ? { lastSuccessAt: lastObservedAt ?? now } : {}),
      ...(lastObservedAt ? { lastObservedAt } : {}),
      capabilities: capabilityHealth,
      recipe: bundle.recipes.length > 0
        ? {
            state: !snapshotFresh ? "stale" : unresolvedDisposition === "none" ? "healthy" : unresolvedDisposition === "observe" ? "repairing" : "stale",
            ...(recipeConfidence !== undefined ? { confidence: recipeConfidence } : {}),
            version: bundle.updatedAt,
          }
        : { state: "missing" },
      ...(missingCapabilities.length ? { missingCapabilities } : {}),
      ...(incompleteCapabilities.length ? { incompleteCapabilities } : {}),
    },
  };
}
