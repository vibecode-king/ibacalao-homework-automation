// A shared map is only safe if it carries structure and nothing else, and if a
// downloaded map can never take over a student's connector on its own.

import assert from "node:assert/strict";
import { test } from "node:test";
import {
  exportPlatformMap,
  isPrivacySafeSelector,
  isShareableTemplate,
  parseFailureExcerpt,
  parsePlatformMap,
  platformMapFingerprint,
  sanitizeFailureExcerpt,
  stageDownloadedMap,
} from "../platformMap";
import type { PlatformNode } from "../platformGraph";
import { recipeVersion, stageRepairCandidate, type SchoolRecipeBundle, type StoredSchoolRecipe } from "../recipeStore";
import type { SchoolRecipe } from "../types";

const SIGNATURE = { tag: "tr", classTokens: ["row"], attributeNames: ["data-id"], childTags: ["td", "td"] };

function recipe(selector: string): SchoolRecipe {
  return { schemaVersion: 1, entity: "assignment", source: { kind: "observed-dom", container: "/modules/activity/fStudentCalendarActivity", selector }, fields: {} };
}

function stored(selector: string, extra: Partial<StoredSchoolRecipe> = {}): StoredSchoolRecipe {
  const value = recipe(selector);
  return {
    id: "r1",
    recipe: value,
    version: recipeVersion(value),
    confidence: 0.9,
    learnedAt: "2026-09-14T10:00:00.000Z",
    updatedAt: "2026-09-14T10:00:00.000Z",
    structuralSignature: SIGNATURE,
    ...extra,
  };
}

function bundle(recipes: StoredSchoolRecipe[]): SchoolRecipeBundle {
  return { schemaVersion: 1, sourceKey: "portal:0123456789abcdef", origin: "https://ukschool.learnbox.com.ec", updatedAt: "2026-09-14T10:00:00.000Z", recipes };
}

function node(routeTemplate: string, overrides: Partial<PlatformNode> = {}): PlatformNode {
  return {
    nodeId: `portal:0123456789abcdef|${routeTemplate}|collection`,
    sourceKey: "portal:0123456789abcdef",
    routeTemplate,
    pageRole: "collection",
    capability: "assignments",
    activeRecipeId: "r1",
    candidateRecipeId: null,
    observationCount: 4,
    successCount: 3,
    failureCount: 1,
    stableIdRatio: 1,
    fieldCompleteness: 0.5,
    lastObservedAt: "2026-09-14T10:00:00.000Z",
    lastSuccessAt: null,
    lastFailureAt: null,
    ...overrides,
  };
}

function sampleMap() {
  return exportPlatformMap(
    "learnbox",
    [
      node("/modules/activity/fStudentCalendarActivity"),
      node("/rpc/remoteValidation/message/checkUserMessages.rpc"),
      node("/alumnos/Juan Pérez"),
    ],
    [{ fromTemplate: "/modules/message/fInbox", toTemplate: "/modules/message/fViewMessageInbox", relationship: "detail", observationCount: 2, lastObservedAt: null }],
    bundle([stored("table tbody > tr")]),
  );
}

test("an exported map carries structure, never who or what", () => {
  const map = sampleMap();
  const json = JSON.stringify(map);
  for (const forbidden of ["portal:", "https://", "ukschool", "\"origin\"", "\"sourceKey\"", "\"url\"", "\"text\"", "Juan"]) {
    assert.equal(json.includes(forbidden), false, forbidden);
  }
  assert.deepEqual(map.nodes.map((entry) => entry.routeTemplate), ["/modules/activity/fStudentCalendarActivity"]);
  assert.equal(map.nodes[0].successRate, 0.75);
  assert.equal(map.recipes.length, 1);
});

test("a map survives the wire unchanged", () => {
  const map = sampleMap();
  assert.deepEqual(parsePlatformMap(JSON.parse(JSON.stringify(map))), map);
});

test("shared selector grammar accepts reusable structure and rejects personal literals", () => {
  assert.equal(isPrivacySafeSelector("table tbody > tr"), true);
  assert.equal(isPrivacySafeSelector("#subjectPeriodSummaryContainer table.gradeTable tbody > tr"), true);
  assert.equal(isPrivacySafeSelector('a[href*="/modules/message/fViewMessageInbox/"]'), true);
  assert.equal(isPrivacySafeSelector('div[data-student="Juan-Perez"]'), false);
  assert.equal(isPrivacySafeSelector("#juan-perez .assignment-card"), false);
  assert.equal(isPrivacySafeSelector(".assignment-card.a8f3c9d72e514abc"), false);
});

