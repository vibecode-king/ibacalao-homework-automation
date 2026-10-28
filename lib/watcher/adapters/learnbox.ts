// lib/watcher/adapters/learnbox.ts
// Learnbox extractor for the watcher daemon's own persistent session.
//
// SCOPE: actively crawls messages, assignments, and grades collections, using
// the daemon's own session. Assignment titles come from table headings (never
// the first cell). Message rows are inbox detail links, not a brittle nth-child
// container. Grades still need the on-page period filters before a table exists.
// Deadlines are derived from assignment due dates; submissions only when the
// assignment status already says delivered. Assignment attachment links are
// fetched through Playwright's authenticated request context and parsed locally
// in memory when they are a supported document type. Inbox pagination is
// bounded and reported as partial when Página X de Y is not exhausted.
// Zero-record crawls are "selector may be stale" unless the page has a
// valid-empty marker.
//
// ⚠️ SELECTORS ARE FROM TWO LEARNED RECIPES (~/.ibacalao/school/recipes.json:
// entity "message" / "/modules/message/fInbox", entity "assignment" /
// "/modules/activity/fStudentCalendarActivity"). Nobody has audited them
// against Learnbox's live markup beyond those two observations — same
// caveat lib/watcher/adapters/managebac.ts states for its own selectors.
// Learnbox is multi-tenant (school subdomain varies) so this is written
// generically against whatever origin the connection reports, not hardcoded
// to one school. Treat a zero-record crawl as "selector may be stale", not
// "nothing exists" — a console.warn below makes that distinguishable in the
// daemon's logs.
//
// SAME SCRAPLING REPAIR AS THE PASSIVE PATH, WITH THE SAME SAFETY NET: every
// successful crawl banks a Scrapling signature of the matched element under
// this portal's recipe bundle (lib/school/recipeStore.ts — the same store
// lib/school/passiveEngine.ts's tryRepair reads/writes, so a school with both
// an active adapter and passive browser-extension captures shares one
// signature history instead of keeping two). When a selector then finds zero
// elements, that banked signature is handed to runScraplingRepair against the
// page actually fetched this run. The candidate is run through the exact
// same validateAdaptiveRepair/activateValidatedRepair gate the passive path
// The candidate is run through validateAdaptiveRepair, then staged as a
// pending repair (lib/school/recipeStore.ts stageRepairCandidate). It is
// promoted only after a second independent observation, and lastKnownGood is
// kept so detectRecipeRegression can roll it back.
// hardcoded MESSAGES_SELECTOR/ASSIGNMENTS_SELECTOR constants below are only
// ever the *starting point*: every crawl first checks the recipe store for
// an adopted repair and prefers that when one exists.

import { createHash } from "node:crypto";
import {
  mergeContentIntegrity,
  normalizePresentationAnomalies,
  sanitizePresentedText,
  type ContentIntegritySummary,
} from "@/lib/security/contentIntegrity";
import { evaluatePassiveSchoolSource, refinePlatformGraph, type PassiveEngineOptions } from "@/lib/school/passiveEngine";
import { openSchoolJournal } from "@/lib/school/journal";
import { ensurePlatformGraphSchema, readPlatformNodes, type PlatformNode, type PlatformNodeObservation } from "@/lib/school/platformGraph";
import { planCapabilityPath } from "@/lib/school/crawlPlan";
import { CAPABILITY_FOR_ENTITY } from "@/lib/school/capabilityHealth";
import { recordFromCard } from "@/lib/school/evidence";
import { matchEmptyMarker } from "@/lib/school/emptyState";
import { scoreMessageImportance } from "@/lib/school/messageImportance";
import { isNonAcademicTitle, parseAcademicRow } from "@/lib/school/tableParse";
import { activateValidatedRepair } from "@/lib/school/recipe";
import {
  loadRecipeBundle,
  recipeId,
  recipeVersion,
  saveRecipeBundle,
  stageRepairCandidate,
  type StoredSchoolRecipe,
} from "@/lib/school/recipeStore";
import { detectRecipeRegression, fieldCompleteness, rollbackToLastKnownGood } from "@/lib/school/recipeLifecycle";
import { overlayCapabilityHealth, summarizeCapabilityHealth } from "@/lib/school/capabilityHealth";
import { runScraplingRepair, runScraplingSignature } from "@/lib/school/scraplingSidecar";
import type { SchoolDomCardEvidence, SchoolRecipe } from "@/lib/school/types";
import { validateAdaptiveRepair } from "@/lib/school/validation";
import { discoverAndExtractSchoolAttachments, type SchoolAttachmentLink } from "../attachmentDiscovery";
import { saveSchoolOriginal } from "../schoolDocs";
import { looksLikeAuthWall, looksLikeChallenge } from "../detect";
import type { CrawlCoverage, CrawlOutcome, PlatformAdapter, ScrapedRecord, WatcherPage } from "../types";
import { LEARNBOX_BROWSER_EVAL_BODY } from "./learnbox.browserEvalSource";

/** tsx/esbuild inject `__name` into Function bodies passed to Playwright; use one string expression per call. */
async function runLearnboxBrowserEval<T>(page: WatcherPage, expression: string): Promise<T> {
  if (!page.evaluate) throw new Error("page does not support evaluate()");
  await ensureLearnboxBrowserEval(page);
  const evaluate = page.evaluate.bind(page) as unknown as (expression: string) => Promise<T>;
  return evaluate(expression);
}

async function ensureLearnboxBrowserEval(page: WatcherPage): Promise<void> {
  if (!page.evaluate) return;
  const evaluate = page.evaluate.bind(page) as unknown as (expression: string) => Promise<unknown>;
  const loaded = await evaluate("Boolean(globalThis.__ibacalaoLearnboxEval)").catch(() => false);
  if (loaded) return;
  const withScript = page as WatcherPage & {
    addScriptTag?: (options: { content: string }) => Promise<unknown>;
  };
  if (withScript.addScriptTag) {
    await withScript.addScriptTag({ content: LEARNBOX_BROWSER_EVAL_BODY });
    return;
  }
  // Direct evaluate — never runLearnboxBrowserEval here or ensure recurses forever.
  await evaluate(`(function(){${LEARNBOX_BROWSER_EVAL_BODY}\nreturn true;})()`);
}

export const MESSAGES_PATH = "/modules/message/fInbox";
const MESSAGES_SELECTOR = 'a[href*="/modules/message/fViewMessageInbox/"]';
export const ASSIGNMENTS_PATH = "/modules/activity/fStudentCalendarActivity";
const ASSIGNMENTS_SELECTOR = "table.dataTableSelectable tbody > tr";
export const GRADES_PATH = "/modules/student_details/fGradesByStudent";
/** Period summary grid (not the activity calendar's dataTableSelectable). */
const GRADES_SELECTOR = "#subjectPeriodSummaryContainer table.gradeTable tbody > tr";

/** Bounded completeness: never walk a 150-page inbox in one poll. */
export const MAX_COLLECTION_PAGES = 8;
/** The inbox is newest-first and only recent mail is worth acting on, so the
 *  newest pages are the whole job for messages, not a truncated read. */
export const MAX_MESSAGE_PAGES = 5;
export const MAX_DETAILS = 12;
/** Five Learnbox inbox pages are normally 50 messages. Detail pages are what
 * give the scorer body + attachment evidence, so cover the whole bounded window. */
