// lib/school/chainTelemetry.ts
// Where the school-sync chain actually stopped.
//
// "Reconnect school" is the wrong answer to almost every failure this system
// has: the browser never visited the portal, the bridge is disconnected, the
// Mac is asleep, the session expired, a challenge appeared, the recipe went
// stale, or the upload could not reach us. Each needs a different sentence —
// and several need no sentence at all.
//
// The journal already timestamps every stage of delivery, so this reads that
// and names the earliest stage that is overdue, instead of collapsing
// everything into one unhelpful state.

import type { DatabaseSync } from "node:sqlite";

export type ChainTelemetry = {
  lastBrowserObservationAt: string | null;
  lastNativePersistAt: string | null;
  lastDaemonConsumeAt: string | null;
  lastExtractSuccessAt: string | null;
  lastReconcileSuccessAt: string | null;
  lastUploadAttemptAt: string | null;
  lastServerAckAt: string | null;
  unacknowledgedCaptures: number;
};

export type ChainState =
  /** Evidence is flowing all the way to a server acknowledgement. */
  | "healthy"
  /** The student simply has not opened their portal recently. Not a failure. */
  | "browser_not_observed"
  /** The browser saw pages the native host never stored. */
  | "bridge_disconnected"
  /** Evidence is piling up unconsumed: the daemon is not running. */
  | "daemon_not_consuming"
  /** We read pages but could not extract records from them. */
  | "extraction_failing"
  /** Extracted fine, but nothing reached the server. */
  | "upload_failing";

const STALE_MS = 2 * 60 * 60 * 1000;

export function readChainTelemetry(db: DatabaseSync, sourceKey: string): ChainTelemetry {
  const captures = db.prepare(
    `SELECT MAX(observed_at) AS observed, MAX(received_at) AS received, MAX(claimed_at) AS claimed
       FROM captures WHERE source_key = ?`,
  ).get(sourceKey) as { observed: string | null; received: string | null; claimed: string | null };

  const attempts = db.prepare(
    `SELECT MAX(extract_succeeded_at) AS extracted, MAX(reconciled_at) AS reconciled,
            MAX(upload_started_at) AS uploaded, MAX(acked_at) AS acked
       FROM sync_attempts WHERE source_key = ?`,
  ).get(sourceKey) as { extracted: string | null; reconciled: string | null; uploaded: string | null; acked: string | null };

  const pending = db.prepare(
    "SELECT COUNT(*) AS count FROM captures WHERE source_key = ? AND consumed_at IS NULL",
  ).get(sourceKey) as { count: number };

  return {
    lastBrowserObservationAt: captures?.observed ?? null,
    lastNativePersistAt: captures?.received ?? null,
    lastDaemonConsumeAt: captures?.claimed ?? null,
    lastExtractSuccessAt: attempts?.extracted ?? null,
    lastReconcileSuccessAt: attempts?.reconciled ?? null,
    lastUploadAttemptAt: attempts?.uploaded ?? null,
    lastServerAckAt: attempts?.acked ?? null,
    unacknowledgedCaptures: Number(pending?.count ?? 0),
  };
}

function isFresh(at: string | null, nowMs: number): boolean {
  if (!at) return false;
  const ms = Date.parse(at);
  return Number.isFinite(ms) && nowMs - ms <= STALE_MS;
}

/**
 * Names the earliest stage that is overdue.
 *
 * Order matters: a dead daemon makes everything downstream look dead too, and
 * telling the student their upload is failing when their Mac was simply asleep
 * sends them to fix the wrong thing.
 */
export function explainChainState(telemetry: ChainTelemetry, nowMs = Date.now()): ChainState {
  if (!isFresh(telemetry.lastBrowserObservationAt, nowMs)) return "browser_not_observed";
  if (!isFresh(telemetry.lastNativePersistAt, nowMs)) return "bridge_disconnected";

  // Nothing left to deliver: the chain finished, whatever the clock says about
  // the last upload (a quiet school produces no uploads at all).
  if (telemetry.unacknowledgedCaptures === 0) return "healthy";

  if (!isFresh(telemetry.lastDaemonConsumeAt, nowMs)) return "daemon_not_consuming";
  if (!isFresh(telemetry.lastExtractSuccessAt, nowMs)) return "extraction_failing";
  if (!isFresh(telemetry.lastServerAckAt, nowMs)) return "upload_failing";
  return "healthy";
}
