import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";
import { test } from "node:test";
import { evaluatePassiveSchoolSource } from "../passiveEngine";
import type { SchoolDomCardEvidence } from "../types";

const ORIGIN = "https://school.example";
const SOURCE_KEY = `portal:${createHash("sha256").update(ORIGIN).digest("hex").slice(0, 32)}`;
const NOW = Date.parse("2026-09-11T15:00:00.000Z");

function card(
  captureId: string,
  groupSelector: string,
  title: string,
  id: string,
  className = groupSelector.replace(/^article\./, ""),
) {
  return {
    captureId,
    selector: `[data-assignment-id="${id}"]`,
    groupSelector,
    tag: "article",
    text: `${title} Due Sep 20`,
    title,
    dueAt: "2026-09-20T23:59:00.000Z",
    sourceRecordId: id,
    classTokens: [className],
    childTags: ["h3", "time"],
    attributes: { class: className, "data-assignment-id": id },
  };
}

function captureLine(
  cards: SchoolDomCardEvidence[],
  observedAt = "2026-09-11T14:59:30.000Z",
  path = "/assignments",
  pageRole?: "collection" | "detail" | "messages" | "grades" | "attachments" | "unknown",
) {
  const fragments = cards.map((item) => (
    `<ibacalao-card data-capture-id="${item.captureId}"><article class="${item.classTokens?.[0] ?? ""}"><h3>${item.title ?? ""}</h3><time datetime="${item.dueAt ?? ""}">Due Sep 20</time></article></ibacalao-card>`
  ));
  return JSON.stringify({
    type: "school.capture",
    sourceSessionId: "test:1",
    sourceKey: SOURCE_KEY,
    origin: ORIGIN,
    originFingerprint: SOURCE_KEY.slice("portal:".length),
    observedAt,
    receivedAt: observedAt,
    payload: {
      kind: "dom-snapshot",
      path,
      ...(pageRole ? { pageRole } : {}),
      rows: [{ tag: "h2", text: "Assignments" }],
      cards,
      sanitizedHtml: `<main>${fragments.join("")}</main>`,
    },
  });
}

function source() {
  return { sourceKey: SOURCE_KEY, origin: ORIGIN, platformLabel: "School Portal" };
}

test("unknown portal learns a local DOM recipe and extracts normalized records", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-passive-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    writeFileSync(captureFile, `${captureLine([
      card("c0", "article.assignment-card", "Biology IA draft", "a1"),
      card("c1", "article.assignment-card", "History essay", "a2"),
    ])}\n`);

    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });
    assert.equal(result.learnedRecipes, 1);
    assert.equal(result.records.length, 2);
    assert.equal(new Set(result.records.map((record) => record.sourceRecordId)).size, 2);
    assert.ok(result.records.every((record) => record.sourceRecordId?.startsWith("school_")));
    assert.equal(result.status.syncMode, "passive_browser");
    assert.equal(result.status.lastSuccessAt, "2026-09-11T14:59:30.000Z");
    assert.ok(result.status.missingCapabilities?.includes("grades"));
    assert.match(readFileSync(recipeFile, "utf8"), /article\.assignment-card/);
    assert.match(readFileSync(join(root, "entities.json"), "utf8"), /source:assignment:a1/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});



