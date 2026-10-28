// Shadow-mode equivalence for the SQLite capture journal.
//
// The journal may only take over from the NDJSON ring once it can be shown to
// answer identically for the same evidence — same source/origin filtering, same
// retention window, same order. These tests are that proof, plus the rules that
// make the journal safer than the file it replaces: idempotent mirroring and
// failing closed on damage instead of reporting an empty school.

import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import fc from "fast-check";
import { createHash } from "node:crypto";
import { readRecentCaptures } from "../evidence";
import {
  mirrorCapturesToJournal,
  openSchoolJournal,
  readJournalCaptures,
  recordJournalCaptures,
  SchoolJournalCorruptError,
  type JournalCapture,
} from "../journal";

const ORIGIN = "https://school.example";
const FINGERPRINT = createHash("sha256").update(ORIGIN).digest("hex").slice(0, 32);
const SOURCE = `portal:${FINGERPRINT}`;
const NOW = Date.parse("2026-09-13T15:00:00.000Z");

function capture(over: Partial<JournalCapture> = {}): JournalCapture {
  return {
    type: "school.capture",
    captureEventId: "11111111-1111-4111-8111-111111111111",
    sourceSessionId: "session-1",
    sourceKey: SOURCE,
    origin: ORIGIN,
    originFingerprint: FINGERPRINT,
    observedAt: "2026-09-13T14:59:00.000Z",
    receivedAt: "2026-09-13T14:59:01.000Z",
    payload: { kind: "route", path: "/assignments" },
    ...over,
  };
}

function withStores<T>(run: (paths: { captureFile: string; journalFile: string }) => T): T {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-journal-"));
  try {
    return run({ captureFile: join(root, "captures.ndjson"), journalFile: join(root, "school.db") });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const captureArb = fc
  .record({
    captureEventId: fc.uuid(),
    minute: fc.integer({ min: 0, max: 59 }),
    ageMinutes: fc.integer({ min: 0, max: 60 * 30 }),
    kind: fc.constantFrom("route", "dom-snapshot", "navigation-edge", "attachment-download"),
    sourceKey: fc.constantFrom(SOURCE, "vendor:managebac"),
    origin: fc.constantFrom(ORIGIN, "https://other.example"),
  })
  .map(({ captureEventId, minute, ageMinutes, kind, sourceKey, origin }) =>
    capture({
      captureEventId,
      sourceKey,
      origin,
      originFingerprint: createHash("sha256").update(origin).digest("hex").slice(0, 32),
      observedAt: new Date(NOW - ageMinutes * 60_000).toISOString(),
      receivedAt: new Date(NOW - ageMinutes * 60_000 + minute * 100).toISOString(),
      payload: { kind },
    }),
  );

test("journal answers identically to the NDJSON ring for the same evidence", () => {
  fc.assert(
    fc.property(fc.array(captureArb, { maxLength: 12 }), (captures) => {
      withStores(({ captureFile, journalFile }) => {
        writeFileSync(captureFile, captures.map((entry) => JSON.stringify(entry)).join("\n"));
        const options = { sourceKey: SOURCE, origin: ORIGIN, nowMs: NOW };

        mirrorCapturesToJournal(captureFile, options, journalFile);

        const db = openSchoolJournal(journalFile);
        try {
          assert.deepEqual(readJournalCaptures(db, options), readRecentCaptures(captureFile, options));
        } finally {
          db.close();
        }
      });
    }),
    { numRuns: 100 },
  );
});

test("re-mirroring the same captures adds nothing", () => {
  withStores(({ captureFile, journalFile }) => {
    const captures = [capture(), capture({ captureEventId: "22222222-2222-4222-8222-222222222222" })];
    writeFileSync(captureFile, captures.map((entry) => JSON.stringify(entry)).join("\n"));
    const options = { sourceKey: SOURCE, origin: ORIGIN, nowMs: NOW };

    assert.equal(mirrorCapturesToJournal(captureFile, options, journalFile)?.mirrored, 2);
    assert.equal(mirrorCapturesToJournal(captureFile, options, journalFile)?.mirrored, 0);

    const db = openSchoolJournal(journalFile);
    try {
      assert.equal(readJournalCaptures(db, options).length, 2);
    } finally {
      db.close();
    }
  });
});

test("captures without an extension id are still deduplicated by content", () => {
  withStores(({ journalFile }) => {
    const legacy = capture();
    delete legacy.captureEventId;
    const db = openSchoolJournal(journalFile);
    try {
      assert.equal(recordJournalCaptures(db, [legacy]), 1);
      assert.equal(recordJournalCaptures(db, [legacy]), 0);
      assert.equal(readJournalCaptures(db, { sourceKey: SOURCE, origin: ORIGIN, nowMs: NOW }).length, 1);
    } finally {
      db.close();
    }
  });
});

test("a damaged journal fails closed instead of reporting an empty school", () => {
  withStores(({ journalFile }) => {
    writeFileSync(journalFile, "this is not a database");
    assert.throws(() => openSchoolJournal(journalFile), SchoolJournalCorruptError);
  });
});

test("shadow-write failure never breaks the caller", () => {
  withStores(({ captureFile, journalFile }) => {
    writeFileSync(captureFile, `${JSON.stringify(capture())}\n`);
    writeFileSync(journalFile, "this is not a database");
    assert.equal(mirrorCapturesToJournal(captureFile, { sourceKey: SOURCE, origin: ORIGIN, nowMs: NOW }, journalFile), null);
  });
});

test("journal is created private to the student", () => {
  withStores(({ journalFile }) => {
    const db = openSchoolJournal(journalFile);
    db.close();
    assert.equal(statSync(journalFile).mode & 0o777, 0o600);
    chmodSync(journalFile, 0o600);
  });
});
