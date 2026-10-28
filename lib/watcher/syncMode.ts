// lib/watcher/syncMode.ts
// P0.1 (research handoff / dispatch plan): confirmed live before this file
// existed — a first-ever crawl of 3 pre-existing tasks classified all 3 as
// "added" (computeDelta's correct behavior: they ARE new to a fresh
// fingerprint store). A student connecting ManageBac for the first time with
// 100 real existing tasks would have every one of them look brand new to any
// consumer that treats "added" as newsworthy — there was no way to tell "this
// crawl is establishing a baseline" from "this crawl found something real"
// separately from computeDelta's added/changed classification.
//
// This module is that missing distinction: a WatcherSyncMode the daemon
// computes and sends alongside a delta, independent of what the delta itself
// contains. Nothing downstream (there is no push/notification sender yet)
// consumes this to suppress anything today — this is the fact those future
// consumers will need, recorded now rather than bolted on once they exist.
//
// Pure and I/O-free — the daemon supplies the two timestamps it already
// tracks (an empty fingerprint store, and the health record's lastSuccessAt).

export type WatcherSyncMode = "bootstrap" | "incremental" | "catchup";

/** Below this, a gap between successful crawls is ordinary polling jitter,
 *  not an interruption worth treating as a batch of held-up history. The
 *  daemon's normal interval is ~30min with jitter (schedule.ts); a threshold
 *  well above that avoids reclassifying a slightly-late poll as a catch-up. */
export const CATCHUP_GAP_MS = 3 * 60 * 60 * 1000; // 3 hours — a config value to tune, not a derived constant

/**
 * Classifies one crawl before it's uploaded.
 *
 * `hadPreviousFingerprints`: false only on this platform's very first
 * successful crawl on this machine — computeDelta had nothing to compare
 * against, so every record it saw is definitionally "added" without being
 * news.
 *
 * `lastSuccessAt`: the watcher's own health record, already tracked
 * (lib/watcher/types.ts's WatcherHealth) — no new state to persist.
 */
export function classifySync(
  hadPreviousFingerprints: boolean,
  lastSuccessAt: string | null,
  now: number = Date.now(),
): WatcherSyncMode {
  if (!hadPreviousFingerprints) return "bootstrap";
  if (!lastSuccessAt) return "incremental"; // has fingerprints but no recorded success — treat as ordinary, not a gap we can't measure
  const lastSuccessMs = Date.parse(lastSuccessAt);
  if (!Number.isFinite(lastSuccessMs)) return "incremental";
  return now - lastSuccessMs >= CATCHUP_GAP_MS ? "catchup" : "incremental";
}
