// Generated-case invariants for the repair promotion contract.
//
// Self-healing is the connector's most dangerous power: a wrong selector that
// gets promoted quietly starts producing confident, wrong school data. These
// properties pin down the evidence a candidate must accumulate before it is
// allowed to replace a working recipe.

import assert from "node:assert/strict";
import { test } from "node:test";
import fc from "fast-check";
import { stageRepairCandidate, type PendingSchoolRepair } from "../recipeStore";

const RUNS = { numRuns: 500 };

const signature = { tag: "article", classTokens: ["task-card"], attributeNames: ["data-id"], childTags: ["h3"] };

const candidateArb = fc.constantFrom("article.task-card", "li.assignment", "div.row").map((selector) => ({
  recipe: { source: { selector } } as PendingSchoolRepair["recipe"],
  version: `v-${selector}`,
  confidence: 0.9,
  structuralSignature: signature,
}));

const observedAtArb = fc
  .integer({ min: 0, max: 12 })
  .map((minute) => new Date(Date.UTC(2026, 8, 13, 15, minute)).toISOString());

type RepairCandidate = Parameters<typeof stageRepairCandidate>[1];

/** Replays a browsing history of candidate sightings against the contract. */
function replay(sightings: Array<{ candidate: RepairCandidate; observedAt: string }>) {
  let pending: PendingSchoolRepair | undefined;
  const promotions: number[] = [];
  sightings.forEach((sighting, index) => {
    const result = stageRepairCandidate(pending, sighting.candidate, sighting.observedAt);
    if (result.promote) promotions.push(index);
    pending = result.pendingRepair;
  });
  return { pending, promotions };
}

test("property 7: a candidate never activates on its first sighting", () => {
  fc.assert(
    fc.property(candidateArb, observedAtArb, (candidate, observedAt) => {
      const { promote, pendingRepair } = stageRepairCandidate(undefined, candidate, observedAt);
      assert.equal(promote, false);
      assert.equal(pendingRepair.observations, 1);
      assert.equal(pendingRepair.firstObservedAt, observedAt);
    }),
    RUNS,
  );
});

test("property 7: re-reading one observation cannot manufacture the second sighting", () => {
  fc.assert(
    fc.property(candidateArb, observedAtArb, fc.integer({ min: 1, max: 5 }), (candidate, observedAt, rereads) => {
      const sightings = Array.from({ length: rereads }, () => ({ candidate, observedAt }));
      const { promotions, pending } = replay(sightings);
      assert.deepEqual(promotions, []);
      assert.equal(pending?.observations, 1);
    }),
    RUNS,
  );
});

test("property 7: promotion requires two independent sightings of the same candidate", () => {
  fc.assert(
    fc.property(
      fc.array(fc.record({ candidate: candidateArb, observedAt: observedAtArb }), { minLength: 1, maxLength: 8 }),
      (sightings) => {
        let pending: PendingSchoolRepair | undefined;
        for (const sighting of sightings) {
          const result = stageRepairCandidate(pending, sighting.candidate, sighting.observedAt);
          if (result.promote) {
            assert.ok(pending);
            assert.equal(pending.version, sighting.candidate.version);
            assert.notEqual(pending.lastObservedAt, sighting.observedAt);
          }
          pending = result.pendingRepair;
        }
      },
    ),
    RUNS,
  );
});

test("property 7: a candidate that keeps changing shape never accumulates evidence", () => {
  fc.assert(
    fc.property(candidateArb, candidateArb, fc.integer({ min: 1, max: 4 }), (first, second, rounds) => {
      fc.pre(first.version !== second.version);
      // The page alternates between two shapes, never showing either twice in a row.
      const sightings = Array.from({ length: rounds * 2 }, (_unused, index) => ({
        candidate: index % 2 === 0 ? first : second,
        observedAt: new Date(Date.UTC(2026, 8, 13, 15, index)).toISOString(),
      }));
      const { promotions, pending } = replay(sightings);
      assert.deepEqual(promotions, []);
      assert.equal(pending?.observations, 1);
    }),
    RUNS,
  );
});
