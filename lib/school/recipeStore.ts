import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { writeFileAtomic } from "./atomicFile";
import type { ElementSignature } from "./repair";
import type { SchoolDomCardEvidence, SchoolRecipe } from "./types";

export type DomStructuralSignature = {
  tag: string;
  classTokens: string[];
  attributeNames: string[];
  role?: string;
  childTags: string[];
};

export type StoredRecipeSnapshot = {
  recipe: SchoolRecipe;
  version: string;
  confidence: number;
  updatedAt: string;
  structuralSignature: DomStructuralSignature;
  scraplingSignature?: ElementSignature;
};

export type PendingSchoolRepair = {
  recipe: SchoolRecipe;
  version: string;
  confidence: number;
  firstObservedAt: string;
  lastObservedAt: string;
  observations: number;
  structuralSignature: DomStructuralSignature;
};

export type QuarantinedRecipeVersion = {
  version: string;
  reason: string;
  at: string;
};

export type StoredSchoolRecipe = {
  id: string;
  recipe: SchoolRecipe;
  version: string;
  confidence: number;
  learnedAt: string;
  updatedAt: string;
  structuralSignature: DomStructuralSignature;
  scraplingSignature?: ElementSignature;
  lastKnownGood?: StoredRecipeSnapshot;
  pendingRepair?: PendingSchoolRepair;
  /** Versions that were promoted, regressed, and must never be promoted again.
   *  See lib/school/recipeLifecycle.ts. */
  quarantined?: QuarantinedRecipeVersion[];
};

/**
 * The promotion contract for a validated repair candidate.
 *
 * A selector that matches once may just be a page that happens to render
 * differently today, so a candidate has to be seen on a second, independent
 * observation before it may replace the active recipe. Re-reading the same
 * capture does not count, and a different candidate restarts the count — a
 * selector that keeps flapping between shapes can never accumulate evidence.
 */
export function stageRepairCandidate(
  previous: PendingSchoolRepair | undefined,
  candidate: Omit<PendingSchoolRepair, "firstObservedAt" | "lastObservedAt" | "observations">,
  observedAt: string,
  options: { quarantined?: QuarantinedRecipeVersion[] } = {},
): { promote: boolean; pendingRepair: PendingSchoolRepair } {
  const sameCandidate = previous?.version === candidate.version;
  const newObservation = previous?.lastObservedAt !== observedAt;
  // A version that already regressed once stays refused, however convincing the
  // page looks this time.
  const quarantined = (options.quarantined ?? []).some((entry) => entry.version === candidate.version);
  const promote = Boolean(!quarantined && sameCandidate && newObservation && previous && previous.observations >= 1);
  return {
    promote,
    pendingRepair: {
      ...candidate,
      firstObservedAt: sameCandidate && previous ? previous.firstObservedAt : observedAt,
      lastObservedAt: observedAt,
      observations: sameCandidate && previous
        ? previous.observations + (newObservation ? 1 : 0)
        : 1,
    },
  };
}

export type SchoolRecipeBundle = {
  schemaVersion: 1;
  sourceKey: string;
  origin: string;
  updatedAt: string;
  recipes: StoredSchoolRecipe[];
};

type StoreFile = {
  schemaVersion: 1;
  sources: Record<string, SchoolRecipeBundle>;
};

export const DEFAULT_SCHOOL_RECIPE_FILE = join(homedir(), ".ibacalao", "school", "recipes.json");

function emptyStore(): StoreFile {
  return { schemaVersion: 1, sources: {} };
}

function parseStoreFile(file: string): StoreFile | null {
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8")) as StoreFile;
    return parsed?.schemaVersion === 1 && parsed.sources && typeof parsed.sources === "object" ? parsed : null;
  } catch {
    return null;
  }
}

function backupFile(file: string): string {
  return `${file}.bak`;
}

function readStore(file = DEFAULT_SCHOOL_RECIPE_FILE): StoreFile {
  if (!existsSync(file)) return emptyStore();
  const current = parseStoreFile(file);
  if (current) return current;
  const backup = parseStoreFile(backupFile(file));
  if (backup) return backup;
  throw new Error(`school_recipe_store_corrupt:${file}`);
}

export function loadRecipeBundle(
  sourceKey: string,
  origin: string,
  file = DEFAULT_SCHOOL_RECIPE_FILE,
): SchoolRecipeBundle {
  const stored = readStore(file).sources[sourceKey];
  if (stored?.origin === origin && Array.isArray(stored.recipes)) return stored;
  return { schemaVersion: 1, sourceKey, origin, updatedAt: new Date(0).toISOString(), recipes: [] };
}

export function saveRecipeBundle(bundle: SchoolRecipeBundle, file = DEFAULT_SCHOOL_RECIPE_FILE): void {
  const store = readStore(file);
  store.sources[bundle.sourceKey] = bundle;
  mkdirSync(dirname(file), { recursive: true });
  if (parseStoreFile(file)) copyFileSync(file, backupFile(file));
  writeFileAtomic(file, JSON.stringify(store, null, 2));
}

export function structuralSignature(card: SchoolDomCardEvidence): DomStructuralSignature {
  const attributes = card.attributes ?? {};
  return {
    tag: card.tag,
    classTokens: Array.from(new Set(card.classTokens ?? [])).sort(),
    attributeNames: Object.keys(attributes).filter((key) => key !== "id").sort(),
    ...(typeof attributes.role === "string" ? { role: attributes.role } : {}),
    childTags: [...(card.childTags ?? [])],
  };
}

export function recipeVersion(recipe: SchoolRecipe): string {
  return createHash("sha256").update(JSON.stringify(recipe)).digest("hex").slice(0, 12);
}

export function recipeId(recipe: SchoolRecipe): string {
  return createHash("sha256")
    .update([recipe.entity, recipe.source.container ?? "", recipe.source.selector ?? ""].join("\u0000"))
    .digest("hex")
    .slice(0, 16);
}