test("production can disable new recipe learning when Learn mode is not armed", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-passive-no-learning-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    writeFileSync(captureFile, `${captureLine([
      card("c0", "article.assignment-card", "Biology IA draft", "a1"),
      card("c1", "article.assignment-card", "History essay", "a2"),
    ])}\n`);

    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      learningWindow: null,
      scrapling: { python: join(root, "missing-python") },
    });
    assert.equal(result.learnedRecipes, 0);
    assert.equal(result.records.length, 0);
    assert.ok(result.status.missingCapabilities?.includes("assignments"));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("learning window ignores captures observed before Learn was armed", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-passive-learning-window-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    writeFileSync(captureFile, `${captureLine([
      card("c0", "article.assignment-card", "Biology IA draft", "a1"),
    ], "2026-09-11T14:59:30.000Z")}\n`);

    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      learningWindow: {
        startedAt: "2026-09-11T14:59:45.000Z",
        missingCapabilities: ["assignments", "deadlines"],
      },
      scrapling: { python: join(root, "missing-python") },
    });
    assert.equal(result.learnedRecipes, 0);
    assert.ok(result.status.missingCapabilities?.includes("assignments"));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("message page role can teach generic table rows with no message keyword", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-passive-message-role-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    const rows = [
      { captureId: "m0", selector: "tr:nth-of-type(2)", groupSelector: "#inbox tbody > tr", tag: "tr", text: "Teacher A Project update Sep 11", title: "Project update", classTokens: [], childTags: ["td", "td", "td"], attributes: {}, links: [] },
      { captureId: "m1", selector: "tr:nth-of-type(3)", groupSelector: "#inbox tbody > tr", tag: "tr", text: "Teacher B Schedule change Sep 11", title: "Schedule change", classTokens: [], childTags: ["td", "td", "td"], attributes: {}, links: [] },
    ] satisfies SchoolDomCardEvidence[];
    writeFileSync(captureFile, `${captureLine(rows, "2026-09-11T14:59:30.000Z", "/student/inbox", "messages")}\n`);

    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      learningWindow: { startedAt: "2026-09-11T14:59:00.000Z", missingCapabilities: ["messages"] },
      scrapling: { python: join(root, "missing-python") },
    });
    assert.equal(result.learnedRecipes, 1);
    assert.equal(result.records.length, 2);
    assert.equal(result.records.every((record) => record.kind === "message"), true);
    assert.equal(result.status.missingCapabilities?.includes("messages") ?? false, false);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a later passive login route requires reauth and never uploads stale academic records", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-passive-auth-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    const learned = captureLine([
      card("c0", "article.assignment-card", "Biology IA draft", "a1"),
    ], "2026-09-11T14:58:00.000Z");
    const loginAt = "2026-09-11T14:59:40.000Z";
    const route = JSON.stringify({
      type: "school.capture",
      sourceSessionId: "test:1",
      sourceKey: SOURCE_KEY,
      origin: ORIGIN,
      originFingerprint: SOURCE_KEY.slice("portal:".length),
      observedAt: loginAt,
      receivedAt: loginAt,
      payload: { kind: "route", path: "/login" },
    });
    writeFileSync(captureFile, `${learned}\n`);
    await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: Date.parse("2026-09-11T14:58:30.000Z"),
      scrapling: { python: join(root, "missing-python") },
    });
    writeFileSync(captureFile, `${learned}\n${route}\n`);

    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });
    assert.equal(result.status.actionReason, "reauth_required");
    assert.equal(result.status.connected, false);
    assert.equal(result.status.lastObservedAt, loginAt);
    assert.equal(result.records.length, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a passive challenge is surfaced and academic automation stays paused", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-passive-challenge-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    const observedAt = "2026-09-11T14:59:45.000Z";
    const challenge = JSON.stringify({
      type: "school.capture",
      sourceSessionId: "test:1",
      sourceKey: SOURCE_KEY,
      origin: ORIGIN,
      originFingerprint: SOURCE_KEY.slice("portal:".length),
      observedAt,
      receivedAt: observedAt,
      payload: {
        kind: "dom-snapshot",
        path: "/assignments",
        rows: [{ tag: "h2", text: "Verify you are human - security check" }],
      },
    });
    writeFileSync(captureFile, `${challenge}\n`);
    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });
    assert.equal(result.status.actionReason, "challenge_paused");
    assert.equal(result.status.connected, true);
    assert.equal(result.records.length, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a later academic snapshot clears an earlier transient login route", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-passive-auth-clear-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    const loginAt = "2026-09-11T14:58:00.000Z";
    const route = JSON.stringify({
      type: "school.capture",
      sourceSessionId: "test:1",
      sourceKey: SOURCE_KEY,
      origin: ORIGIN,
      originFingerprint: SOURCE_KEY.slice("portal:".length),
      observedAt: loginAt,
      receivedAt: loginAt,
      payload: { kind: "route", path: "/signin" },
    });
    const academic = captureLine([
      card("c0", "article.assignment-card", "Biology IA draft", "a1"),
    ], "2026-09-11T14:59:30.000Z");
    writeFileSync(captureFile, `${route}\n${academic}\n`);
    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });
    assert.notEqual(result.status.actionReason, "reauth_required");
    assert.equal(result.records.length, 1);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a changed card selector self-repairs only after nonzero visible validation", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-repair-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    const first = [
      card("c0", "article.assignment-card", "Biology IA draft", "a1"),
      card("c1", "article.assignment-card", "History essay", "a2"),
    ];
    writeFileSync(captureFile, `${captureLine(first)}\n`);
    await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });

    const changed = [
      card("c7", "article.task-card", "Biology IA draft", "a1", "task-card"),
      card("c8", "article.task-card", "History essay", "a2", "task-card"),
    ];
    writeFileSync(captureFile, `${captureLine(changed, "2026-09-11T14:59:30.000Z")}\n`);
    const shadow = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });
    assert.equal(shadow.repairedRecipes, 0);
    assert.equal(shadow.status.actionReason, "recipe_repairing");
    const shadowStore = JSON.parse(readFileSync(recipeFile, "utf8"));
    assert.equal(shadowStore.sources[SOURCE_KEY].recipes[0].recipe.source.selector, "article.assignment-card");
    assert.equal(shadowStore.sources[SOURCE_KEY].recipes[0].pendingRepair.recipe.source.selector, "article.task-card");

    writeFileSync(captureFile, `${captureLine(changed, "2026-09-11T14:59:45.000Z")}\n`);
    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });

    assert.equal(result.repairedRecipes, 1);
    assert.equal(result.records.length, 2);
    const repairedStore = JSON.parse(readFileSync(recipeFile, "utf8"));
    const repaired = repairedStore.sources[SOURCE_KEY].recipes[0];
    assert.equal(repaired.recipe.source.selector, "article.task-card");
    assert.equal(repaired.pendingRepair, undefined);
    assert.equal(repaired.lastKnownGood.recipe.source.selector, "article.assignment-card");
    assert.notEqual(repaired.lastKnownGood.version, repaired.version);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("equally strong repair targets with different group selectors fail closed", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-ambiguous-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    writeFileSync(captureFile, `${captureLine([
      card("c0", "article.assignment-card", "Biology IA draft", "a1"),
    ])}\n`);
    await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });

    writeFileSync(captureFile, `${captureLine([
      card("c2", "article.task-a", "Biology IA draft", "a1", "task-a"),
      card("c3", "article.task-b", "History essay", "a2", "task-b"),
    ])}\n`);
    const result = await evaluatePassiveSchoolSource(source(), {
      captureFile,
      recipeFile,
      nowMs: NOW,
      scrapling: { python: join(root, "missing-python") },
    });
    assert.equal(result.repairedRecipes, 0);
    assert.equal(result.status.actionReason, "manual_learning_required");
    assert.match(readFileSync(recipeFile, "utf8"), /article\.assignment-card/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("durable captures older than five minutes are consumed but never reported healthy", async () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-stale-"));
  try {
    const captureFile = join(root, "captures.ndjson");
    const recipeFile = join(root, "recipes.json");
    writeFileSync(captureFile, `${captureLine([
      card("c0", "article.assignment-card", "Biology IA draft", "a1"),
    ], "2026-09-11T14:50:00.000Z")}\n`);
    const result = await evaluatePassiveSchoolSource(source(), { captureFile, recipeFile, nowMs: NOW });
    assert.equal(result.observedCaptures, 1);
    assert.equal(result.records.length, 1);
    assert.equal(result.status.connected, false);
    assert.equal(result.status.actionReason, "connector_stale");
    assert.equal(result.status.recipe?.state, "stale");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
