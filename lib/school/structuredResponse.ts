// lib/school/structuredResponse.ts
// Structured school JSON the authenticated browser already loaded.
//
// The extension never forwards JSON scalar values off the page — only a
// schema shape. This module does two jobs with that contract:
//   1. Hypothesize which same-origin endpoints carry assignments/messages/grades
//      so the platform graph can prefer them over DOM scraping later.
//   2. Turn sanitized academic JSON *fixtures* (shadow tests, never live
//      unsanitized bodies) into the same ScrapedRecord contract as DOM cards.

import { createHash } from "node:crypto";
import type { ScrapedRecord } from "../watcher/types";
import { isNonAcademicTitle } from "./tableParse";
import type { SchoolActionCapability } from "./types";

export type StructuredEndpointHypothesis = {
  endpointTemplate: string;
  capability: SchoolActionCapability;
  confidence: number;
  reason: string;
};

const ASSIGNMENT_KEY = /\b(assignment|actividad|tarea|homework|task|due_?date|fecha_?entrega|dueat)\b/i;
const MESSAGE_KEY = /\b(message|mensaje|inbox|announcement|thread|asunto)\b/i;
const GRADE_KEY = /\b(grade|nota|score|mark|calificaci)\b/i;
const TITLE_KEY = /^(?:title|name|nombre|actividad|assignment|subject|asunto|descripci[oó]n)$/i;
const ID_KEY = /^(?:id|assignment_?id|task_?id|message_?id|activity_?id|source_?record_?id)$/i;
const DUE_KEY = /^(?:due_?at|due_?date|deadline|fecha_?entrega|vencimiento)$/i;
const SUBJECT_KEY = /^(?:subject|course|materia|asignatura|class)$/i;
const STATUS_KEY = /^(?:status|estado|state)$/i;
const GRADE_FIELD = /^(?:grade|nota|score|mark)$/i;
const TEACHER_KEY = /^(?:teacher|profesor[ae]?|sender|from|de|docente)$/i;
const THREAD_KEY = /^(?:thread_?id|conversation_?id|parent_?id)$/i;

function collectKeys(schema: unknown, into: Set<string>, depth = 0): void {
  if (depth > 8 || !schema || typeof schema !== "object") return;
  const node = schema as { type?: string; fields?: Record<string, unknown>; sampleShapes?: unknown[] };
  if (node.fields) {
    for (const [key, child] of Object.entries(node.fields)) {
      into.add(key);
      collectKeys(child, into, depth + 1);
    }
  }
  for (const sample of node.sampleShapes ?? []) collectKeys(sample, into, depth + 1);
}

function endpointHint(endpointTemplate: string): string {
  return endpointTemplate.replace(/:id/g, "");
}

export function hypothesizeStructuredEndpoint(
  endpointTemplate: string,
  schema: unknown,
): StructuredEndpointHypothesis | null {
  if (!endpointTemplate.startsWith("/")) return null;
  const keys = new Set<string>();
  collectKeys(schema, keys);
  const keyHaystack = Array.from(keys).join(" ");
  const path = endpointHint(endpointTemplate);

  const score = (capability: SchoolActionCapability, pattern: RegExp): number => {
    let n = 0;
    if (pattern.test(path)) n += 0.45;
    if (pattern.test(keyHaystack)) n += 0.5;
    return n;
  };

  // Annotated on this literal, not on `ranked` below: the type doesn't flow
  // backward through .filter().sort(), so `capability` would otherwise widen
  // to `string` and fail StructuredEndpointHypothesis's literal union.
  const candidates: StructuredEndpointHypothesis[] = [
    { endpointTemplate, capability: "assignments", confidence: score("assignments", ASSIGNMENT_KEY), reason: "assignment-shaped json" },
    { endpointTemplate, capability: "messages", confidence: score("messages", MESSAGE_KEY), reason: "message-shaped json" },
    { endpointTemplate, capability: "grades", confidence: score("grades", GRADE_KEY), reason: "grade-shaped json" },
  ];
  const ranked = candidates
    .filter((item) => item.confidence >= 0.45)
    .sort((a, b) => b.confidence - a.confidence);

  return ranked[0] ?? null;
}

function stringField(row: Record<string, unknown>, matcher: RegExp, max: number): string | undefined {
  for (const [key, value] of Object.entries(row)) {
    if (!matcher.test(key) || typeof value !== "string") continue;
    const trimmed = value.replace(/\s+/g, " ").trim().slice(0, max);
    if (trimmed) return trimmed;
  }
  return undefined;
}

function kindForHypothesis(capability: SchoolActionCapability): ScrapedRecord["kind"] {
  if (capability === "messages") return "message";
  if (capability === "grades") return "grade";
  if (capability === "submissions") return "submission";
  if (capability === "deadlines") return "deadline";
  return "assignment";
}

function academicRows(value: unknown, depth = 0): Record<string, unknown>[] {
  if (depth > 6 || value == null) return [];
  if (Array.isArray(value)) {
    return value.flatMap((entry) => academicRows(entry, depth + 1));
  }
  if (typeof value !== "object") return [];
  const row = value as Record<string, unknown>;
  const hasTitle = Object.keys(row).some((key) => TITLE_KEY.test(key) && typeof row[key] === "string");
  if (hasTitle) return [row];
  return Object.values(row).flatMap((child) => academicRows(child, depth + 1));
}

/**
 * Fixture-only: parse sanitized academic JSON into records. Live network
 * bodies never take this path; the page-hook discards scalars first.
 */
export function recordsFromAcademicJson(
  json: unknown,
  origin: string,
  endpointTemplate: string,
): ScrapedRecord[] {
  const hypothesis = hypothesizeStructuredEndpoint(endpointTemplate, {
    type: "object",
    fields: json && typeof json === "object" && !Array.isArray(json)
      ? Object.fromEntries(Object.keys(json as object).map((key) => [key, "string"]))
      : {},
  }) ?? { endpointTemplate, capability: "assignments" as const, confidence: 0.5, reason: "fixture" };

  const kind = kindForHypothesis(hypothesis.capability);
  const records: ScrapedRecord[] = [];
  for (const row of academicRows(json)) {
    const title = stringField(row, TITLE_KEY, 300);
    if (!title || isNonAcademicTitle(title)) continue;
    const id = stringField(row, ID_KEY, 160)
      ?? createHash("sha256").update([kind, endpointTemplate, title].join("\0")).digest("hex").slice(0, 32);
    const dueAt = stringField(row, DUE_KEY, 80);
    const grade = stringField(row, GRADE_FIELD, 120);
    if (kind === "grade" && !grade) continue;
    const record: ScrapedRecord = {
      sourceRecordId: id,
      kind,
      title,
      ...(stringField(row, SUBJECT_KEY, 180) ? { subject: stringField(row, SUBJECT_KEY, 180) } : {}),
      ...(dueAt ? { dueAt } : {}),
      ...(stringField(row, STATUS_KEY, 160) ? { status: stringField(row, STATUS_KEY, 160) } : {}),
      ...(grade ? { grade } : {}),
      ...(stringField(row, TEACHER_KEY, 180) ? { teacher: stringField(row, TEACHER_KEY, 180) } : {}),
      ...(stringField(row, THREAD_KEY, 160) ? { threadId: stringField(row, THREAD_KEY, 160) } : {}),
      url: `${origin}${endpointTemplate.replace(/:id/g, id)}`,
    };
    records.push(record);
  }
  return records.slice(0, 40);
}
