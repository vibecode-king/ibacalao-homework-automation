// Every failure in the chain must name itself, so the student is never told to
// "reconnect school" when their Mac was simply asleep.

import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { explainChainState, readChainTelemetry, type ChainTelemetry } from "../chainTelemetry";
import {
  ackSyncAttempt,
  claimCapturesForSync,
  openSchoolJournal,
  recordJournalCaptures,
  recordSyncStage,
  type JournalCapture,
} from "../journal";

const ORIGIN = "https://school.example";
const FINGERPRINT = createHash("sha256").update(ORIGIN).digest("hex").slice(0, 32);
const SOURCE = `portal:${FINGERPRINT}`;
const NOW = Date.parse("2026-09-13T15:00:00.000Z");
const recent = new Date(NOW - 60_000).toISOString();
const old = new Date(NOW - 6 * 60 * 60 * 1000).toISOString();

function telemetry(over: Partial<ChainTelemetry> = {}): ChainTelemetry {
  return {
    lastBrowserObservationAt: recent,
    lastNativePersistAt: recent,
    lastDaemonConsumeAt: recent,
    lastExtractSuccessAt: recent,
    lastReconcileSuccessAt: recent,
    lastUploadAttemptAt: recent,
    lastServerAckAt: recent,
    unacknowledgedCaptures: 0,
    ...over,
  };
}

test("a student who has not opened their portal is not a failure", () => {
  assert.equal(
    explainChainState(telemetry({ lastBrowserObservationAt: old }), NOW),
    "browser_not_observed",
  );
});

test("pages the native host never stored mean the bridge is down", () => {
  assert.equal(explainChainState(telemetry({ lastNativePersistAt: old }), NOW), "bridge_disconnected");
});

test("evidence piling up unconsumed means the daemon is not running", () => {
  assert.equal(
    explainChainState(telemetry({ lastDaemonConsumeAt: old, unacknowledgedCaptures: 5 }), NOW),
    "daemon_not_consuming",
  );
});

test("consumed but never extracted is an extraction problem", () => {
  assert.equal(
    explainChainState(telemetry({ lastExtractSuccessAt: old, unacknowledgedCaptures: 3 }), NOW),
    "extraction_failing",
  );
});

test("extracted but never acknowledged is an upload problem", () => {
  assert.equal(
    explainChainState(telemetry({ lastServerAckAt: old, unacknowledgedCaptures: 2 }), NOW),
    "upload_failing",
  );
});

test("a quiet school with nothing owed is healthy, not stalled", () => {
  // No uploads for hours is normal when nothing changed at school.
  assert.equal(
    explainChainState(telemetry({ lastUploadAttemptAt: old, lastServerAckAt: old }), NOW),
    "healthy",
  );
});

test("telemetry reads the real stage timestamps out of the journal", () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-chain-"));
  const db = openSchoolJournal(join(root, "school.db"));
  try {
    const capture: JournalCapture = {
      type: "school.capture",
      captureEventId: randomUUID(),
      sourceSessionId: "session-1",
      sourceKey: SOURCE,
      origin: ORIGIN,
      originFingerprint: FINGERPRINT,
      observedAt: recent,
      receivedAt: recent,
      payload: { kind: "dom-snapshot" },
    };
    recordJournalCaptures(db, [capture]);

    const beforeClaim = readChainTelemetry(db, SOURCE);
    assert.equal(beforeClaim.lastBrowserObservationAt, recent);
    assert.equal(beforeClaim.lastDaemonConsumeAt, null);
    assert.equal(beforeClaim.unacknowledgedCaptures, 1);

    const claimed = claimCapturesForSync(db, { sourceKey: SOURCE, syncMode: "incremental", syncAttemptId: randomUUID(), now: recent });
    recordSyncStage(db, claimed!.attempt.syncAttemptId, "extract_succeeded_at", recent);
    ackSyncAttempt(db, claimed!.attempt.syncAttemptId, { recordsStored: 1 }, recent);

    const after = readChainTelemetry(db, SOURCE);
    assert.equal(after.lastDaemonConsumeAt, recent);
    assert.equal(after.lastExtractSuccessAt, recent);
    assert.equal(after.lastServerAckAt, recent);
    assert.equal(after.unacknowledgedCaptures, 0);
    assert.equal(explainChainState(after, NOW), "healthy");
  } finally {
    db.close();
    rmSync(root, { recursive: true, force: true });
  }
});
