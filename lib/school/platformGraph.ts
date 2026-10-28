// lib/school/platformGraph.ts
// What iBacalao has learned about the shape of one school's portal.
//
// Recipes know how to read a page. Nothing until now knew that /assignments is
// where assignments live, that /assignments/12345 is one of them, or that the
// link from a message to a PDF is how attachments are reached. That knowledge
// was rediscovered from scratch on every visit and thrown away every time.
//
// The graph is evidence, not behavior: browsing refines confidence here
// continuously, but changing how a page is actually read still has to go
// through the candidate/shadow/promote path in recipeLifecycle.ts.

import type { DatabaseSync } from "node:sqlite";
import type { NavigationEdgeObservation } from "./evidence";
import type { SchoolLinkRelationship, SchoolPageRole } from "./types";
import type { SchoolActionCapability } from "./types";

export type PlatformNode = {
  nodeId: string;
  sourceKey: string;
  routeTemplate: string;
  pageRole: SchoolPageRole;
  capability: SchoolActionCapability | null;
  activeRecipeId: string | null;
  candidateRecipeId: string | null;
  observationCount: number;
  successCount: number;
  failureCount: number;
  stableIdRatio: number;
  fieldCompleteness: number;
  lastObservedAt: string | null;
  lastSuccessAt: string | null;
  lastFailureAt: string | null;
};

export type PlatformEdge = {
  fromTemplate: string;
  toTemplate: string;
  relationship: SchoolLinkRelationship;
  observationCount: number;
  lastObservedAt: string | null;
};

export type PlatformNodeObservation = {
  path: string;
  pageRole: SchoolPageRole;
  capability?: SchoolActionCapability | null;
  activeRecipeId?: string | null;
  candidateRecipeId?: string | null;
  observedAt: string;
  /** Did reading this page produce records this time? */
  succeeded: boolean;
  stableIdRatio?: number;
  fieldCompleteness?: number;
};

/** Path segments that are clearly an identifier rather than a page name. */
// Long opaque tokens must contain a digit: Learnbox page names like
// fStudentCalendarActivity are 20+ letters and are pages, not ids.
const ID_SEGMENT = /^(?:\d{2,}|[0-9a-f]{8}-[0-9a-f-]{27,}|(?=[A-Za-z_-]*\d)[A-Za-z0-9_-]{20,})$/i;

/** A segment right after one of these is a specific person, never a page name
 *  — "juanperez" and "maria-gomez" have no digit, so ID_SEGMENT alone misses
 *  them. English + Spanish since Learnbox schools are LatAm. */
export const PERSON_COLLECTION_SEGMENT = new Set([
  "student", "students", "estudiante", "estudiantes", "alumno", "alumnos",
  "teacher", "teachers", "profesor", "profesores", "docente", "docentes",
  "parent", "parents", "padre", "padres",
  "user", "users", "usuario", "usuarios",
  "member", "members", "miembro", "miembros",
  "profile", "profiles", "perfil", "perfiles",
  "staff", "person", "people", "personas",
]);

/**
 * Generalizes one visited path into the route it is an instance of.
 *
 * `/assignments/12345` and `/assignments/67890` are the same kind of page, and
 * the graph is only useful if it knows that. Without this, every assignment the
 * student ever opened would be its own node.
 */