test("selector grammar refuses escapes, smuggled attribute names and syntax tricks", () => {
  for (const safe of [
    "tr:nth-of-type(2)",
    "#inbox tbody > tr",
    "ul.pagination li[aria-label='Siguiente']",
    "button[type=submit]",
    "div[role=\"row\"] > td",
    "tr[data-id]",
  ]) assert.equal(isPrivacySafeSelector(safe), true, safe);

  for (const unsafe of [
    "a[data-juan-perez]", // personal attribute name, presence only
    "#\\4a uan", // CSS escape hides the id from token checks
    '[data-name="Juan]"]', // `]` inside quotes
    'a[title="Juan Perez"]',
    "div:has(> a.row)",
    "li:not(.row)",
    "li.row, #juan",
    "li.row ~ li",
    "li.row + li",
    'a[href="/students/1234567"]',
    'a[href="/alumno/juan.perez@colegio.edu"]',
    "tr[data-id='8f14e45f-ceea-467a-9575-1234567890ab']",
    ".row.a8f3c9d72e514abc",
    "unknown > tr",
    "> tr",
    "tr >",
    "",
  ]) assert.equal(isPrivacySafeSelector(unsafe), false, unsafe);
});

test("structural attribute names are filtered on export and refused on import", () => {
  const excerpt = sanitizeFailureExcerpt({ tag: "tr", classTokens: ["row"], attributeNames: ["data-id", "data-student-juan-perez", "data-9f8e7d6c5b4a"], childTags: ["td"] });
  assert.deepEqual(JSON.parse(excerpt).attributeNames, ["data-id"]);
  assert.equal(parseFailureExcerpt(JSON.stringify({ ...SIGNATURE, attributeNames: ["data-juan-perez"] })), null);

  const shared = exportPlatformMap("learnbox", [], [], bundle([stored("table tbody > tr")]));
  const hostile = JSON.parse(JSON.stringify(shared));
  hostile.recipes[0].structuralSignature.attributeNames = ["data-maria-gomez"];
  assert.equal(parsePlatformMap(hostile), null);
});

test("unsafe selector literals never leave or enter a shared map", () => {
  const unsafeExport = exportPlatformMap(
    "learnbox",
    [],
    [],
    bundle([stored('div[data-student="Juan-Perez"]')]),
  );
  assert.equal(unsafeExport.recipes.length, 0);

  const downloaded = JSON.parse(JSON.stringify(sampleMap()));
  downloaded.recipes[0].recipe.source.selector = "#juan-perez .assignment-card";
  assert.equal(parsePlatformMap(downloaded), null);
});

test("shared structural signatures strip identifying or high-entropy class tokens", () => {
  const unsafeStored = stored("table tbody > tr", {
    structuralSignature: {
      tag: "tr",
      classTokens: ["row", "student-juan-perez", "a8f3c9d72e514abc"],
      attributeNames: ["data-id"],
      childTags: ["td"],
      role: "row",
    },
  });
  const map = exportPlatformMap("learnbox", [], [], bundle([unsafeStored]));
  assert.equal(map.recipes.length, 1);
  assert.deepEqual(map.recipes[0].structuralSignature.classTokens, ["row"]);

  const hostile = JSON.parse(JSON.stringify(map));
  hostile.recipes[0].structuralSignature.classTokens.push("student-juan-perez");
  assert.equal(parsePlatformMap(hostile), null);

  const excerpt = sanitizeFailureExcerpt(unsafeStored.structuralSignature);
  assert.equal(excerpt.includes("juan"), false);
  assert.equal(excerpt.includes("a8f3c9"), false);
});

test("any unknown key or unknown recipe kind rejects the whole map", () => {
  const map = JSON.parse(JSON.stringify(sampleMap()));
  assert.equal(parsePlatformMap({ ...map, script: "alert(1)" }), null);

  const smuggled = JSON.parse(JSON.stringify(map));
  smuggled.recipes[0].recipe.onLoad = "fetch('https://evil.example')";
  assert.equal(parsePlatformMap(smuggled), null);

  const remoteCode = JSON.parse(JSON.stringify(map));
  remoteCode.recipes[0].recipe.source.kind = "remote-js";
  assert.equal(parsePlatformMap(remoteCode), null);

  const schoolRoute = JSON.parse(JSON.stringify(map));
  schoolRoute.nodes[0].routeTemplate = "/alumnos/Juan Pérez";
  assert.equal(parsePlatformMap(schoolRoute), null);

  assert.equal(parsePlatformMap({ ...map, platformId: "https://ukschool.learnbox.com.ec" }), null);
});

