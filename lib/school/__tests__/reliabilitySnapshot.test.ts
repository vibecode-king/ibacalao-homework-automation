import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { ackSyncAttempt, claimCapturesForSync, openSchoolJournal, recordJournalCaptures } from "../journal";
import { readReliabilitySnapshot } from "../reliabilitySnapshot";
import type { JournalCapture } from "../journal";

const ORIGIN = "https://school.example";
const FINGERPRINT = createHash("sha256").update(ORIGIN).digest("hex").slice(0, 32);
const SOURCE = `portal:${FINGERPRINT}`;

test("a readable journal names the chain instead of pretending the connector is healthy", () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-reliab-"));
  const journalFile = join(root, "school.db");
  const recipeFile = join(root, "recipes.json");
  try {
    writeFileSync(recipeFile, JSON.stringify({ schemaVersion: 1, sources: { [SOURCE]: { recipes: [{ id: "r1" }] } } }));
    const db = openSchoolJournal(journalFile);
    const capture: JournalCapture = {
      type: "school.capture",
      captureEventId: "11111111-1111-4111-8111-111111111111",
      sourceSessionId: "s",
      sourceKey: SOURCE,
      origin: ORIGIN,
      originFingerprint: FINGERPRINT,
      observedAt: "2026-09-13T22:00:00.000Z",
      receivedAt: "2026-09-13T22:00:00.000Z",
      payload: { kind: "dom-snapshot" },
    };
    recordJournalCaptures(db, [capture]);
    ackSyncAttempt(db, claimCapturesForSync(db, {
      sourceKey: SOURCE,
      syncMode: "incremental",
      syncAttemptId: randomUUID(),
    })!.attempt.syncAttemptId, { recordsStored: 1 });
    db.close();

    const snapshot = readReliabilitySnapshot({
      sourceKey: SOURCE,
      journalFile,
      recipeFile,
      nowMs: Date.parse("2026-09-13T22:01:00.000Z"),
    });
    assert.equal(snapshot.journalReadable, true);
    assert.equal(snapshot.chain, "healthy");
    assert.equal(snapshot.recipeCount, 1);
    assert.equal(snapshot.unacknowledgedCaptures, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
