// lib/watcher/platformMapSync.ts
// The daemon's side of the shared platform map: download the approved map as
// candidates, propose what this Mac learned, report pages that stopped reading.
//
// Every function here is best effort and never throws. The watcher's own
// crawl and upload must behave exactly the same when the server has no map,
// is unreachable, or rejects a proposal.

import type { CapabilityHealth } from "../school/capabilityHealth";
import { CAPABILITY_FOR_ENTITY } from "../school/capabilityHealth";
import { openSchoolJournal } from "../school/journal";
import { ensurePlatformGraphSchema, readPlatformEdges, readPlatformNodes } from "../school/platformGraph";
import {
  exportPlatformMap,
  parsePlatformMap,
  platformMapFingerprint,
  sanitizeFailureExcerpt,
  stageDownloadedMap,
} from "../school/platformMap";
import { loadRecipeBundle, saveRecipeBundle } from "../school/recipeStore";

export type PlatformMapTarget = {
  platformId: string;
  /** Only platforms discovery recognizes share maps; an unknown portal's id
   *  is derived from its own domain and would identify the school. */
  recognized?: boolean;
  origin: string;
  sourceKey: string;
  journalFile: string;
  recipeFile?: string;
};

type FetchLike = (url: string, init?: RequestInit) => Promise<Response>;

const downloadedSources = new Set<string>();
const proposedFingerprints = new Map<string, string>();
const reportedFailures = new Set<string>();
const approvedVersionIds = new Map<string, string>();

const warn = (what: string, error: unknown) =>
  console.warn(`[platform-map] ${what} failed:`, error instanceof Error ? error.message : error);

/** Once per daemon run per source. Returns how many recipes were staged. */
export async function downloadPlatformMapOnce(
  target: PlatformMapTarget,
  baseUrl: string,
  token: string,
  fetchImpl: FetchLike = fetch,
): Promise<number> {
  if (!target.recognized || downloadedSources.has(target.sourceKey)) return 0;
  downloadedSources.add(target.sourceKey);
  try {
    const response = await fetchImpl(
      `${baseUrl}/api/watcher/platform-map/${encodeURIComponent(target.platformId)}`,
      { headers: { authorization: `Bearer ${token}` } },
    );
    if (!response.ok) return 0;
    const body = (await response.json()) as { versionId?: unknown; map?: unknown };
    const map = parsePlatformMap(body?.map);
    if (!map || map.platformId !== target.platformId) return 0;
    if (typeof body.versionId === "string") approvedVersionIds.set(target.platformId, body.versionId);
    const result = stageDownloadedMap(
      loadRecipeBundle(target.sourceKey, target.origin, target.recipeFile),
      map,
      new Date().toISOString(),
    );
    if (result.staged > 0) {
      saveRecipeBundle(result.bundle, target.recipeFile);
      console.log(`[platform-map] staged ${result.staged} shared ${target.platformId} recipe(s) as candidates`);
    }
    return result.staged;
  } catch (error) {
    warn("download", error);
    return 0;
  }
}

/** Posts this Mac's map when its structure changed since the last proposal. */
export async function proposePlatformMap(
  target: PlatformMapTarget,
  baseUrl: string,
  token: string,
  fetchImpl: FetchLike = fetch,
): Promise<boolean> {
  if (!target.recognized) return false;
  let db: ReturnType<typeof openSchoolJournal> | null = null;
  try {
    db = openSchoolJournal(target.journalFile);
    ensurePlatformGraphSchema(db);
    const map = exportPlatformMap(
      target.platformId,
      readPlatformNodes(db, target.sourceKey),
      readPlatformEdges(db, target.sourceKey),
      loadRecipeBundle(target.sourceKey, target.origin, target.recipeFile),
    );
    db.close();
    db = null;
    if (map.nodes.length === 0 && map.recipes.length === 0) return false;
    const fingerprint = platformMapFingerprint(map);
    if (proposedFingerprints.get(target.sourceKey) === fingerprint) return false;
    const response = await fetchImpl(`${baseUrl}/api/watcher/platform-map`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify(map),
    });
    // 429 is the server's one-a-day limit: this structure is already queued or
    // will be proposed tomorrow, so stop retrying it every poll.
    if (response.ok || response.status === 429) proposedFingerprints.set(target.sourceKey, fingerprint);
    return response.ok;
  } catch (error) {
    warn("proposal", error);
    return false;
  } finally {
    db?.close();
  }
}

const FAILURE_KIND_FOR_STATE: Partial<Record<CapabilityHealth["state"], "zero_records" | "shape_mismatch">> = {
  // Could not read it and the page did not explain itself as empty.
  degraded: "zero_records",
  // A different structure is accumulating evidence.
  repairing: "shape_mismatch",
};

/** One report per capability, kind and shape per daemon run; the server dedupes daily. */
export async function reportCapabilityFailures(
  target: PlatformMapTarget,
  capabilities: CapabilityHealth[] | undefined,
  baseUrl: string,
  token: string,
  fetchImpl: FetchLike = fetch,
): Promise<number> {
  if (!target.recognized || !capabilities?.length) return 0;
  let sent = 0;
  try {
    const recipes = loadRecipeBundle(target.sourceKey, target.origin, target.recipeFile).recipes;
    for (const capability of capabilities) {
      const failureKind = FAILURE_KIND_FOR_STATE[capability.state];
      if (!failureKind) continue;
      const recipe = recipes.find((stored) => CAPABILITY_FOR_ENTITY[stored.recipe.entity] === capability.capability);
      const sanitizedExcerpt = recipe ? sanitizeFailureExcerpt(recipe.structuralSignature) : null;
      const key = [target.sourceKey, capability.capability, failureKind, sanitizedExcerpt].join("|");
      if (reportedFailures.has(key)) continue;
      const response = await fetchImpl(`${baseUrl}/api/watcher/failure`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
        body: JSON.stringify({
          platform: target.platformId,
          failureKind,
          strategyVersionId: approvedVersionIds.get(target.platformId) ?? null,
          sanitizedExcerpt,
        }),
      });
      if (response.ok) {
        reportedFailures.add(key);
        sent += 1;
      }
    }
  } catch (error) {
    warn("failure report", error);
  }
  return sent;
}
