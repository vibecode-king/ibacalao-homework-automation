import type { ScrapedRecord } from "../watcher/types";
import { classifyDomCard, recordFromCard, type DomSnapshotObservation } from "./evidence";
import type { DomStructuralSignature, StoredSchoolRecipe } from "./recipeStore";
import { structuralSignature } from "./recipeStore";
import type { SchoolDomCardEvidence, SchoolRecipe } from "./types";
import { classifySchoolPage } from "./pageClassifier";

export type RecipeRunResult = {
  records: ScrapedRecord[];
  matchedCards: SchoolDomCardEvidence[];
  observed: boolean;
  hasExpectedFields: boolean;
  visibleDataAgrees: boolean;
};

function latestForPath(snapshots: DomSnapshotObservation[], path: string): DomSnapshotObservation | undefined {
  return [...snapshots].reverse().find((snapshot) => snapshot.payload.path === path);
}

function expectedFieldPresent(record: ScrapedRecord, field: string): boolean {
  const key = field as keyof ScrapedRecord;
  const value = record[key];
  return typeof value === "string" && value.trim().length > 0;
}

export function runDomRecipe(
  stored: StoredSchoolRecipe,
  snapshots: DomSnapshotObservation[],
  origin: string,
): RecipeRunResult {
  const recipe = stored.recipe;
  const routePath = recipe.source.container;
  if (!routePath || !recipe.source.selector) {
    return { records: [], matchedCards: [], observed: false, hasExpectedFields: false, visibleDataAgrees: false };
  }
  const snapshot = latestForPath(snapshots, routePath);
  if (!snapshot) {
    return { records: [], matchedCards: [], observed: false, hasExpectedFields: false, visibleDataAgrees: false };
  }
  const cards = (snapshot.payload.cards ?? []).filter(
    (card) => card.groupSelector === recipe.source.selector || card.selector === recipe.source.selector,
  );
  const pageRole = classifySchoolPage(snapshot);
  const records = cards.flatMap((card) => {
    const record = recordFromCard(recipe.entity, card, origin, routePath, pageRole, snapshot.observedAt);
    return record ? [record] : [];
  });
  const required = Object.keys(recipe.fields).filter((field) => field !== "sourceRecordId");
  const hasExpectedFields = records.length > 0 && records.every((record) => required.every((field) => expectedFieldPresent(record, field)));
  const visibleDataAgrees = records.length > 0 && records.every((record, index) => {
    const card = cards[index];
    return Boolean(card && card.text.toLowerCase().includes(record.title.toLowerCase().slice(0, Math.min(40, record.title.length))));
  });
  return { records, matchedCards: cards, observed: true, hasExpectedFields, visibleDataAgrees };
}

function setSimilarity(left: string[], right: string[]): number | null {
  const a = new Set(left);
  const b = new Set(right);
  if (a.size === 0 && b.size === 0) return null;
  const union = new Set(Array.from(a).concat(Array.from(b)));
  let intersection = 0;
  for (const item of Array.from(a)) if (b.has(item)) intersection += 1;
  return union.size ? intersection / union.size : null;
}

function sequenceSimilarity(left: string[], right: string[]): number | null {
  if (left.length === 0 && right.length === 0) return null;
  const max = Math.max(left.length, right.length);
  let equal = 0;
  for (let index = 0; index < Math.min(left.length, right.length); index += 1) {
    if (left[index] === right[index]) equal += 1;
  }
  return max ? equal / max : null;
}

export function structuralSimilarity(signature: DomStructuralSignature, card: SchoolDomCardEvidence): number {
  const candidate = structuralSignature(card);
  const scores: Array<[number, number | null]> = [
    [0.35, signature.tag === candidate.tag ? 1 : 0],
    // Class names are the most common thing a frontend rebuild changes, so
    // they are evidence, not identity. Structural children and attribute shape
    // carry more weight for repair confidence.
    [0.05, setSimilarity(signature.classTokens, candidate.classTokens)],
    [0.2, setSimilarity(signature.attributeNames, candidate.attributeNames)],
    [0.1, signature.role || candidate.role ? (signature.role === candidate.role ? 1 : 0) : null],
    [0.3, sequenceSimilarity(signature.childTags, candidate.childTags)],
  ];
  let weight = 0;
  let total = 0;
  for (const [partWeight, score] of scores) {
    if (score === null) continue;
    weight += partWeight;
    total += partWeight * score;
  }
  return weight > 0 ? total / weight : 0;
}