export function routeTemplate(path: string): string {
  const [pathname] = path.split(/[?#]/);
  const raw = pathname.split("/").filter(Boolean);
  const segments = raw.map((segment, index) => {
    if (ID_SEGMENT.test(segment)) return ":id";
    const previous = raw[index - 1]?.toLowerCase();
    if (previous && PERSON_COLLECTION_SEGMENT.has(previous)) return ":id";
    return segment;
  });
  return `/${segments.join("/")}`;
}

const MIGRATION = `
  CREATE TABLE IF NOT EXISTS platform_nodes (
    node_id             TEXT PRIMARY KEY,
    source_key          TEXT NOT NULL,
    route_template      TEXT NOT NULL,
    page_role           TEXT NOT NULL,
    capability          TEXT,
    active_recipe_id    TEXT,
    candidate_recipe_id TEXT,
    observation_count   INTEGER NOT NULL DEFAULT 0,
    success_count       INTEGER NOT NULL DEFAULT 0,
    failure_count       INTEGER NOT NULL DEFAULT 0,
    stable_id_ratio     REAL NOT NULL DEFAULT 0,
    field_completeness  REAL NOT NULL DEFAULT 0,
    last_observed_at    TEXT,
    last_success_at     TEXT,
    last_failure_at     TEXT
  );
  CREATE INDEX IF NOT EXISTS platform_nodes_source ON platform_nodes (source_key);
  CREATE TABLE IF NOT EXISTS platform_edges (
    source_key        TEXT NOT NULL,
    from_template     TEXT NOT NULL,
    to_template       TEXT NOT NULL,
    relationship      TEXT NOT NULL,
    observation_count INTEGER NOT NULL DEFAULT 0,
    last_observed_at  TEXT,
    PRIMARY KEY (source_key, from_template, to_template, relationship)
  );
`;

export function ensurePlatformGraphSchema(db: DatabaseSync): void {
  db.exec(MIGRATION);
}

const nodeId = (sourceKey: string, template: string, role: SchoolPageRole) => `${sourceKey}|${template}|${role}`;

const NON_PAGE_EXTENSION = /\.(?:rpc|json|xml|js|css|png|svg)$/i;
const NON_PAGE_ROOT = new Set(["rpc", "api", "static", "assets"]);

/** Polling RPCs and assets are not places a student reads school work. On
 *  Learnbox, checkUserMessages.rpc was the graph's only node, seen thousands
 *  of times, which made the graph look confident about nothing. */
export function isGraphablePath(path: string): boolean {
  const segments = path.split(/[?#]/)[0].split("/").filter(Boolean);
  if (segments.length === 0) return true;
  if (NON_PAGE_ROOT.has(segments[0].toLowerCase())) return false;
  return !NON_PAGE_EXTENSION.test(segments[segments.length - 1]);
}

/**
 * Folds one page view into the node's running evidence.
 *
 * Rates are kept as running averages rather than a stored history: the graph
 * answers "is this page usually readable", and a full observation log belongs
 * in the capture journal, which already has one.
 */
export function recordPlatformNode(db: DatabaseSync, sourceKey: string, observation: PlatformNodeObservation): void {
  if (!isGraphablePath(observation.path)) return;
  const template = routeTemplate(observation.path);
  const id = nodeId(sourceKey, template, observation.pageRole);
  const existing = db.prepare("SELECT * FROM platform_nodes WHERE node_id = ?").get(id) as
    | { observation_count: number; success_count: number; failure_count: number; stable_id_ratio: number; field_completeness: number }
    | undefined;

  const observationCount = (existing?.observation_count ?? 0) + 1;
  const successCount = (existing?.success_count ?? 0) + (observation.succeeded ? 1 : 0);
  const failureCount = (existing?.failure_count ?? 0) + (observation.succeeded ? 0 : 1);
  const blend = (previous: number, next: number | undefined) =>
    next === undefined ? previous : (previous * (observationCount - 1) + next) / observationCount;

  db.prepare(
    `INSERT INTO platform_nodes (
       node_id, source_key, route_template, page_role, capability, active_recipe_id, candidate_recipe_id,
       observation_count, success_count, failure_count, stable_id_ratio, field_completeness,
       last_observed_at, last_success_at, last_failure_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (node_id) DO UPDATE SET
       capability = COALESCE(excluded.capability, platform_nodes.capability),
       active_recipe_id = COALESCE(excluded.active_recipe_id, platform_nodes.active_recipe_id),
       candidate_recipe_id = excluded.candidate_recipe_id,
       observation_count = excluded.observation_count,
       success_count = excluded.success_count,
       failure_count = excluded.failure_count,
       stable_id_ratio = excluded.stable_id_ratio,
       field_completeness = excluded.field_completeness,
       last_observed_at = excluded.last_observed_at,
       last_success_at = COALESCE(excluded.last_success_at, platform_nodes.last_success_at),
       last_failure_at = COALESCE(excluded.last_failure_at, platform_nodes.last_failure_at)`,
  ).run(
    id,
    sourceKey,
    template,
    observation.pageRole,
    observation.capability ?? null,
    observation.activeRecipeId ?? null,
    observation.candidateRecipeId ?? null,
    observationCount,
    successCount,
    failureCount,
    blend(existing?.stable_id_ratio ?? 0, observation.stableIdRatio),
    blend(existing?.field_completeness ?? 0, observation.fieldCompleteness),
    observation.observedAt,
    observation.succeeded ? observation.observedAt : null,
    observation.succeeded ? null : observation.observedAt,
  );
}

/** A link the student actually followed: the only evidence of page structure
 *  we trust, since it came from real navigation rather than guessing. */
export function recordPlatformEdges(
  db: DatabaseSync,
  sourceKey: string,
  edges: NavigationEdgeObservation[],
): void {
  const statement = db.prepare(
    `INSERT INTO platform_edges (source_key, from_template, to_template, relationship, observation_count, last_observed_at)
     VALUES (?, ?, ?, ?, 1, ?)
     ON CONFLICT (source_key, from_template, to_template, relationship) DO UPDATE SET
       observation_count = platform_edges.observation_count + 1,
       last_observed_at = excluded.last_observed_at`,
  );
  for (const edge of edges) {
    statement.run(
      sourceKey,
      routeTemplate(edge.payload.fromPath),
      routeTemplate(edge.payload.toPath),
      edge.payload.relationship,
      edge.observedAt,
    );
  }
}

export function readPlatformNodes(db: DatabaseSync, sourceKey: string): PlatformNode[] {
  return (db.prepare(
    "SELECT * FROM platform_nodes WHERE source_key = ? ORDER BY route_template ASC, page_role ASC",
  ).all(sourceKey) as Array<Record<string, unknown>>).map((row) => ({
    nodeId: String(row.node_id),
    sourceKey: String(row.source_key),
    routeTemplate: String(row.route_template),
    pageRole: row.page_role as SchoolPageRole,
    capability: (row.capability as SchoolActionCapability | null) ?? null,
    activeRecipeId: (row.active_recipe_id as string | null) ?? null,
    candidateRecipeId: (row.candidate_recipe_id as string | null) ?? null,
    observationCount: Number(row.observation_count),
    successCount: Number(row.success_count),
    failureCount: Number(row.failure_count),
    stableIdRatio: Number(row.stable_id_ratio),
    fieldCompleteness: Number(row.field_completeness),
    lastObservedAt: (row.last_observed_at as string | null) ?? null,
    lastSuccessAt: (row.last_success_at as string | null) ?? null,
    lastFailureAt: (row.last_failure_at as string | null) ?? null,
  }));
}

export function readPlatformEdges(db: DatabaseSync, sourceKey: string): PlatformEdge[] {
  return (db.prepare(
    "SELECT * FROM platform_edges WHERE source_key = ? ORDER BY from_template ASC, to_template ASC",
  ).all(sourceKey) as Array<Record<string, unknown>>).map((row) => ({
    fromTemplate: String(row.from_template),
    toTemplate: String(row.to_template),
    relationship: row.relationship as SchoolLinkRelationship,
    observationCount: Number(row.observation_count),
    lastObservedAt: (row.last_observed_at as string | null) ?? null,
  }));
}

/** Where a capability is known to live, best-established first. Later phases
 *  use this to know which page to ask the student for when automation fails. */
export function bestNodeForCapability(
  nodes: PlatformNode[],
  capability: SchoolActionCapability,
): PlatformNode | null {
  const candidates = nodes
    .filter((node) => node.capability === capability && node.successCount > 0)
    .sort((left, right) => {
      const leftRate = left.successCount / Math.max(left.observationCount, 1);
      const rightRate = right.successCount / Math.max(right.observationCount, 1);
      if (leftRate !== rightRate) return rightRate - leftRate;
      return right.successCount - left.successCount;
    });
  return candidates[0] ?? null;
}