export const MAX_MESSAGE_DETAILS = 60;
const SUBMITTED_STATUS = /\b(entregado|enviado|submitted|turned in|entrega realizada)\b/i;
const DIALOG_SELECTOR = ".ui-dialog, [role='dialog']";
const MAX_ASSIGNMENT_ATTACHMENTS = 6;
const MAX_ASSIGNMENT_ATTACHMENT_BYTES = 25 * 1024 * 1024;
const MAX_ASSIGNMENT_ATTACHMENT_TEXT_CHARS = 12_000;
const MAX_ASSIGNMENT_ATTACHMENT_TOTAL_TEXT_CHARS = 24_000;

type LearnboxAttachmentLink = SchoolAttachmentLink;

const LEARNBOX_ATTACHMENT_ATTRIBUTE_RESOLVERS = [{
  attribute: "attlink",
  resolve(value: string): string | null {
    const token = value.trim();
    if (!token || token.includes("/") || token.includes("\\") || !/^[A-Za-z0-9._-]{1,240}$/.test(token)) return null;
    return `/files/message_attachment/${encodeURIComponent(token)}`;
  },
}];

/** Same fingerprint the passive bridge/daemon already use for an origin
 *  without a bundled adapter (scripts/watcher-daemon.ts's
 *  sourceKeyForConnection) — kept in sync so both paths address the same
 *  recipe/entity store. */
export function portalSourceKey(origin: string): string {
  return `portal:${createHash("sha256").update(origin).digest("hex").slice(0, 32)}`;
}

type EvaluatedElement = {
  title: string | null;
  text: string;
  cells?: string[];
  headers?: string[];
  href?: string | null;
  sourceRecordId?: string | null;
  teacher?: string | null;
  rowId?: string | null;
};
type TitleStrategy = "heading-or-text" | "first-cell";
type DetailStrategy = "none" | "href" | "dialog";

// Two title strategies because the two learned containers have genuinely
// different shapes: a message row is effectively one text blob (a heading,
// if any, is the real title), but an assignment row is a multi-column table
// row — falling back to the whole row's text there would concatenate every
// column together into one garbled "title" instead of the actual assignment
// name, AND would almost never match the passive capture's own per-column
// title closely enough to merge into the same record (they'd show up as
// ugly near-duplicates instead of one enriched entry). The actual DOM
// traversal is inlined inside crawlEntity's page.evaluate call below rather
// than calling a shared function from here — Playwright serializes that
// callback and re-runs it inside the real browser, where this module's other
// functions do not exist.

/** Pure and testable without a real page: turns one evaluated DOM element
 *  into the same card shape lib/school/evidence.ts's recordFromCard expects,
 *  mirroring what the passive browser extension's content.js already builds. */
export function cardFromEvaluatedElement(
  raw: EvaluatedElement,
  index: number,
  selector: string = MESSAGES_SELECTOR,
  idPrefix: string = "learnbox",
): SchoolDomCardEvidence | null {
  const parsed = raw.cells && raw.cells.length > 0
    ? parseAcademicRow(raw.headers ?? [], raw.cells)
    : null;
  // Table rows must map through headings. Falling back to the first cell is
  // how "BIOLOGÍA" / "Materia" became fake assignments on live Learnbox.
  if (raw.cells && raw.cells.length > 0 && !parsed) return null;
  const title = parsed?.title || raw.title || raw.text.slice(0, 300);
  if (!title?.trim() || isNonAcademicTitle(title)) return null;
  const teacher = parsed ? undefined : (raw.teacher || undefined);
  return {
    captureId: `${idPrefix}-${index}`,
    selector,
    groupSelector: selector,
    tag: parsed ? "tr" : "div",
    text: raw.text,
    title,
    ...(parsed?.subject ? { subject: parsed.subject } : {}),
    ...(parsed?.dueAt ? { dueAt: parsed.dueAt } : {}),
    ...(parsed?.status ? { status: parsed.status } : {}),
    ...(parsed?.grade ? { grade: parsed.grade } : {}),
    ...(teacher ? { teacher } : {}),
    ...(raw.href ? { path: raw.href } : {}),
    ...(raw.sourceRecordId ? { sourceRecordId: raw.sourceRecordId } : {}),
    ...(raw.href ? { links: [{ path: raw.href, relationship: "detail" as const, text: title.slice(0, 240) }] } : {}),
  };
}

/** Inbox detail pages include Learnbox chrome (VER MENSAJE / Agenda). Keep DE:…body. */
export function cleanLearnboxMessageDetail(text: string): string {
  const normalized = text.replace(/\s+/g, " ").trim();
  const fromDe = normalized.search(/\bDE:\s/i);
  let body = fromDe >= 0 ? normalized.slice(fromDe) : normalized.replace(/^(VER MENSAJE\s+)?Menú\s+Agenda[\s\S]*?(?=\bDE:|$)/i, "");
  body = body.replace(/\s*(Responder Mensaje\s*)?(Guardar\s*\|\s*Borrar).*$/i, "");
  return body.trim().slice(0, 12_000);
}

/** Leftover jQuery UI dialogs stay in the DOM after a failed close. Refuse
 *  to copy that body onto a different assignment. */
export function assignmentDetailMatchesRecord(title: string | undefined, detailText: string): boolean {
  const needle = (title ?? "").replace(/\s+/g, " ").trim().toLowerCase();
  if (needle.length < 4) return true;
  return detailText.replace(/\s+/g, " ").trim().toLowerCase().includes(needle);
}

/** Deadlines from due dates; submissions only when Learnbox already marked delivery. */
export function derivedRecordsFromAssignments(assignments: ScrapedRecord[]): ScrapedRecord[] {
  const derived: ScrapedRecord[] = [];
  for (const assignment of assignments) {
    const id = assignment.sourceRecordId ?? assignment.platformId;
    if (!id) continue;
    if (assignment.dueAt) {
      derived.push({
        ...assignment,
        kind: "deadline",
        sourceRecordId: `deadline:${id}`,
        platformId: undefined,
      });
    }
    const haystack = `${assignment.status ?? ""} ${assignment.detail ?? ""}`;
    if (SUBMITTED_STATUS.test(haystack)) {
      derived.push({
        ...assignment,
        kind: "submission",
        sourceRecordId: `submission:${id}`,
        platformId: undefined,
      });
    }
  }
  return derived;
}

export type EntityCrawlConfig = {
  entity: SchoolRecipe["entity"];
  path: string;
  selector: string;
  titleStrategy: TitleStrategy;
  idPrefix: string;
  detailStrategy?: DetailStrategy;
};

/** The identity of a recipe is always anchored to the hardcoded starting
 *  selector, not whatever is currently adopted — so a permanently-adopted
 *  repair still resolves back to the same store entry next time, letting
 *  its `recipe.source.selector` be updated in place rather than orphaning a
 *  new entry every time a repair lands. */
function recipeFor(config: EntityCrawlConfig): SchoolRecipe {
  return {
    schemaVersion: 1,
    entity: config.entity,
    source: { kind: "observed-dom", container: config.path, selector: config.selector },
    fields: {},
  };
}

function lookupStoredRecipe(origin: string, config: EntityCrawlConfig): StoredSchoolRecipe | undefined {
  const bundle = loadRecipeBundle(portalSourceKey(origin), origin);
  const id = recipeId(recipeFor(config));
  return bundle.recipes.find((stored) => stored.id === id);
}

