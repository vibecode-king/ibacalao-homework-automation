// Generated-case invariants for canonical school identity and local durability.
//
// These are the rules the reconciler must keep no matter what order the student
// happens to browse in: one school object stays one canonical entity, later
// glimpses of it only ever add information, and a damaged local store refuses
// to answer rather than reporting an empty, healthy-looking school.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import fc from "fast-check";
import { loadCanonicalSchoolEntities, reconcileSchoolRecords } from "../entityStore";
import type { ScrapedRecord } from "../../watcher/types";

const RUNS = { numRuns: 200 };
const ORIGIN = "https://school.example";
const SOURCE = "portal:0123456789abcdef0123456789abcdef";
const OTHER_SOURCE = "vendor:managebac";

const ENRICHABLE = ["subject", "detail", "status", "grade"] as const;

const richRecordArb = fc.record({
  sourceRecordId: fc.constantFrom("assignment-1", "assignment-2", "77"),
  kind: fc.constantFrom<ScrapedRecord["kind"]>("assignment", "message", "grade"),
  title: fc.constantFrom("Biology IA", "History essay"),
  subject: fc.constantFrom("Biology", "History"),
  detail: fc.constantFrom("Read chapter 4", "See the rubric"),
  status: fc.constantFrom("assigned", "submitted"),
  grade: fc.constantFrom("6", "7"),
  dueAt: fc.constantFrom("2026-09-20T23:59:00.000Z", "2026-09-21T23:59:00.000Z"),
}) as fc.Arbitrary<ScrapedRecord>;

function withTempStore<T>(run: (file: string) => T): T {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-entity-properties-"));
  try {
    return run(join(root, "entities.json"));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("property 3: a later sparse sighting of a known entity only adds information", () => {
  fc.assert(
    fc.property(richRecordArb, fc.uniqueArray(fc.constantFrom(...ENRICHABLE)), (rich, dropped) => {
      withTempStore((file) => {
        const sparse: ScrapedRecord = { ...rich };
        for (const field of dropped) delete sparse[field];

        reconcileSchoolRecords(SOURCE, ORIGIN, [rich], { file, observedAt: "2026-09-13T12:00:00.000Z" });
        const after = reconcileSchoolRecords(SOURCE, ORIGIN, [sparse], { file, observedAt: "2026-09-13T13:00:00.000Z" });

        const entities = loadCanonicalSchoolEntities(SOURCE, file);
        assert.equal(entities.length, 1);
        for (const field of ENRICHABLE) assert.equal(entities[0].record[field], rich[field]);
        // Learning nothing new is not an academic change.
        for (const mutation of after.mutations) assert.notEqual(mutation.changeKind, "source_changed");
      });
    }),
    RUNS,
  );
});

test("property 1: re-observing the same page never forks the canonical entity", () => {
  fc.assert(
    fc.property(richRecordArb, fc.integer({ min: 1, max: 4 }), (record, sightings) => {
      withTempStore((file) => {
        for (let index = 0; index < sightings; index += 1) {
          reconcileSchoolRecords(SOURCE, ORIGIN, [record], {
            file,
            observedAt: new Date(Date.UTC(2026, 8, 13, 12, index)).toISOString(),
          });
        }
        assert.equal(loadCanonicalSchoolEntities(SOURCE, file).length, 1);
      });
    }),
    RUNS,
  );
});

test("property 5: two schools using the same record id stay separate entities", () => {
  fc.assert(
    fc.property(richRecordArb, (record) => {
      withTempStore((file) => {
        const observedAt = "2026-09-13T12:00:00.000Z";
        const mine = reconcileSchoolRecords(SOURCE, ORIGIN, [record], { file, observedAt });
        const theirs = reconcileSchoolRecords(OTHER_SOURCE, "https://other.example", [record], { file, observedAt });

        assert.equal(loadCanonicalSchoolEntities(SOURCE, file).length, 1);
        assert.equal(loadCanonicalSchoolEntities(OTHER_SOURCE, file).length, 1);
        assert.notEqual(mine.records[0].sourceRecordId, theirs.records[0].sourceRecordId);
      });
    }),
    RUNS,
  );
});

test("property 12: a damaged store fails closed instead of reporting no school work", () => {
  fc.assert(
    fc.property(richRecordArb, fc.string({ maxLength: 40 }), (record, garbage) => {
      withTempStore((file) => {
        reconcileSchoolRecords(SOURCE, ORIGIN, [record], { file, observedAt: "2026-09-13T12:00:00.000Z" });
        writeFileSync(file, garbage);
        writeFileSync(`${file}.bak`, garbage);

        // The one string that is legitimately an empty store must not throw;
        // everything else must refuse rather than look like an empty school.
        let entities: ReturnType<typeof loadCanonicalSchoolEntities> | null = null;
        try {
          entities = loadCanonicalSchoolEntities(SOURCE, file);
        } catch (error) {
          assert.match(String(error), /school_entity_store_corrupt/);
          return;
        }
        const parsed = JSON.parse(garbage) as { schemaVersion?: number };
        assert.equal(parsed.schemaVersion, 1);
        assert.deepEqual(entities, []);
      });
    }),
    RUNS,
  );
});