test("the fingerprint ignores success rates but not new pages", () => {
  const map = sampleMap();
  const moved = { ...map, nodes: map.nodes.map((entry) => ({ ...entry, successRate: 0.1, observationCount: 99 })) };
  assert.equal(platformMapFingerprint(moved), platformMapFingerprint(map));
  const grown = { ...map, nodes: [...map.nodes, { ...map.nodes[0], routeTemplate: "/modules/message/fInbox" }] };
  assert.notEqual(platformMapFingerprint(grown), platformMapFingerprint(map));
});

test("a downloaded recipe is never active before two independent local observations agree", () => {
  const shared = exportPlatformMap("learnbox", [], [], bundle([stored("div.activity-row")]));
  const local = bundle([stored("table tbody > tr")]);
  const { bundle: staged, staged: count } = stageDownloadedMap(local, shared, "2026-09-14T11:00:00.000Z");
  assert.equal(count, 1);
  const candidate = staged.recipes[0];
  assert.equal(candidate.recipe.source.selector, "table tbody > tr");
  assert.equal(candidate.pendingRepair?.observations, 0);

  const { version, recipe: sharedRecipe, confidence, structuralSignature } = candidate.pendingRepair!;
  const first = stageRepairCandidate(candidate.pendingRepair, { recipe: sharedRecipe, version, confidence, structuralSignature }, "2026-09-14T11:05:00.000Z");
  assert.equal(first.promote, false);
  const second = stageRepairCandidate(first.pendingRepair, { recipe: sharedRecipe, version, confidence, structuralSignature }, "2026-09-14T11:10:00.000Z");
  assert.equal(second.promote, true);
});

test("a quarantined version, a local candidate, or an unknown page is never staged", () => {
  const shared = exportPlatformMap("learnbox", [], [], bundle([stored("div.activity-row")]));
  const sharedVersion = shared.recipes.map((entry) => recipeVersion(entry.recipe))[0];

  const quarantined = bundle([stored("table tbody > tr", { quarantined: [{ version: sharedVersion, reason: "zero_records", at: "2026-09-13T00:00:00.000Z" }] })]);
  assert.equal(stageDownloadedMap(quarantined, shared, "2026-09-14T11:00:00.000Z").staged, 0);

  const localCandidate = stored("table tbody > tr");
  localCandidate.pendingRepair = { recipe: recipe("ul > li"), version: "local", confidence: 0.8, structuralSignature: SIGNATURE, firstObservedAt: "x", lastObservedAt: "x", observations: 1 };
  assert.equal(stageDownloadedMap(bundle([localCandidate]), shared, "2026-09-14T11:00:00.000Z").staged, 0);

  assert.equal(stageDownloadedMap(bundle([]), shared, "2026-09-14T11:00:00.000Z").staged, 0);
});

test("a failure excerpt is only a short structural signature", () => {
  const excerpt = sanitizeFailureExcerpt({
    tag: "tr",
    classTokens: ["x".repeat(200), "row"],
    attributeNames: ["data-student-name-that-is-very-long-indeed-and-more"],
    childTags: ["td"],
  });
  const strings: string[] = [];
  JSON.parse(excerpt, (key, value) => {
    if (typeof key === "string" && key) strings.push(key);
    if (typeof value === "string") strings.push(value);
    return value;
  });
  assert.ok(strings.every((value) => value.length <= 40));
  assert.equal(excerpt.includes("\"text\""), false);
  assert.equal(parseFailureExcerpt(excerpt), excerpt);
  assert.equal(parseFailureExcerpt(JSON.stringify({ ...SIGNATURE, text: "Juan Pérez 7/7" })), null);
  assert.equal(parseFailureExcerpt("<tr><td>Juan</td></tr>"), null);
});

test("a route template naming a specific person is never shareable, even pre-templated", () => {
  // Guards against nodes recorded before routeTemplate() learned this: the
  // stored routeTemplate itself carries a literal name here, not :id.
  assert.equal(isShareableTemplate("/alumnos/juanperez"), false);
  assert.equal(isShareableTemplate("/students/maria-gomez"), false);
  assert.equal(isShareableTemplate("/alumnos/:id"), true);
  assert.equal(isShareableTemplate("/assignments/:id"), true);
});
