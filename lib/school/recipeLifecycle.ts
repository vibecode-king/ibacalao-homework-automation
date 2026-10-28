// lib/school/recipeLifecycle.ts
// What happens after a repair is promoted.
//
// Promotion is a bet: a selector that agreed with the page twice is probably
// right. When that bet turns out wrong — the new selector suddenly extracts
// nothing, a fraction of what it used to, or a different set of items entirely
// — the connector must go back to the strategy that was working and refuse to
// make the same mistake again, rather than quietly producing confident
// nonsense until someone notices.

import type { ScrapedRecord } from "../watcher/types";
import type { StoredSchoolRecipe } from "./recipeStore";

export type RecipeRegression =
  /** The promoted recipe reads nothing where the old one still reads records. */
  | { reason: "zero_records"; before: number; after: number }
  /** It reads dramatically fewer items — a collection that lost most of itself. */
  | { reason: "record_count_collapse"; before: number; after: number }
  /** Same number of rows, far less information in each. */
  | { reason: "field_completeness_drop"; before: number; after: number }
  /** Both read records, but they are not the same school items. */
  | { reason: "identity_divergence"; before: number; after: number };

/** Below this share of the previous count, a collection has collapsed. */
const COLLAPSE_RATIO = 0.5;
/** Completeness may dip a little between page variants; this much is a signal. */
const COMPLETENESS_DROP = 0.25;

const OPTIONAL_FIELDS = ["subject", "detail", "url", "dueAt", "status", "grade"] as const;

/** Average share of optional academic fields actually filled in. */
export function fieldCompleteness(records: ScrapedRecord[]): number {
  if (records.length === 0) return 0;
  const total = records.reduce((sum, record) => {
    const filled = OPTIONAL_FIELDS.filter((field) => {
      const value = record[field];
      return typeof value === "string" && value.trim().length > 0;
    }).length;
    return sum + filled / OPTIONAL_FIELDS.length;
  }, 0);
  return total / records.length;
}

function identitySeeds(records: ScrapedRecord[]): Set<string> {
  const seeds = new Set<string>();
  for (const record of records) {
    const seed = record.sourceRecordId ?? record.platformId ?? record.url ?? record.title;
    if (seed) seeds.add(seed.trim().toLowerCase());
  }
  return seeds;
}

/**
 * Compares what the active recipe now reads against what the last known good
 * recipe reads from the same page. `comparison` is the shadow run: if the old
 * strategy finds nothing either, the page simply changed or emptied, and that
 * is not the new recipe's fault.
 */
export function detectRecipeRegression(
  active: ScrapedRecord[],
  comparison: ScrapedRecord[],
): RecipeRegression | null {
  if (comparison.length === 0) return null;

  if (active.length === 0) {
    return { reason: "zero_records", before: comparison.length, after: 0 };
  }
  if (active.length < comparison.length * COLLAPSE_RATIO) {
    return { reason: "record_count_collapse", before: comparison.length, after: active.length };
  }

  const activeSeeds = identitySeeds(active);
  const comparisonSeeds = identitySeeds(comparison);
  if (activeSeeds.size > 0 && comparisonSeeds.size > 0) {
    const shared = Array.from(activeSeeds).filter((seed) => comparisonSeeds.has(seed)).length;
    if (shared === 0) {
      return { reason: "identity_divergence", before: comparisonSeeds.size, after: activeSeeds.size };
    }
  }

  const activeCompleteness = fieldCompleteness(active);
  const comparisonCompleteness = fieldCompleteness(comparison);
  if (comparisonCompleteness - activeCompleteness > COMPLETENESS_DROP) {
    return { reason: "field_completeness_drop", before: comparisonCompleteness, after: activeCompleteness };
  }

  return null;
}

/**
 * Restores the last known good recipe and records why the promoted one failed.
 *
 * The failed version is quarantined rather than forgotten: without that, the
 * same structural evidence would produce the same candidate on the next page
 * view and promote it all over again.
 */
export function rollbackToLastKnownGood(
  stored: StoredSchoolRecipe,
  regression: RecipeRegression,
  at: string,
): StoredSchoolRecipe | null {
  const lastKnownGood = stored.lastKnownGood;
  if (!lastKnownGood) return null;

  const { pendingRepair: _pendingRepair, lastKnownGood: _lastKnownGood, ...base } = stored;
  return {
    ...base,
    recipe: lastKnownGood.recipe,
    version: lastKnownGood.version,
    confidence: lastKnownGood.confidence,
    structuralSignature: lastKnownGood.structuralSignature,
    ...(lastKnownGood.scraplingSignature ? { scraplingSignature: lastKnownGood.scraplingSignature } : {}),
    updatedAt: at,
    quarantined: [
      ...(stored.quarantined ?? []),
      { version: stored.version, reason: regression.reason, at },
    ].slice(-10),
  };
}

export function isQuarantinedVersion(stored: StoredSchoolRecipe, version: string): boolean {
  return (stored.quarantined ?? []).some((entry) => entry.version === version);
}
