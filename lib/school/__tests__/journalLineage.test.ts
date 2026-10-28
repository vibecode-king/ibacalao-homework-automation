// Delivery lineage: can we prove a capture reached the server?
//
// Each test kills the pipeline at one of the stages the handoff calls out —
// before consuming, after extraction but before upload, after the server
// accepted an upload whose response we never saw — and asserts the same thing
// every time: evidence is never considered done until the server acknowledged
// it, and a restart picks up exactly what was left unfinished.

import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { DatabaseSync } from "node:sqlite";
import {
  ackSyncAttempt,
  claimCapturesForSync,
  failSyncAttempt,
  openSchoolJournal,
  recordJournalCaptures,
  recordSyncStage,
  recoverStaleSyncAttempts,
  unacknowledgedCaptureCount,
  unacknowledgedSyncAttempts,
  type JournalCapture,
} from "../journal";

const ORIGIN = "https://school.example";
const FINGERPRINT = createHash("sha256").update(ORIGIN).digest("hex").slice(0, 32);
const SOURCE = `portal:${FINGERPRINT}`;

function capture(id: string, observedAt = "2026-09-13T14:59:00.000Z"): JournalCapture {
  return {
    type: "school.capture",
    captureEventId: id,
    sourceSessionId: "session-1",
    sourceKey: SOURCE,
    origin: ORIGIN,
    originFingerprint: FINGERPRINT,
    observedAt,
    receivedAt: observedAt,
    payload: { kind: "dom-snapshot" },
  };
}

/** Each test gets a real database on disk, closed and removed afterwards. */
function withJournal(run: (db: DatabaseSync, reopen: () => DatabaseSync) => void): void {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-lineage-"));
  const file = join(root, "school.db");
  let db = openSchoolJournal(file);
  try {
    run(db, () => {
      // Simulates the daemon dying and starting again against the same journal.
      db.close();
      db = openSchoolJournal(file);
      return db;
    });
  } finally {
    db.close();
    rmSync(root, { recursive: true, force: true });
  }
}

const claim = (db: DatabaseSync) =>
  claimCapturesForSync(db, { sourceKey: SOURCE, syncMode: "incremental", syncAttemptId: randomUUID() });

test("a claim carries exactly the unacknowledged evidence", () => {
  withJournal((db) => {
    recordJournalCaptures(db, [capture("a"), capture("b")]);
    const claimed = claim(db);

    assert.equal(claimed?.captures.length, 2);
    assert.equal(claimed?.attempt.state, "sending");
    assert.equal(claimed?.attempt.attemptCount, 1);
    assert.ok(claimed?.attempt.requestHash);
  });
});

test("claimed evidence is not handed to a second attempt", () => {
  withJournal((db) => {
    recordJournalCaptures(db, [capture("a")]);
    assert.equal(claim(db)?.captures.length, 1);
    assert.equal(claim(db), null);
  });
});

test("killing the daemon before the upload leaves the evidence claimable again", () => {
  withJournal((db, reopen) => {
    recordJournalCaptures(db, [capture("a")]);
    const claimed = claim(db);
    recordSyncStage(db, claimed!.attempt.syncAttemptId, "extract_succeeded_at");

    const restarted = reopen();
    // Nothing acknowledged it, so it must still be owed.
    assert.equal(unacknowledgedCaptureCount(restarted, SOURCE), 1);
    assert.equal(recoverStaleSyncAttempts(restarted, { olderThanMs: 0 }), 1);

    const retry = claim(restarted);
    assert.equal(retry?.captures.length, 1);
    assert.equal(retry?.captures[0].captureEventId, "a");
  });
});

test("an unfinished attempt is never discarded", () => {
  withJournal((db) => {
    recordJournalCaptures(db, [capture("a")]);
    const claimed = claim(db);
    failSyncAttempt(db, claimed!.attempt.syncAttemptId, "network unreachable");

    const pending = unacknowledgedSyncAttempts(db, SOURCE);
    assert.equal(pending.length, 1);
    assert.equal(pending[0].state, "failed_retryable");
    assert.equal(pending[0].lastError, "network unreachable");
    assert.equal(unacknowledgedCaptureCount(db, SOURCE), 1);
  });
});

test("an auth failure is held separately from a retryable one", () => {
  withJournal((db) => {
    recordJournalCaptures(db, [capture("a")]);
    const claimed = claim(db);
    failSyncAttempt(db, claimed!.attempt.syncAttemptId, "401", { blockedByAuth: true });

    assert.equal(unacknowledgedSyncAttempts(db, SOURCE)[0].state, "blocked_auth");
  });
});

test("only a server ACK marks evidence consumed", () => {
  withJournal((db, reopen) => {
    recordJournalCaptures(db, [capture("a"), capture("b")]);
    const claimed = claim(db);
    const id = claimed!.attempt.syncAttemptId;

    recordSyncStage(db, id, "extract_succeeded_at");
    recordSyncStage(db, id, "reconciled_at");
    recordSyncStage(db, id, "upload_started_at");
    assert.equal(unacknowledgedCaptureCount(db, SOURCE), 2);

    ackSyncAttempt(db, id, { recordsStored: 2 });

    const restarted = reopen();
    assert.equal(unacknowledgedCaptureCount(restarted, SOURCE), 0);
    assert.equal(unacknowledgedSyncAttempts(restarted, SOURCE).length, 0);
    assert.equal(claim(restarted), null);
  });
});

test("a lost upload response replays the same evidence, not new evidence", () => {
  withJournal((db) => {
    recordJournalCaptures(db, [capture("a")]);
    const first = claim(db);
    // The server stored it; the response never made it back to the Mac.
    failSyncAttempt(db, first!.attempt.syncAttemptId, "socket hang up");

    const second = claim(db);
    assert.deepEqual(
      second?.captures.map((entry) => entry.captureEventId),
      first?.captures.map((entry) => entry.captureEventId),
    );
    // Identical evidence means an identical request hash, so the retry is
    // recognisable as the same upload rather than a second one.
    assert.equal(second?.attempt.requestHash, first?.attempt.requestHash);
  });
});

test("a stale in-flight attempt is only recovered once it is actually stale", () => {
  withJournal((db) => {
    recordJournalCaptures(db, [capture("a")]);
    claim(db);
    assert.equal(recoverStaleSyncAttempts(db, { olderThanMs: 60 * 60 * 1000 }), 0);
    assert.equal(claim(db), null);
  });
});

test("acknowledged evidence stays acknowledged after re-mirroring", () => {
  withJournal((db) => {
    recordJournalCaptures(db, [capture("a")]);
    ackSyncAttempt(db, claim(db)!.attempt.syncAttemptId, { recordsStored: 1 });

    // The NDJSON ring still holds the capture and mirrors it again next poll.
    assert.equal(recordJournalCaptures(db, [capture("a")]), 0);
    assert.equal(unacknowledgedCaptureCount(db, SOURCE), 0);
  });
});
