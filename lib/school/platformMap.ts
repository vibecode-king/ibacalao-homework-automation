// lib/school/platformMap.ts
// What one Mac learned about a platform, in a form another Mac can use.
//
// The map is declarative data only: route templates, page roles, capabilities
// and the same SchoolRecipe shape local code already interprets. It never
// carries an origin, a sourceKey, record text, HTML, or anything executable,
// and the parser rejects any key it does not know so nothing can be smuggled
// in beside the fields it checks.
//
// A downloaded map is only ever a candidate (stageDownloadedMap): the local
// promotion rules in recipeStore.ts decide whether it ever becomes active.

import { createHash } from "node:crypto";
import { CAPABILITY_FOR_ENTITY } from "./capabilityHealth";
import { isGraphablePath, PERSON_COLLECTION_SEGMENT, type PlatformEdge, type PlatformNode } from "./platformGraph";
import { isQuarantinedVersion } from "./recipeLifecycle";
import { recipeVersion, type DomStructuralSignature, type SchoolRecipeBundle } from "./recipeStore";
import type { SchoolActionCapability, SchoolLinkRelationship, SchoolPageRole, SchoolRecipe } from "./types";

export type PlatformMapV1 = {
  schemaVersion: 1;
  /** "learnbox" — from discovery.ts, never a school origin. */
  platformId: string;
  nodes: Array<{
    routeTemplate: string;
    pageRole: SchoolPageRole;
    capability: SchoolActionCapability | null;
    successRate: number;
    observationCount: number;
  }>;
  edges: Array<{ fromTemplate: string; toTemplate: string; relationship: SchoolLinkRelationship }>;
  recipes: Array<{ recipe: SchoolRecipe; structuralSignature: DomStructuralSignature; confidence: number }>;
};

const MAX_NODES = 200;
const MAX_EDGES = 500;
const MAX_RECIPES = 50;
const SHORT = 40;

const PAGE_ROLES: readonly SchoolPageRole[] = ["collection", "detail", "messages", "grades", "attachments", "unknown"];
const RELATIONSHIPS: readonly SchoolLinkRelationship[] = ["detail", "attachment", "unknown"];
const ENTITIES = Object.keys(CAPABILITY_FOR_ENTITY) as SchoolRecipe["entity"][];
const CAPABILITIES = Object.values(CAPABILITY_FOR_ENTITY);
const SEGMENT = /^(?::id|[a-z][a-z0-9_.-]{0,40})$/i;
const PLATFORM_ID = /^[a-z0-9-]{1,40}$/;
const STRUCTURAL_WORDS = new Set([
  "ui", "data", "table", "selectable", "row", "item", "card", "list", "message", "inbox",
  "activity", "assignment", "grade", "task", "content", "container", "body", "title", "subject",
  "detail", "pagination", "paginate", "button", "dialog", "form", "select", "summary", "period",
  "status", "date", "teacher", "course", "cell", "header", "footer", "main", "modal", "panel",
  "nav", "menu", "active", "selected", "disabled", "root", "wrapper", "grid", "student", "calendar",
  "view", "input", "label", "link", "next", "previous", "prev", "page", "paging", "school", "record",
  "field", "value", "icon", "text", "actions", "action", "info", "metadata", "meta", "summary", "period",
]);
/** Standard attribute vocabulary. Attribute NAMES are shared too (presence
 *  selectors, structural signatures), so `data-juan-perez` must not pass. */