/**
 * A validated Scrapling candidate is staged, not immediately adopted.
 * Promotion needs a second independent observation (stageRepairCandidate).
 */
export function applyStagedLearnboxRepair(
  stored: StoredSchoolRecipe,
  candidateRecipe: SchoolRecipe,
  confidence: number,
  observedAt: string,
): { stored: StoredSchoolRecipe; promoted: boolean } {
  const version = recipeVersion(candidateRecipe);
  const staged = stageRepairCandidate(
    stored.pendingRepair,
    {
      recipe: candidateRecipe,
      version,
      confidence,
      structuralSignature: stored.structuralSignature,
    },
    observedAt,
    { quarantined: stored.quarantined },
  );
  if (!staged.promote) {
    return {
      promoted: false,
      stored: { ...stored, pendingRepair: staged.pendingRepair, updatedAt: observedAt },
    };
  }
  return {
    promoted: true,
    stored: {
      ...stored,
      recipe: candidateRecipe,
      version,
      confidence,
      updatedAt: observedAt,
      lastKnownGood: {
        recipe: stored.recipe,
        version: stored.version,
        confidence: stored.confidence,
        updatedAt: stored.updatedAt,
        structuralSignature: stored.structuralSignature,
        ...(stored.scraplingSignature ? { scraplingSignature: stored.scraplingSignature } : {}),
      },
      pendingRepair: undefined,
    },
  };
}

async function prepareGradeFilters(page: WatcherPage): Promise<void> {
  if (!page.evaluate) return;
  const pickValue = async (selector: string, skipZero: boolean, prefer: "first" | "last" | "selected") => {
    await runLearnboxBrowserEval(
      page,
      `globalThis.__ibacalaoLearnboxEval.pickFirstSelectOption(${JSON.stringify({ selector, skipZero, prefer })})`,
    );
  };
  await page.waitForSelector?.("#selSchoolYear", { timeout: 15_000 }).catch(() => undefined);
  // Current school year is usually the last populated option, not "- Seleccione -".
  await pickValue("#selSchoolYear", false, "last");
  await page.waitForSelector?.("#selPeriod option[value]:not([value='']):not([value='0'])", {
    timeout: 15_000,
    state: "attached",
  }).catch(() => undefined);
  // Year change loads periods via AJAX and auto-selects PERIODO 1, which triggers the summary table.
  await pickValue("#selPeriod", true, "first");
  await page.waitForSelector?.(GRADES_SELECTOR.replace(" tbody > tr", " tbody tr td"), {
    timeout: 20_000,
  }).catch(() => undefined);
}

/** Builds records the same way crawlEntity's final step does, but keeps each
 *  record paired with the card it came from — needed to check the passive
 *  path's "visible text agrees with the record" validation rule without
 *  risking an off-by-one if a card ever fails to produce a record. */
function recordsFromElements(
  elements: EvaluatedElement[],
  selector: string,
  origin: string,
  config: EntityCrawlConfig,
  observedAt: string,
): Array<{ card: SchoolDomCardEvidence; record: ScrapedRecord }> {
  const cards = elements
    .map((raw, index) => cardFromEvaluatedElement(raw, index, selector, config.idPrefix))
    .filter((card): card is SchoolDomCardEvidence => card !== null);
  return cards.flatMap((card) => {
    const record = recordFromCard(config.entity, card, origin, config.path, "collection", observedAt);
    return record ? [{ card, record }] : [];
  });
}

function safePath(raw: string | null | undefined, origin: string): string | null {
  if (!raw) return null;
  try {
    const url = new URL(raw, origin);
    if (url.origin !== new URL(origin).origin) return null;
    return `${url.pathname}${url.search}`.slice(0, 500);
  } catch {
    return null;
  }
}

async function evaluateElements(
  page: WatcherPage,
  selector: string,
  strategy: TitleStrategy,
): Promise<EvaluatedElement[]> {
  await ensureLearnboxBrowserEval(page);
  return runLearnboxBrowserEval(
    page,
    `globalThis.__ibacalaoLearnboxEval.evaluateElementsInBrowser(${JSON.stringify({ selector, strategy })})`,
  );
}

type CollectionMeta = {
  pageText: string;
  nextHref: string | null;
  pageCurrent: number | null;
  pageTotal: number | null;
};

async function evaluateCollectionMeta(page: WatcherPage): Promise<CollectionMeta> {
  const fallback: CollectionMeta = { pageText: "", nextHref: null, pageCurrent: null, pageTotal: null };
  if (!page.evaluate) return fallback;
  try {
    await ensureLearnboxBrowserEval(page);
    const result = await runLearnboxBrowserEval<CollectionMeta>(
      page,
      "globalThis.__ibacalaoLearnboxEval.evaluateCollectionMetaInBrowser()",
    );
    if (result && typeof result === "object" && !Array.isArray(result) && "pageText" in result) {
      return result as CollectionMeta;
    }
  } catch {
    return fallback;
  }
  return fallback;
}

async function advanceCollectionPage(page: WatcherPage, currentPage: number, selector: string): Promise<boolean> {
  if (!page.evaluate || !Number.isInteger(currentPage) || currentPage < 1) return false;
  try {
    await ensureLearnboxBrowserEval(page);
    return Boolean(await runLearnboxBrowserEval<boolean>(
      page,
      `globalThis.__ibacalaoLearnboxEval.advanceCollectionPageInBrowser(${JSON.stringify({ targetPage: currentPage + 1, timeoutMs: 8_000, selector })})`,
    ));
  } catch {
    return false;
  }
}

function withMessageImportance(record: ScrapedRecord, attachments: string[] = []): ScrapedRecord {
  if (record.kind !== "message") return record;
  const ranked = scoreMessageImportance({
    sender: record.teacher,
    heading: record.title,
    body: record.detail,
    attachments,
  });
  return {
    ...record,
    urgency: ranked.level,
    importanceScore: ranked.score,
    importanceReasons: ranked.reasons,
  };
}

/** Scrapling's signature operation deliberately signs only a child of a
 * synthetic ibacalao-card. Active crawls do not naturally have that wrapper,
 * so make the contract explicit here instead of relying on passive-capture HTML. */
export function wrapLearnboxSignatureHtml(outerHtml: string, captureId: string): string | null {
  if (!outerHtml.trim()) return null;
  if (!/^[A-Za-z0-9_-]{1,40}$/.test(captureId)) return null;
  return `<ibacalao-card data-capture-id="${captureId}">${outerHtml}</ibacalao-card>`;
}

/** Best-effort: banks what a working match currently looks like, so a later
 *  zero-element crawl has something to hand Scrapling for repair. Never
 *  allowed to fail the crawl itself — a signature miss just means the next
 *  break, if any, falls back to the old "selector may be stale" log only.
 *  Always signs the CURRENTLY EFFECTIVE selector, not the original hardcoded
 *  one, so a permanently-adopted repair keeps refreshing its own baseline
 *  going forward instead of quietly going stale itself. */
