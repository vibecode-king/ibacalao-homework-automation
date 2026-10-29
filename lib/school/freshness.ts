// lib/school/freshness.ts
// Per-source proof-of-life state, as computed by the server from heartbeats.
// Only the pure summarizer and types live here; storage stays in the website repo.
//
// The watcher only uploads when something changed, so without a heartbeat the
// server cannot tell "nothing new at school" from "the Mac has been asleep for
// three days". Silence must never read as all-clear.

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

// Hash fields are "<sourceKey>|<fact>" so concurrent writes never read-modify-write.
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