const ATTRIBUTE_WORDS = new Set([
  "id", "aria", "href", "role", "type", "name", "tab", "tabindex", "index", "hidden", "expanded", "current",
  "colspan", "rowspan", "scope", "target", "rel", "src", "alt", "for", "style", "onclick", "width", "height",
  "align", "valign", "class", "lang", "dir", "placeholder", "checked", "readonly", "required", "controls",
  "describedby", "labelledby", "live", "sort", "order", "toggle", "dismiss", "url", "key", "number", "count",
  "total", "colindex", "rowindex", "sorting", "sortable",
]);
const SAFE_ROLES = new Set([
  "alert", "article", "button", "cell", "dialog", "document", "form", "grid", "gridcell", "heading",
  "link", "list", "listbox", "listitem", "main", "menu", "menuitem", "navigation", "option", "row",
  "rowgroup", "search", "status", "table", "tab", "tabpanel", "textbox",
]);
const SAFE_TAGS = new Set([
  "unknown", "html", "body", "main", "section", "article", "div", "span", "table", "thead", "tbody",
  "tfoot", "tr", "th", "td", "ul", "ol", "li", "a", "button", "form", "input", "select", "option",
  "label", "p", "h1", "h2", "h3", "h4", "h5", "h6",
]);
const EMAIL_LIKE = /[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/i;
const UUID_LIKE = /[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/i;
const HEX_LIKE = /(?:^|[-_])[0-9a-f]{12,}(?:$|[-_])/i;
const LONG_DIGITS = /\d{5,}/;

type Json = Record<string, unknown>;

function tokenWords(value: string): string[] {
  return value
    .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
    .split(/[-_]+/)
    .map((part) => part.toLowerCase())
    .filter(Boolean);
}

function isSafeStructuralToken(value: unknown): value is string {
  if (typeof value !== "string" || value.length < 1 || value.length > SHORT) return false;
  if (!/^[A-Za-z_][A-Za-z0-9_-]*$/.test(value)) return false;
  if (EMAIL_LIKE.test(value) || UUID_LIKE.test(value) || HEX_LIKE.test(value) || LONG_DIGITS.test(value)) return false;
  const words = tokenWords(value);
  return words.length > 0 && words.every((word) => STRUCTURAL_WORDS.has(word));
}

function isSafeAttributeName(value: unknown): value is string {
  if (typeof value !== "string" || !/^[A-Za-z][A-Za-z0-9-]{0,39}$/.test(value)) return false;
  if (HEX_LIKE.test(value) || LONG_DIGITS.test(value)) return false;
  return tokenWords(value).every((word) => STRUCTURAL_WORDS.has(word) || ATTRIBUTE_WORDS.has(word));
}

function isSafeHrefSelectorValue(value: string): boolean {
  if (!value.startsWith("/") || value.includes("?") || value.includes("#")) return false;
  if (EMAIL_LIKE.test(value) || UUID_LIKE.test(value) || LONG_DIGITS.test(value)) return false;
  return value.split("/").filter(Boolean).every((segment) => /^[A-Za-z][A-Za-z0-9_.-]{0,40}$/.test(segment));
}

const SAFE_TYPES = new Set(["button", "submit", "text", "checkbox", "radio", "hidden"]);
const SAFE_PAGER_LABELS = new Set(["next", "previous", "prev", "siguiente", "anterior"]);
// One simple-selector part: #id, .class, [attr], [attr op value], or a
// positional pseudo-class. Values cannot hold quotes, brackets, backslashes or
// whitespace, so escapes and `]`-inside-quotes tricks never reach a check.
const SELECTOR_PART = /^(?:#([A-Za-z_][A-Za-z0-9_-]*)|\.([A-Za-z_][A-Za-z0-9_-]*)|\[([A-Za-z][A-Za-z0-9-]*)(?:([~|^$*]?=)(?:"([A-Za-z0-9_/.-]+)"|'([A-Za-z0-9_/.-]+)'|([A-Za-z0-9_/.-]+)))?\]|:(?:first-child|last-child|only-child|(?:nth-child|nth-of-type)\(\d{1,3}\)))/;

function isSafeAttributeValue(attribute: string, literal: string): boolean {
  switch (attribute.toLowerCase()) {
    case "href": return isSafeHrefSelectorValue(literal);
    case "role": return SAFE_ROLES.has(literal.toLowerCase());
    case "type": return SAFE_TYPES.has(literal.toLowerCase());
    case "aria-label": return SAFE_PAGER_LABELS.has(literal.toLowerCase());
    default: return false;
  }
}

function isSafeCompound(compound: string): boolean {
  const tag = /^[a-z][a-z0-9]*/i.exec(compound)?.[0] ?? "";
  if (tag && (tag.toLowerCase() === "unknown" || !SAFE_TAGS.has(tag.toLowerCase()))) return false;
  let rest = compound.slice(tag.length);
  let parts = tag ? 1 : 0;
  while (rest) {
    const match = SELECTOR_PART.exec(rest);
    if (!match) return false;
    rest = rest.slice(match[0].length);
    parts += 1;
    const [, id, className, attribute, operator, doubleQuoted, singleQuoted, bare] = match;
    if (id !== undefined && !isSafeStructuralToken(id)) return false;
    if (className !== undefined && !isSafeStructuralToken(className)) return false;
    if (attribute !== undefined) {
      if (!isSafeAttributeName(attribute)) return false;
      if (operator !== undefined && !isSafeAttributeValue(attribute, doubleQuoted ?? singleQuoted ?? bare)) return false;
    }
  }
  return parts > 0;
}

/** Privacy boundary for selector strings that may leave the Mac. An allowlist
 * grammar, not a scan for bad patterns: tags, `#`/`.` structural tokens,
 * attribute presence with structural names, a few valued attributes
 * (href path, role, type, pager aria-label), positional pseudo-classes, and
 * descendant/child combinators. Commas, escapes, :has/:not, sibling
 * combinators and every other literal are refused. */
export function isPrivacySafeSelector(value: unknown): value is string {
  if (typeof value !== "string" || value.length < 1 || value.length > 300) return false;
  if (EMAIL_LIKE.test(value) || UUID_LIKE.test(value) || LONG_DIGITS.test(value)) return false;
  return value.trim().split(/\s*>\s*|\s+/).every(isSafeCompound);
}

function hasExactKeys(value: unknown, required: string[], optional: string[] = []): value is Json {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const keys = Object.keys(value);
  return required.every((key) => keys.includes(key)) && keys.every((key) => required.includes(key) || optional.includes(key));
}

const isShortString = (value: unknown, max: number): value is string => typeof value === "string" && value.length <= max;
const isRate = (value: unknown): value is number => typeof value === "number" && value >= 0 && value <= 1;

function stringList(value: unknown): string[] | null {
  if (!Array.isArray(value) || value.length > SHORT) return null;
  return value.every((item) => isShortString(item, SHORT)) ? [...value] : null;
}

/** A route another school on the same platform can have too: plain page names
 *  and :id, nothing that looks like a school, a person, or a file. */
export function isShareableTemplate(value: unknown): value is string {
  if (typeof value !== "string" || !value.startsWith("/") || value.length > 300 || !isGraphablePath(value)) return false;
  const segments = value.split("/").filter(Boolean);
  if (!segments.every((segment) => SEGMENT.test(segment))) return false;
  // Backstop for nodes recorded before routeTemplate() learned to template
  // person segments: a name straight after "students"/"alumnos"/etc. is
  // still a specific person even though it looks like a plain word.
  return segments.every((segment, index) => {
    const previous = segments[index - 1]?.toLowerCase();
    return !previous || !PERSON_COLLECTION_SEGMENT.has(previous) || segment === ":id";
  });
}

function parseSignature(value: unknown): DomStructuralSignature | null {
  if (!hasExactKeys(value, ["tag", "classTokens", "attributeNames", "childTags"], ["role"])) return null;
  const classTokens = stringList(value.classTokens);
  const attributeNames = stringList(value.attributeNames);
  const childTags = stringList(value.childTags);
  if (!isShortString(value.tag, SHORT) || !classTokens || !attributeNames || !childTags) return null;
  if (!SAFE_TAGS.has(value.tag.toLowerCase())) return null;
  if (!classTokens.every(isSafeStructuralToken)) return null;
  if (!attributeNames.every(isSafeAttributeName)) return null;
  if (!childTags.every((item) => SAFE_TAGS.has(item.toLowerCase()))) return null;
  if (value.role !== undefined && (!isShortString(value.role, SHORT) || !SAFE_ROLES.has(value.role.toLowerCase()))) return null;
  return { tag: value.tag, classTokens, attributeNames, ...(value.role !== undefined ? { role: value.role as string } : {}), childTags };
}

function sanitizeSignatureForShare(signature: DomStructuralSignature): DomStructuralSignature | null {
  const tag = SAFE_TAGS.has(signature.tag.toLowerCase()) ? signature.tag.slice(0, SHORT) : "unknown";
  const classTokens = signature.classTokens.filter(isSafeStructuralToken).slice(0, SHORT);
  // Dropped, never truncated: a cut-off personal name is still personal.
  const attributeNames = signature.attributeNames.filter(isSafeAttributeName).slice(0, SHORT);
  const childTags = signature.childTags
    .filter((item) => SAFE_TAGS.has(item.toLowerCase()))
    .slice(0, SHORT)
    .map((item) => item.slice(0, SHORT));
  const role = signature.role && SAFE_ROLES.has(signature.role.toLowerCase()) ? signature.role.slice(0, SHORT) : undefined;
  return parseSignature({ tag, classTokens, attributeNames, childTags, ...(role ? { role } : {}) });
}

function parseRecipe(value: unknown): SchoolRecipe | null {
  if (!hasExactKeys(value, ["schemaVersion", "entity", "source", "fields"], ["collectionPath"])) return null;
  if (value.schemaVersion !== 1 || !ENTITIES.includes(value.entity as SchoolRecipe["entity"])) return null;
  const source = value.source;
  if (!hasExactKeys(source, ["kind"], ["endpointTemplate", "container", "selector"])) return null;
  if (source.kind === "observed-dom") {
    if (!isShareableTemplate(source.container) || !isPrivacySafeSelector(source.selector) || source.endpointTemplate !== undefined) return null;
  } else if (source.kind === "observed-json") {
    if (!isShareableTemplate(source.endpointTemplate) || source.container !== undefined || source.selector !== undefined) return null;
  } else {
    return null;
  }
  if (value.collectionPath !== undefined && !isShareableTemplate(value.collectionPath)) return null;
  const fields = value.fields;
  if (!fields || typeof fields !== "object" || Array.isArray(fields)) return null;
  const fieldEntries = Object.entries(fields);
  if (fieldEntries.length > 30 || !fieldEntries.every(([key, selector]) => isShortString(key, SHORT) && isPrivacySafeSelector(selector))) {
    return null;
  }
  return {
    schemaVersion: 1,
    entity: value.entity as SchoolRecipe["entity"],
    source: source.kind === "observed-dom"
      ? { kind: "observed-dom", container: source.container as string, selector: source.selector as string }
      : { kind: "observed-json", endpointTemplate: source.endpointTemplate as string },
    ...(value.collectionPath !== undefined ? { collectionPath: value.collectionPath as string } : {}),
    fields: Object.fromEntries(fieldEntries) as Record<string, string>,
  };
}

export function exportPlatformMap(
  platformId: string,
  nodes: PlatformNode[],
  edges: PlatformEdge[],
  bundle: SchoolRecipeBundle,
): PlatformMapV1 {
  return {
    schemaVersion: 1,
    platformId,
    nodes: nodes
      .filter((node) => isShareableTemplate(node.routeTemplate) && node.observationCount > 0)
      .sort((left, right) => right.observationCount - left.observationCount)
      .slice(0, MAX_NODES)
      .map((node) => ({
        routeTemplate: node.routeTemplate,
        pageRole: node.pageRole,
        capability: node.capability,
        successRate: node.successCount / node.observationCount,
        observationCount: node.observationCount,
      })),
    edges: edges
      .filter((edge) => isShareableTemplate(edge.fromTemplate) && isShareableTemplate(edge.toTemplate))
      .slice(0, MAX_EDGES)
      .map((edge) => ({ fromTemplate: edge.fromTemplate, toTemplate: edge.toTemplate, relationship: edge.relationship })),
    recipes: bundle.recipes.flatMap((stored) => {
      const recipe = parseRecipe(stored.recipe);
      const structuralSignature = sanitizeSignatureForShare(stored.structuralSignature);
      return recipe && structuralSignature
        ? [{ recipe, structuralSignature, confidence: Math.max(0, Math.min(1, stored.confidence)) }]
        : [];
    }).slice(0, MAX_RECIPES),
  };
}

/** Strict: one bad element rejects the whole map rather than serving a
 *  partially-trusted one. */
export function parsePlatformMap(raw: unknown): PlatformMapV1 | null {
  if (!hasExactKeys(raw, ["schemaVersion", "platformId", "nodes", "edges", "recipes"])) return null;
  if (raw.schemaVersion !== 1 || typeof raw.platformId !== "string" || !PLATFORM_ID.test(raw.platformId)) return null;
  const { nodes, edges, recipes } = raw;
  if (!Array.isArray(nodes) || nodes.length > MAX_NODES) return null;
  if (!Array.isArray(edges) || edges.length > MAX_EDGES) return null;
  if (!Array.isArray(recipes) || recipes.length > MAX_RECIPES) return null;

  const map: PlatformMapV1 = { schemaVersion: 1, platformId: raw.platformId, nodes: [], edges: [], recipes: [] };
  for (const node of nodes) {
    if (!hasExactKeys(node, ["routeTemplate", "pageRole", "capability", "successRate", "observationCount"])) return null;
    if (!isShareableTemplate(node.routeTemplate) || !PAGE_ROLES.includes(node.pageRole as SchoolPageRole)) return null;
    if (node.capability !== null && !CAPABILITIES.includes(node.capability as SchoolActionCapability)) return null;
    if (!isRate(node.successRate) || !Number.isInteger(node.observationCount) || (node.observationCount as number) < 0) return null;
    map.nodes.push({
      routeTemplate: node.routeTemplate,
      pageRole: node.pageRole as SchoolPageRole,
      capability: node.capability as SchoolActionCapability | null,
      successRate: node.successRate,
      observationCount: node.observationCount as number,
    });
  }
  for (const edge of edges) {
    if (!hasExactKeys(edge, ["fromTemplate", "toTemplate", "relationship"])) return null;
    if (!isShareableTemplate(edge.fromTemplate) || !isShareableTemplate(edge.toTemplate)) return null;
    if (!RELATIONSHIPS.includes(edge.relationship as SchoolLinkRelationship)) return null;
    map.edges.push({ fromTemplate: edge.fromTemplate, toTemplate: edge.toTemplate, relationship: edge.relationship as SchoolLinkRelationship });
  }
  for (const entry of recipes) {
    if (!hasExactKeys(entry, ["recipe", "structuralSignature", "confidence"])) return null;
    const recipe = parseRecipe(entry.recipe);
    const structuralSignature = parseSignature(entry.structuralSignature);
    if (!recipe || !structuralSignature || !isRate(entry.confidence)) return null;
    map.recipes.push({ recipe, structuralSignature, confidence: entry.confidence });
  }
  return map;
}

/** Changes only when the map's structure does, not every time a success rate
 *  moves, so the daemon proposes on new knowledge rather than on every poll. */
export function platformMapFingerprint(map: PlatformMapV1): string {
  return createHash("sha256").update(JSON.stringify({
    nodes: map.nodes.map((node) => [node.routeTemplate, node.pageRole, node.capability]),
    edges: map.edges.map((edge) => [edge.fromTemplate, edge.toTemplate, edge.relationship]),
    recipes: map.recipes.map((entry) => recipeVersion(entry.recipe)),
  })).digest("hex").slice(0, 16);
}

/**
 * Offers each shared DOM recipe to the local recipe for the same entity and
 * page as a pending repair with zero observations, so the unchanged
 * stageRepairCandidate rules need two independent local sightings before it
 * can replace anything.
 *
 * ponytail: a shared recipe with no local counterpart is skipped, because
 * adding it as a new recipe would make it active immediately. Add a separate
 * candidate list to the bundle when a platform without a bundled adapter
 * needs to start from the shared map.
 */
export function stageDownloadedMap(
  bundle: SchoolRecipeBundle,
  map: PlatformMapV1,
  observedAt: string,
): { bundle: SchoolRecipeBundle; staged: number } {
  let staged = 0;
  const recipes = bundle.recipes.map((stored) => {
    if (stored.pendingRepair) return stored;
    const shared = map.recipes.find((entry) =>
      entry.recipe.source.kind === "observed-dom"
      && entry.recipe.entity === stored.recipe.entity
      && entry.recipe.source.container === stored.recipe.source.container
      && recipeVersion(entry.recipe) !== stored.version
    );
    if (!shared) return stored;
    const version = recipeVersion(shared.recipe);
    if (isQuarantinedVersion(stored, version)) return stored;
    staged += 1;
    return {
      ...stored,
      pendingRepair: {
        recipe: shared.recipe,
        version,
        confidence: shared.confidence,
        structuralSignature: shared.structuralSignature,
        firstObservedAt: observedAt,
        lastObservedAt: observedAt,
        observations: 0,
      },
    };
  });
  return { bundle: staged > 0 ? { ...bundle, recipes, updatedAt: observedAt } : bundle, staged };
}

/** The only thing a failure report may say about the page: the shape of the
 *  container that stopped matching, every string cut to 40 characters. */
export function sanitizeFailureExcerpt(signature: DomStructuralSignature): string {
  const sanitized = sanitizeSignatureForShare(signature) ?? {
    tag: "unknown",
    classTokens: [],
    attributeNames: [],
    childTags: [],
  };
  return JSON.stringify(sanitized);
}

/** Server side of the same contract: anything but a bare signature is refused. */
export function parseFailureExcerpt(raw: unknown): string | null {
  if (typeof raw !== "string" || raw.length > 4_000) return null;
  try {
    const signature = parseSignature(JSON.parse(raw));
    return signature ? JSON.stringify(signature) : null;
  } catch {
    return null;
  }
}