async function bankSuccessSignature(
  page: WatcherPage,
  origin: string,
  currentUrl: string,
  config: EntityCrawlConfig,
  effectiveSelector: string,
): Promise<void> {
  try {
    await ensureLearnboxBrowserEval(page);
    const outerHtml = await runLearnboxBrowserEval<string>(
      page,
      `globalThis.__ibacalaoLearnboxEval.outerHtmlForSelector(${JSON.stringify(effectiveSelector)})`,
    );
    if (typeof outerHtml !== "string" || !outerHtml) return;
    const captureId = `${config.idPrefix}-signature`;
    const signatureHtml = wrapLearnboxSignatureHtml(outerHtml, captureId);
    if (!signatureHtml) return;
    const signature = await runScraplingSignature({
      currentHtml: signatureHtml,
      currentUrl,
      captureId,
    });
    if (!signature.ok) return;

    const sourceKey = portalSourceKey(origin);
    const bundle = loadRecipeBundle(sourceKey, origin);
    const recipe = recipeFor(config);
    const id = recipeId(recipe);
    const now = new Date().toISOString();
    const existing = bundle.recipes.find((stored) => stored.id === id);
    const updated: StoredSchoolRecipe = existing
      ? { ...existing, updatedAt: now, scraplingSignature: signature.signature }
      : {
          id,
          recipe: { ...recipe, source: { ...recipe.source, selector: effectiveSelector } },
          version: recipeVersion(recipe),
          confidence: 1,
          learnedAt: now,
          updatedAt: now,
          structuralSignature: { tag: "unknown", classTokens: [], attributeNames: [], childTags: [] },
          scraplingSignature: signature.signature,
        };
    saveRecipeBundle({
      ...bundle,
      updatedAt: now,
      recipes: [...bundle.recipes.filter((stored) => stored.id !== id), updated],
    });
  } catch (error) {
    console.warn(`[learnbox] could not bank a Scrapling signature for ${config.entity}:`, error);
  }
}

/** Same activation gate the passive path uses (lib/school/validation.ts,
 *  lib/school/recipe.ts): a repair candidate must produce real records with
 *  the expected fields and visible text agreeing with what a person would
 *  see before it is trusted enough to persist as this recipe's new selector.
 *  Returns the elements to use for THIS crawl either way (repaired-and-kept
 *  or repaired-but-rejected) — the caller does not need to know which. */
async function attemptScraplingRepair(
  page: WatcherPage,
  origin: string,
  currentUrl: string,
  html: string,
  config: EntityCrawlConfig,
): Promise<EvaluatedElement[]> {
  const bundle = loadRecipeBundle(portalSourceKey(origin), origin);
  const baseRecipe = recipeFor(config);
  const id = recipeId(baseRecipe);
  const stored = bundle.recipes.find((candidate) => candidate.id === id);
  if (!stored?.scraplingSignature) return [];

  const result = await runScraplingRepair({
    oldRecipe: baseRecipe,
    oldElementSignature: stored.scraplingSignature,
    currentHtml: html,
    currentUrl,
    expectedEntity: config.entity,
  });
  if (!result.ok || !result.candidateRecipe.source.selector) return [];
  const candidateSelector = result.candidateRecipe.source.selector;

  const elements = await evaluateElements(page, candidateSelector, config.titleStrategy).catch(() => []);
  const observedAt = new Date().toISOString();
  const pairs = recordsFromElements(elements, candidateSelector, origin, config, observedAt);
  const hasExpectedFields = pairs.length > 0; // recipeFor()'s fields are {} — recordFromCard already guarantees a title
  const visibleDataAgrees = pairs.length > 0 && pairs.every(({ card, record }) =>
    card.text.toLowerCase().includes(record.title.toLowerCase().slice(0, Math.min(40, record.title.length))),
  );

  const validation = validateAdaptiveRepair({
    result,
    recordCount: pairs.length,
    hasExpectedFields,
    visibleDataAgrees,
  });
  const accepted = activateValidatedRepair(result, validation);

  if (accepted) {
    const now = new Date().toISOString();
    const applied = applyStagedLearnboxRepair(stored, accepted, result.confidence, now);
    saveRecipeBundle({
      ...bundle,
      updatedAt: now,
      recipes: [...bundle.recipes.filter((candidate) => candidate.id !== id), applied.stored],
    });
    console.warn(
      `[learnbox] selector for ${config.entity} was stale; Scrapling suggested "${candidateSelector}" `
      + `(confidence=${result.confidence.toFixed(2)}, ${pairs.length} records)`
      + (applied.promoted
        ? ` and it was PROMOTED after repeated agreement.`
        : ` and it was STAGED as a candidate (needs a second independent observation before replacing active).`),
    );
  } else {
    console.warn(
      `[learnbox] selector for ${config.entity} found zero elements; Scrapling suggested "${candidateSelector}" `
      + `(confidence=${result.confidence.toFixed(2)}) but validation rejected it (${validation.reasons.join(", ") || "no reason recorded"}) — `
      + `using it for this crawl only, not persisted.`,
    );
  }

  return elements;
}

/** Exported so a config's selector can be driven directly — mirrors why
 *  cardFromEvaluatedElement above is exported: testable without spinning up
 *  the whole adapter/session lifecycle. */
