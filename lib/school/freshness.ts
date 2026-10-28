// lib/school/freshness.ts
// Server-side proof of life per school source.
//
// The watcher only uploads when something changed, so without a heartbeat the
// server cannot tell "nothing new at school" from "the Mac has been asleep for
// three days". Silence must never read as all-clear.

import { redis } from "@/lib/redis";

/** Healthy polling is ~30 min with jitter; two missed cycles plus slack. */
export const STALE_AFTER_MS = 2 * 60 * 60 * 1000;

export type SourceFreshnessState =
  /** Heard from recently and the last crawl succeeded (or no crawl state reported). */
  | "live"
  /** Watcher is alive but its crawls have not succeeded recently (auth, challenge, broken). */
  | "failing"
  /** Nothing heard recently: Mac asleep/off, app quit, daemon dead. */
  | "offline";

export type SourceFreshness = {
  sourceKey: string;
  lastHeartbeatAt: string | null;
  lastSuccessAt: string | null;
  lastIngestAt: string | null;
  state: SourceFreshnessState;
};

const freshnessKey = (userId: string) => `school:${userId}:freshness`;
// Separate hash fields per fact so concurrent heartbeat/ingest writes never
// read-modify-write each other.
const field = (sourceKey: string, fact: "hb" | "ok" | "ingest") => `${sourceKey}|${fact}`;

function isoOrNull(value: unknown): string | null {
  return typeof value === "string" && Number.isFinite(Date.parse(value)) ? value : null;
}

/** Pure: raw hash fields → per-source freshness. */
export function summarizeFreshness(fields: Record<string, unknown> | null, now: number = Date.now()): SourceFreshness[] {
  const bySource = new Map<string, { hb?: unknown; ok?: unknown; ingest?: unknown }>();
  for (const [name, value] of Object.entries(fields ?? {})) {
    const split = name.lastIndexOf("|");
    if (split <= 0) continue;
    const sourceKey = name.slice(0, split);
    const fact = name.slice(split + 1) as "hb" | "ok" | "ingest";
    bySource.set(sourceKey, { ...bySource.get(sourceKey), [fact]: value });
  }

  return Array.from(bySource.entries()).map(([sourceKey, facts]) => {
    const lastHeartbeatAt = isoOrNull(facts.hb);
    const lastSuccessAt = isoOrNull(facts.ok);
    const lastIngestAt = isoOrNull(facts.ingest);
    const heardAt = Math.max(Date.parse(lastHeartbeatAt ?? "") || 0, Date.parse(lastIngestAt ?? "") || 0);
    const successAt = Math.max(Date.parse(lastSuccessAt ?? "") || 0, Date.parse(lastIngestAt ?? "") || 0);
    let state: SourceFreshnessState = "live";
    if (now - heardAt > STALE_AFTER_MS) state = "offline";
    else if (lastSuccessAt !== null && now - successAt > STALE_AFTER_MS) state = "failing";
    return { sourceKey, lastHeartbeatAt, lastSuccessAt, lastIngestAt, state };
  }).sort((a, b) => a.sourceKey.localeCompare(b.sourceKey));
}

export async function recordHeartbeat(userId: string, sourceKey: string, lastSuccessAt?: string | null): Promise<void> {
  const now = new Date().toISOString();
  const success = isoOrNull(lastSuccessAt);
  // A future-dated success from a skewed client clock would mask failures.
  const trusted = success && Date.parse(success) <= Date.now() + 60_000 ? success : null;
  await redis().hset(freshnessKey(userId), {
    [field(sourceKey, "hb")]: now,
    ...(trusted ? { [field(sourceKey, "ok")]: trusted } : {}),
  });
}

/** An accepted upload is both proof of life and proof of a successful crawl. */
export async function recordIngest(userId: string, sourceKey: string): Promise<void> {
  const now = new Date().toISOString();
  await redis().hset(freshnessKey(userId), {
    [field(sourceKey, "hb")]: now,
    [field(sourceKey, "ingest")]: now,
  });
}

export async function getSchoolFreshness(userId: string): Promise<SourceFreshness[]> {
  return summarizeFreshness(await redis().hgetall<Record<string, unknown>>(freshnessKey(userId)));
}

export async function deleteSchoolFreshness(userId: string): Promise<void> {
  await redis().del(freshnessKey(userId));
}