export function bestStructuralRepairCandidate(
  stored: StoredSchoolRecipe,
  snapshot: DomSnapshotObservation,
): { card: SchoolDomCardEvidence; confidence: number; candidateCount: number } | null {
  const candidates = (snapshot.payload.cards ?? []).map((card) => ({
    card,
    confidence: structuralSimilarity(stored.structuralSignature, card),
  }));
  if (!candidates.length) return null;
  const best = Math.max(...candidates.map((candidate) => candidate.confidence));
  const winners = candidates.filter((candidate) => Math.abs(candidate.confidence - best) < 0.0001);
  // Several rows from the same repeated card pattern are one repair target,
  // not an ambiguity. Different winning group selectors are ambiguous and
  // therefore still fail closed.
  const winningGroups = new Set(winners.map((candidate) => candidate.card.groupSelector));
  return { card: winners[0].card, confidence: best, candidateCount: winningGroups.size };
}

export function inferDomRecipes(
  snapshots: DomSnapshotObservation[],
): Array<{ recipe: SchoolRecipe; card: SchoolDomCardEvidence; confidence: number }> {
  type Cluster = {
    entity: SchoolRecipe["entity"];
    routePath: string;
    groupSelector: string;
    observations: Array<{ card: SchoolDomCardEvidence; record: ScrapedRecord; confidence: number }>;
  };
  const clusters = new Map<string, Cluster>();
  const entitiesByGroup = new Map<string, Set<SchoolRecipe["entity"]>>();
  const results: Array<{ recipe: SchoolRecipe; card: SchoolDomCardEvidence; confidence: number }> = [];
  for (const snapshot of snapshots) {
    const routePath = snapshot.payload.path;
    const pageRole = classifySchoolPage(snapshot);
    for (const card of snapshot.payload.cards ?? []) {
      const classified = classifyDomCard(card, routePath, pageRole);
      if (!classified || classified.confidence < 0.9) continue;
      const record = recordFromCard(classified.entity, card, snapshot.origin, routePath, pageRole, snapshot.observedAt);
      if (!record) continue;
      const groupKey = `${routePath}\u0000${card.groupSelector}`;
      const entities = entitiesByGroup.get(groupKey) ?? new Set<SchoolRecipe["entity"]>();
      entities.add(classified.entity);
      entitiesByGroup.set(groupKey, entities);

      const key = `${classified.entity}\u0000${groupKey}`;
      const cluster = clusters.get(key) ?? {
        entity: classified.entity,
        routePath,
        groupSelector: card.groupSelector,
        observations: [],
      };
      cluster.observations.push({ card, record, confidence: classified.confidence });
      clusters.set(key, cluster);
    }
  }

  for (const cluster of Array.from(clusters.values())) {
    const groupKey = `${cluster.routePath}\u0000${cluster.groupSelector}`;
    // One structural card pattern producing different academic entity types is
    // not safe enough to automate. Keep it in manual learning instead of
    // teaching contradictory recipes for the same selector.
    if ((entitiesByGroup.get(groupKey)?.size ?? 0) !== 1) continue;
    const representative = cluster.observations[0];
    if (!representative) continue;
    const fields: Record<string, string> = { title: "$.title" };
    for (const name of ["subject", "detail", "dueAt", "status", "grade"] as const) {
      if (cluster.observations.every((observation) => Boolean(observation.record[name]))) fields[name] = `$.${name}`;
    }
    results.push({
      recipe: {
        schemaVersion: 1,
        entity: cluster.entity,
        source: { kind: "observed-dom", container: cluster.routePath, selector: cluster.groupSelector },
        fields,
      },
      card: representative.card,
      confidence: Math.min(...cluster.observations.map((observation) => observation.confidence)),
    });
  }
  return results;
}