export async function crawlEntity(page: WatcherPage, origin: string, config: EntityCrawlConfig): Promise<CrawlOutcome> {
  const url = new URL(config.path, origin).toString();
  await page.goto(url, { timeout: 30_000 });
  const html = await page.content();
  const currentUrl = page.url();
  if (looksLikeAuthWall(currentUrl, html)) return { ok: false, reason: "auth_required" };
  if (looksLikeChallenge(currentUrl, html)) return { ok: false, reason: "challenged" };

  if (!page.evaluate) return { ok: false, reason: "error", message: "page does not support evaluate()" };

  if (config.entity === "grade") {
    await prepareGradeFilters(page);
  }

  // A previously-adopted repair takes priority over the hardcoded constant —
  // it is, by definition, the most recently validated-working selector.
  const stored = lookupStoredRecipe(origin, config);
  let effectiveSelector = stored?.recipe.source.selector || config.selector;

  // goto() only waits for the 'load' event, which fires before a
  // single-page app's own async data fetch has rendered real rows — reading
  // the DOM immediately after can race an empty shell and log a false
  // "selector may be stale" every single crawl. A timeout here is not
  // itself a failure: it may just mean this list is genuinely empty, so the
  // crawl still proceeds to evaluate() rather than erroring out.
  await page.waitForSelector?.(effectiveSelector, { timeout: 8_000 }).catch(() => undefined);

  let elements = (await evaluateElements(page, effectiveSelector, config.titleStrategy)) ?? [];

  if (elements.length === 0) {
    const meta = await evaluateCollectionMeta(page);
    const emptyMarker = matchEmptyMarker(meta.pageText);
    if (emptyMarker) {
      return {
        ok: true,
        records: [],
        coverage: { pagesSeen: 1, hasMore: false, detailsAttempted: 0, detailsSucceeded: 0, completeness: "complete" },
      };
    }
    console.warn(`[learnbox] active crawl of ${config.path} found zero elements for selector "${effectiveSelector}" — selector may be stale, not necessarily empty`);
    const repaired = await attemptScraplingRepair(page, origin, currentUrl, html, config).catch(() => []);
    if (repaired.length > 0) {
      elements = repaired;
      const refreshed = lookupStoredRecipe(origin, config);
      effectiveSelector = refreshed?.recipe.source.selector || effectiveSelector;
    }
  } else {
    await bankSuccessSignature(page, origin, currentUrl, config, effectiveSelector);
  }

  const observedAt = new Date().toISOString();
  const toRecords = (batch: EvaluatedElement[], startIndex: number) =>
    batch
      .map((raw, index) => cardFromEvaluatedElement(raw, startIndex + index, effectiveSelector, config.idPrefix))
      .flatMap((card) => {
        if (!card) return [];
        const pageRole = card.path && card.path !== config.path ? "detail" as const : "collection" as const;
        const record = recordFromCard(config.entity, card, origin, card.path ?? config.path, pageRole, observedAt);
        return record ? [record] : [];
      });

  const records = toRecords(elements, 0);
  let collectedElements = [...elements];
  let pagesSeen = 1;
  let hasMore = false;
  const seenIds = new Set(records.map((record) => record.sourceRecordId ?? record.url ?? record.title));

  const maxPages = config.entity === "message" ? MAX_MESSAGE_PAGES : MAX_COLLECTION_PAGES;
  while ((config.entity === "message" || config.entity === "assignment") && pagesSeen < maxPages) {
    const meta = await evaluateCollectionMeta(page);
    const nextPath = safePath(meta.nextHref, origin);
    hasMore = Boolean(
      (meta.pageCurrent && meta.pageTotal && meta.pageCurrent < meta.pageTotal)
      || nextPath,
    );
    if (!hasMore) break;

    let advanced = false;
    if (nextPath) {
      await page.goto(new URL(nextPath, origin).toString(), { timeout: 30_000 });
      advanced = true;
    } else if (config.entity === "message" && meta.pageCurrent) {
      // Live Learnbox uses a delegated JS click handler on an LI pager with no
      // href/data-page. The browser helper only returns true after it observes
      // the visible page counter actually advance, so a dead click cannot loop.
      advanced = await advanceCollectionPage(page, meta.pageCurrent, effectiveSelector);
    }

    if (!advanced) {
      console.log(
        `[learnbox] ${config.entity} pagination stopped at page ${meta.pageCurrent ?? "?"} of ${meta.pageTotal ?? "?"}: `
        + `no verified next-page action`,
      );
      break;
    }

    const afterHtml = await page.content();
    if (looksLikeAuthWall(page.url(), afterHtml)) return { ok: false, reason: "auth_required" };
    if (looksLikeChallenge(page.url(), afterHtml)) return { ok: false, reason: "challenged" };
    await page.waitForSelector?.(effectiveSelector, { timeout: 8_000 }).catch(() => undefined);
    const extra = await evaluateElements(page, effectiveSelector, config.titleStrategy);
    collectedElements = collectedElements.concat(extra);
    const extraRecords = toRecords(extra, records.length);
    let fresh = 0;
    for (const record of extraRecords) {
      const id = record.sourceRecordId ?? record.url ?? record.title;
      if (seenIds.has(id)) continue;
      seenIds.add(id);
      records.push(record);
      fresh += 1;
    }
    if (extraRecords.length > 0 && fresh === 0) {
      // Same rows as a page already read: the "next" page never loaded. Stop
      // with hasMore still true so the crawl reports partial, not complete.
      console.log(`[learnbox] ${config.entity} pagination stopped: page ${pagesSeen + 1} repeated rows already seen`);
      hasMore = true;
      break;
    }
    pagesSeen += 1;
    const again = await evaluateCollectionMeta(page);
    hasMore = Boolean(
      (again.pageCurrent && again.pageTotal && again.pageCurrent < again.pageTotal)
      || safePath(again.nextHref, origin),
    );
  }

  const details = await enrichDetails(page, origin, records, collectedElements, config);
  let finalRecords = details.records;
  const currentStored = lookupStoredRecipe(origin, config);
  const previousSelector = currentStored?.lastKnownGood?.recipe.source.selector;
  if (currentStored && previousSelector && previousSelector !== effectiveSelector) {
    const comparisonElements = await evaluateElements(page, previousSelector, config.titleStrategy).catch(() => []);
    const comparisonRecords = toRecords(comparisonElements, 0);
    const regression = detectRecipeRegression(finalRecords, comparisonRecords);
    if (regression) {
      const rolled = rollbackToLastKnownGood(currentStored, regression, new Date().toISOString());
      if (rolled) {
        const bundle = loadRecipeBundle(portalSourceKey(origin), origin);
        saveRecipeBundle({
          ...bundle,
          updatedAt: rolled.updatedAt,
          recipes: [...bundle.recipes.filter((candidate) => candidate.id !== rolled.id), rolled],
        });
        console.warn(
          `[learnbox] promoted selector for ${config.entity} regressed (${regression.reason}); rolled back to lastKnownGood.`,
        );
        finalRecords = comparisonRecords;
        effectiveSelector = previousSelector;
      }
    }
  }

  // Older mail past the recent window is intentionally skipped, so reaching
  // it is a complete read; any other collection with more pages is partial.
  const truncated = hasMore && !(config.entity === "message" && pagesSeen >= MAX_MESSAGE_PAGES);
  const completeness: CrawlCoverage["completeness"] = truncated
    ? "partial"
    : finalRecords.length > 0 || matchEmptyMarker((await evaluateCollectionMeta(page)).pageText)
      ? "complete"
      : "unknown";

  return {
    ok: true,
    records: finalRecords,
    coverage: {
      pagesSeen,
      hasMore,
      detailsAttempted: details.attempted,
      detailsSucceeded: details.succeeded,
      completeness,
    },
  };
}

type LearnboxAssignmentDetail = {
  text: string;
  sourceRecordId?: string | null;
  teacher?: string;
  dueAt?: string;
  status?: string;
  attachments: LearnboxAttachmentLink[];
  contentIntegrity?: ContentIntegritySummary;
};

async function evaluateDetailDialog(page: WatcherPage, expectedId?: string): Promise<LearnboxAssignmentDetail | null> {
  if (!page.evaluate) return null;
  try {
    await ensureLearnboxBrowserEval(page);
    const result = await runLearnboxBrowserEval(
      page,
      `globalThis.__ibacalaoLearnboxEval.evaluateDetailDialogInBrowser(${JSON.stringify(DIALOG_SELECTOR)}, ${JSON.stringify(expectedId ?? null)})`,
    );
    if (!result || Array.isArray(result) || typeof result !== "object" || !("text" in result)) return null;
    const raw = result as Record<string, unknown>;
    if (typeof raw.text !== "string") return null;
    const sanitized = sanitizePresentedText(raw.text, normalizePresentationAnomalies(raw.anomalies));
    const safeTeacher = sanitized.text.match(/Profesor(?:a)?\s*:\s*(.+?)\s+Fecha de Entrega/i)?.[1]?.trim();
    const safeDueAt = sanitized.text.match(/Fecha de Entrega:\s*(\d{4}-\d{2}-\d{2}[^\s]*|\d{1,2}\/\d{1,2}\/\d{4}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?)/i)?.[1];
    const safeStatus = sanitized.text.match(/Estado:\s*([A-Za-zÁÉÍÓÚÑáéíóúñ]+)/i)?.[1]?.trim();
    return {
      text: sanitized.text,
      ...(typeof raw.sourceRecordId === "string" || raw.sourceRecordId === null ? { sourceRecordId: raw.sourceRecordId as string | null } : {}),
      ...(safeTeacher ? { teacher: safeTeacher } : {}),
      ...(safeDueAt ? { dueAt: safeDueAt } : {}),
      ...(safeStatus ? { status: safeStatus } : {}),
      attachments: Array.isArray(raw.attachments)
        ? raw.attachments.filter((item): item is LearnboxAttachmentLink => Boolean(
            item && typeof item === "object" && !Array.isArray(item)
            && typeof (item as LearnboxAttachmentLink).href === "string"
            && typeof (item as LearnboxAttachmentLink).name === "string",
          )).slice(0, 12)
        : [],
      ...(sanitized.integrity ? { contentIntegrity: sanitized.integrity } : {}),
    };
  } catch {
    return null;
  }
}

/**
 * Compatibility wrapper for existing adapter callers/tests. The actual
 * discovery/fetch/parser ladder now lives in attachmentDiscovery.ts so other
 * LMS adapters can reuse the same fallbacks.
 */
export async function extractLearnboxAttachmentContents(
  page: WatcherPage,
  origin: string,
  links: LearnboxAttachmentLink[],
): Promise<{ text: string; extracted: number }> {
  const result = await discoverAndExtractSchoolAttachments(page, origin, {
    seedLinks: links,
    enableRevealInteractions: false,
    enableDownloadInteractions: false,
    maxCandidates: MAX_ASSIGNMENT_ATTACHMENTS,
    maxFileBytes: MAX_ASSIGNMENT_ATTACHMENT_BYTES,
    maxTextCharsPerFile: MAX_ASSIGNMENT_ATTACHMENT_TEXT_CHARS,
    maxTotalTextChars: MAX_ASSIGNMENT_ATTACHMENT_TOTAL_TEXT_CHARS,
  });
  return { text: result.text, extracted: result.extracted };
}

/** Backward-compatible name for existing assignment-specific callers/tests. */
export const extractAssignmentAttachmentContents = extractLearnboxAttachmentContents;

async function closeDetailDialog(page: WatcherPage, expectedId?: string): Promise<void> {
  if (!page.evaluate) return;
  await ensureLearnboxBrowserEval(page);
  await runLearnboxBrowserEval(
    page,
    `globalThis.__ibacalaoLearnboxEval.closeDetailDialogInBrowser(${JSON.stringify(DIALOG_SELECTOR)}, ${JSON.stringify(expectedId ?? null)})`,
  ).catch(() => undefined);
}

async function enrichDetails(
  page: WatcherPage,
  origin: string,
  records: ScrapedRecord[],
  elements: EvaluatedElement[],
  config: EntityCrawlConfig,
): Promise<{ records: ScrapedRecord[]; attempted: number; succeeded: number }> {
  const strategy = config.detailStrategy ?? "none";
  if (strategy === "none") return { records, attempted: 0, succeeded: 0 };

  let attempted = 0;
  let succeeded = 0;
  const updated = [...records];

  if (strategy === "href") {
    const hrefs = Array.from(new Set(updated.flatMap((record) => (
      record.url && /fViewMessageInbox|fView|detail/i.test(record.url) ? [record.url] : []
    )))).slice(0, config.entity === "message" ? MAX_MESSAGE_DETAILS : MAX_DETAILS);
    for (const href of hrefs) {
      attempted += 1;
      await page.goto(href, { timeout: 30_000 });
      const html = await page.content();
      if (looksLikeAuthWall(page.url(), html) || looksLikeChallenge(page.url(), html)) break;
      let extracted = "";
      let attachments: LearnboxAttachmentLink[] = [];
      let detailIntegrity: ContentIntegritySummary | undefined;
      try {
        await ensureLearnboxBrowserEval(page);
        const fromDom = await runLearnboxBrowserEval<unknown>(
          page,
          "globalThis.__ibacalaoLearnboxEval.extractMessageDetailInBrowser()",
        );
        if (fromDom && typeof fromDom === "object" && !Array.isArray(fromDom)) {
          const detail = fromDom as { text?: unknown; anomalies?: unknown; attachments?: unknown };
          if (typeof detail.text === "string") {
            const sanitized = sanitizePresentedText(detail.text, normalizePresentationAnomalies(detail.anomalies));
            extracted = sanitized.text;
            detailIntegrity = sanitized.integrity;
          }
          attachments = Array.isArray(detail.attachments)
            ? detail.attachments.filter((item): item is LearnboxAttachmentLink => Boolean(
                item && typeof item === "object" && !Array.isArray(item)
                && typeof (item as LearnboxAttachmentLink).href === "string"
                && typeof (item as LearnboxAttachmentLink).name === "string",
              )).slice(0, 20)
            : [];
        }
      } catch {
        extracted = "";
        attachments = [];
        detailIntegrity = undefined;
      }
      // `html.replace(/<...>/)` cannot see CSS visibility and would resurrect
      // hidden/white prompt injection if the presentation-aware browser helper
      // failed. Only use that legacy fallback on page implementations that do
      // not support browser evaluation at all.
      const stripped = page.evaluate ? "" : html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
      const text = cleanLearnboxMessageDetail(extracted || stripped);
      const attachmentContent = await discoverAndExtractSchoolAttachments(page, origin, {
        seedLinks: attachments,
        attributeResolvers: LEARNBOX_ATTACHMENT_ATTRIBUTE_RESOLVERS,
        enableRevealInteractions: true,
        enableDownloadInteractions: true,
        maxCandidates: 20,
        maxFileBytes: MAX_ASSIGNMENT_ATTACHMENT_BYTES,
        maxTextCharsPerFile: MAX_ASSIGNMENT_ATTACHMENT_TEXT_CHARS,
        maxTotalTextChars: MAX_ASSIGNMENT_ATTACHMENT_TOTAL_TEXT_CHARS,
      });
      const index = updated.findIndex((record) => record.url === href);
      if (index < 0) continue;
      const current = updated[index];
      const sender = current.teacher ?? text.match(/\bDE:\s*([A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ.' -]{1,80})/i)?.[1]?.trim();
      const contentIntegrity = mergeContentIntegrity(current.contentIntegrity, detailIntegrity, attachmentContent.contentIntegrity);
      updated[index] = withMessageImportance({
        ...current,
        ...(sender ? { teacher: sender } : {}),
        ...(contentIntegrity ? { contentIntegrity } : {}),
        ...((text.length > 20 || attachmentContent.text) ? {
          detail: [text.length > 20 ? text : undefined, attachmentContent.text || undefined].filter(Boolean).join("\n\n"),
        } : {}),
      }, Array.from(new Set([
        ...attachments.map((item) => item.name || item.href),
        ...attachmentContent.names,
      ])));
      succeeded += 1;
    }
    // A detail fetch can fail independently of the inbox list. Every message
    // still gets a deterministic score from the evidence that is available.
    for (let index = 0; index < updated.length; index += 1) {
      if (updated[index].kind === "message" && updated[index].importanceScore === undefined) {
        updated[index] = withMessageImportance(updated[index]);
      }
    }
    return { records: updated, attempted, succeeded };
  }

  const clickTargets = elements
    .map((element) => ({
      element,
      clickId: element.sourceRecordId || element.rowId,
      matchId: element.sourceRecordId || element.rowId,
    }))
    .filter((item): item is { element: EvaluatedElement; clickId: string; matchId: string } => Boolean(item.clickId))
    .slice(0, MAX_DETAILS);
  for (const { element, clickId, matchId } of clickTargets) {
    attempted += 1;
    await ensureLearnboxBrowserEval(page);
    await runLearnboxBrowserEval(
      page,
      `globalThis.__ibacalaoLearnboxEval.clickRowById(${JSON.stringify(clickId)})`,
    ).catch(() => undefined);
    await runLearnboxBrowserEval(
      page,
      `globalThis.__ibacalaoLearnboxEval.waitForAssignmentDialogReady(${JSON.stringify({ selector: DIALOG_SELECTOR, timeoutMs: 12_000, expectedId: clickId })})`,
    ).catch(() => undefined);
    const detail = await evaluateDetailDialog(page, clickId);
    const attachmentContent = detail
      ? await discoverAndExtractSchoolAttachments(page, origin, {
          rootSelector: DIALOG_SELECTOR,
          seedLinks: detail.attachments,
          attributeResolvers: LEARNBOX_ATTACHMENT_ATTRIBUTE_RESOLVERS,
          enableRevealInteractions: true,
          enableDownloadInteractions: true,
          maxCandidates: MAX_ASSIGNMENT_ATTACHMENTS,
          maxFileBytes: MAX_ASSIGNMENT_ATTACHMENT_BYTES,
          maxTextCharsPerFile: MAX_ASSIGNMENT_ATTACHMENT_TEXT_CHARS,
          maxTotalTextChars: MAX_ASSIGNMENT_ATTACHMENT_TOTAL_TEXT_CHARS,
          // Keep the teacher's file so the app can open it as an editable draft.
          onFile: (name, bytes) => { saveSchoolOriginal(matchId, name, bytes); },
        })
      : { text: "", extracted: 0, discovered: 0, interacted: 0, names: [], methods: [], contentIntegrity: undefined };
    await closeDetailDialog(page, clickId);
    if (!detail) continue;
    if (
      !detail.teacher
      && !detail.status
      && !(detail.text && detail.text.length > 80)
      && !attachmentContent.text
      && !detail.contentIntegrity
      && !attachmentContent.contentIntegrity
    ) continue;
    const index = updated.findIndex((record) => {
      const id = record.sourceRecordId;
      return id === matchId || id === element.sourceRecordId || id === element.rowId;
    });
    if (index < 0) continue;
    const current = updated[index];
    const detailId = detail.sourceRecordId?.trim();
    if (detailId ? detailId !== matchId : !assignmentDetailMatchesRecord(current.title, detail.text)) continue;
    const attachmentNote = detail.attachments.length > 0
      ? `Attachments: ${detail.attachments.map((item) => item.name ? `${item.name} ${item.href}` : item.href).join(" ")}`
      : undefined;
    const contentIntegrity = mergeContentIntegrity(current.contentIntegrity, detail.contentIntegrity, attachmentContent.contentIntegrity);
    updated[index] = {
      ...current,
      ...(detail.teacher ? { teacher: detail.teacher } : {}),
      ...(detail.status ? { status: detail.status } : {}),
      ...(detail.dueAt && !current.dueAt ? { dueAt: detail.dueAt } : {}),
      ...(contentIntegrity ? { contentIntegrity } : {}),
      ...(detail.text.length > 80 || attachmentContent.text
        ? { detail: [detail.text, attachmentNote, attachmentContent.text].filter(Boolean).join("\n\n") }
        : {}),
    };
    succeeded += 1;
  }
  return { records: updated, attempted, succeeded };
}

/** Field-level merge: for the same record id, the active crawl's OWN fields
 *  win (it just navigated the real page — fresher than a capture up to five
 *  minutes old), but a field the active side didn't populate does not blank
 *  out a richer value the passive DOM recipe already had. This matters
 *  concretely for assignments: the active crawl now parses table headings, but
 *  a still-sparse row must not blank out richer fields a passive recipe already
 *  captured from a detail page.
 *  Safe because lib/school/evidence.ts's recordFromCard only ever includes
 *  an optional field on the returned object when it found one — a field the
 *  active side lacks is genuinely absent from `record`, not present-but-
 *  undefined, so a plain object spread cannot accidentally erase it. */
export function mergeById(active: ScrapedRecord[], passive: ScrapedRecord[]): ScrapedRecord[] {
  const byId = new Map<string, ScrapedRecord>();
  for (const record of passive) {
    const id = record.sourceRecordId ?? record.platformId;
    if (id) byId.set(id, record);
  }
  for (const record of active) {
    const id = record.sourceRecordId ?? record.platformId;
    if (!id) continue;
    const existing = byId.get(id);
    byId.set(id, existing ? { ...existing, ...record } : record);
  }
  return Array.from(byId.values());
}

function mergeCoverage(parts: Array<CrawlCoverage | undefined>): CrawlCoverage | undefined {
  const present = parts.filter((part): part is CrawlCoverage => Boolean(part));
  if (present.length === 0) return undefined;
  const completeness = present.some((part) => part.completeness === "partial")
    ? "partial"
    : present.every((part) => part.completeness === "complete")
      ? "complete"
      : "unknown";
  return {
    pagesSeen: present.reduce((sum, part) => sum + part.pagesSeen, 0),
    hasMore: present.some((part) => part.hasMore),
    detailsAttempted: present.reduce((sum, part) => sum + part.detailsAttempted, 0),
    detailsSucceeded: present.reduce((sum, part) => sum + part.detailsSucceeded, 0),
    completeness,
  };
}

/** Best effort: no graph means the bundled paths, exactly as before. */
function readGraphNodes(journalFile: string | undefined, sourceKey: string): PlatformNode[] {
  if (!journalFile) return [];
  let db: ReturnType<typeof openSchoolJournal> | null = null;
  try {
    db = openSchoolJournal(journalFile);
    ensurePlatformGraphSchema(db);
    return readPlatformNodes(db, sourceKey);
  } catch {
    return [];
  } finally {
    db?.close();
  }
}

function crawlObservation(
  config: EntityCrawlConfig,
  outcome: Extract<CrawlOutcome, { ok: true }>,
  observedAt: string,
  succeeded = outcome.records.length > 0 || outcome.coverage?.completeness === "complete",
): PlatformNodeObservation {
  return {
    path: config.path,
    pageRole: "collection",
    capability: CAPABILITY_FOR_ENTITY[config.entity],
    activeRecipeId: recipeId(recipeFor(config)),
    observedAt,
    succeeded,
    fieldCompleteness: fieldCompleteness(outcome.records),
  };
}

/**
 * Crawls the page the graph trusts for this capability. When that is not the
 * bundled page, the bundled page is shadow-crawled too and wins on any
 * regression, so a wrong graph can cost an extra page load but never records.
 */
async function crawlPlanned(
  page: WatcherPage,
  origin: string,
  config: EntityCrawlConfig,
  nodes: PlatformNode[],
  observations: PlatformNodeObservation[],
): Promise<CrawlOutcome> {
  const plan = planCapabilityPath(nodes, CAPABILITY_FOR_ENTITY[config.entity], config.path);
  const observedAt = () => new Date().toISOString();
  if (plan.source === "bundled" || plan.path === config.path) {
    const outcome = await crawlEntity(page, origin, config);
    if (outcome.ok) observations.push(crawlObservation(config, outcome, observedAt()));
    return outcome;
  }
  const graphConfig = { ...config, path: plan.path };
  const graph = await crawlEntity(page, origin, graphConfig);
  // Never trust an auth/challenge signal from a learned route alone. A stale
  // graph route can land on a login-looking page while the bundled route is
  // still authenticated; only the bundled route is allowed to surface reauth.
  const bundled = await crawlEntity(page, origin, config);
  if (bundled.ok) observations.push(crawlObservation(config, bundled, observedAt()));
  const regression = bundled.ok ? detectRecipeRegression(graph.ok ? graph.records : [], bundled.records) : null;
  const graphFailed = !graph.ok || regression !== null;
  if (graph.ok) {
    observations.push(crawlObservation(graphConfig, graph, observedAt(), !graphFailed && graph.records.length > 0));
  } else {
    observations.push({
      path: graphConfig.path,
      pageRole: "collection",
      capability: CAPABILITY_FOR_ENTITY[graphConfig.entity],
      activeRecipeId: recipeId(recipeFor(graphConfig)),
      observedAt: observedAt(),
      succeeded: false,
    });
  }
  console.log(
    `[learnbox] ${config.entity} path source=graph ${plan.path}`
    + (graphFailed ? ` regressed (${regression?.reason ?? (graph.ok ? "unknown" : graph.reason)}); using bundled ${config.path}` : ""),
  );
  return graphFailed ? bundled : graph;
}

/** `passiveOptions` exists so tests can point the passive merge at fixture
 *  files instead of the real ~/.ibacalao/school files this reads by default
 *  in production. */
export function createLearnboxAdapter(origin: string, passiveOptions: PassiveEngineOptions = {}): PlatformAdapter {
  return {
    platform: "learnbox",
    label: "Learnbox",
    async crawl(page: WatcherPage): Promise<CrawlOutcome> {
      const messageConfig: EntityCrawlConfig = {
        entity: "message",
        path: MESSAGES_PATH,
        selector: MESSAGES_SELECTOR,
        titleStrategy: "heading-or-text",
        idPrefix: "learnbox-inbox",
        detailStrategy: "href",
      };
      const assignmentConfig: EntityCrawlConfig = {
        entity: "assignment",
        path: ASSIGNMENTS_PATH,
        selector: ASSIGNMENTS_SELECTOR,
        titleStrategy: "first-cell",
        idPrefix: "learnbox-assignments",
        detailStrategy: "dialog",
      };
      const gradeConfig: EntityCrawlConfig = {
        entity: "grade",
        path: GRADES_PATH,
        selector: GRADES_SELECTOR,
        titleStrategy: "first-cell",
        idPrefix: "learnbox-grades",
        detailStrategy: "none",
      };

      const sourceKey = portalSourceKey(origin);
      const graphNodes = readGraphNodes(passiveOptions.journalFile, sourceKey);
      const graphObservations: PlatformNodeObservation[] = [];

      const messages = await crawlPlanned(page, origin, messageConfig, graphNodes, graphObservations);
      if (!messages.ok) return messages;

      const assignments = await crawlPlanned(page, origin, assignmentConfig, graphNodes, graphObservations);
      if (!assignments.ok) {
        console.warn(`[learnbox] assignments crawl failed after a successful messages crawl: ${assignments.reason}`);
      }

      const grades = await crawlPlanned(page, origin, gradeConfig, graphNodes, graphObservations);
      refinePlatformGraph(passiveOptions.journalFile, sourceKey, graphObservations, []);
      if (!grades.ok) {
        console.warn(`[learnbox] grades crawl failed after a successful messages crawl: ${grades.reason}`);
      }

      const assignmentRecords = assignments.ok ? assignments.records : [];
      const derived = derivedRecordsFromAssignments(assignmentRecords);
      const active = [
        ...messages.records,
        ...assignmentRecords,
        ...(grades.ok ? grades.records : []),
        ...derived,
      ];
      const coverage = mergeCoverage([
        messages.ok ? messages.coverage : undefined,
        assignments.ok ? assignments.coverage : undefined,
        grades.ok ? grades.coverage : undefined,
      ]);

      const observedAt = new Date().toISOString();
      const observationFor = (config: EntityCrawlConfig, outcome: CrawlOutcome) => {
        const stored = lookupStoredRecipe(origin, config) ?? {
          id: recipeId(recipeFor(config)),
          recipe: recipeFor(config),
          version: recipeVersion(recipeFor(config)),
          confidence: 1,
          learnedAt: observedAt,
          updatedAt: observedAt,
          structuralSignature: { tag: "unknown" as const, classTokens: [], attributeNames: [], childTags: [] },
        };
        const completeness = outcome.ok && outcome.coverage
          ? outcome.coverage.completeness === "partial"
            ? { state: "partial" as const, reason: "has_next" as const }
            : outcome.coverage.completeness === "complete"
              ? { state: "complete" as const, reason: "single_page" as const }
              : { state: "unknown" as const }
          : undefined;
        return {
          recipe: stored,
          observed: true,
          recordCount: outcome.ok ? outcome.records.filter((record) => record.kind === config.entity).length : 0,
          observedAt,
          method: "active_crawl" as const,
          ...(completeness ? { completeness } : {}),
          ...(!outcome.ok && (outcome.reason === "auth_required" || outcome.reason === "challenged")
            ? { barrier: outcome.reason }
            : {}),
          ...(!outcome.ok && outcome.reason === "error" ? { empty: { state: "unproven" as const } } : {}),
        };
      };

      const deadlineRecords = derived.filter((record) => record.kind === "deadline");
      const submissionRecords = derived.filter((record) => record.kind === "submission");
      const derivedRecipe = (entity: "deadline" | "submission") => {
        const stored = lookupStoredRecipe(origin, assignmentConfig);
        const recipe = { ...recipeFor(assignmentConfig), entity };
        return stored
          ? { ...stored, recipe: { ...stored.recipe, entity } }
          : {
              id: recipeId(recipe),
              recipe,
              version: recipeVersion(recipe),
              confidence: 1,
              learnedAt: observedAt,
              updatedAt: observedAt,
              structuralSignature: { tag: "unknown" as const, classTokens: [], attributeNames: [], childTags: [] },
            };
      };
      const derivedCompleteness = assignments.ok && assignments.coverage
        ? assignments.coverage.completeness === "partial"
          ? { state: "partial" as const, reason: "has_next" as const }
          : assignments.coverage.completeness === "complete"
            ? { state: "complete" as const, reason: "single_page" as const }
            : { state: "unknown" as const }
        : undefined;

      const activeHealth = summarizeCapabilityHealth([
        observationFor(messageConfig, messages),
        observationFor(assignmentConfig, assignments),
        observationFor(gradeConfig, grades),
        {
          recipe: derivedRecipe("deadline"),
          observed: assignments.ok,
          recordCount: deadlineRecords.length,
          observedAt,
          method: "active_crawl" as const,
          ...(derivedCompleteness ? { completeness: derivedCompleteness } : {}),
          ...(deadlineRecords.length === 0 && assignments.ok
            ? { empty: { state: "valid_empty" as const, marker: "no assignment due dates" } }
            : {}),
        },
        {
          recipe: derivedRecipe("submission"),
          observed: assignments.ok,
          recordCount: submissionRecords.length,
          observedAt,
          method: "active_crawl" as const,
          ...(derivedCompleteness ? { completeness: derivedCompleteness } : {}),
          ...(submissionRecords.length === 0 && assignments.ok
            ? { empty: { state: "valid_empty" as const, marker: "no delivered assignment status" } }
            : {}),
        },
      ]);

      // Options go in the second argument: spread into the source they were
      // silently dropped, so tests read this Mac's real ~/.ibacalao files.
      const passive = await evaluatePassiveSchoolSource({
        sourceKey,
        origin,
        platformLabel: "Learnbox",
      }, passiveOptions);
      const capabilities = overlayCapabilityHealth(passive.status.capabilities, activeHealth);

      return {
        ok: true,
        records: mergeById(active, passive.records),
        ...(coverage ? { coverage } : {}),
        capabilities,
      };
    },
  };
}
