// lib/school/emptyState.ts
// Why a page showed nothing.
//
// "Zero assignments" and "we could not read the assignments" look identical in
// the extracted records, and telling a student they have nothing due when they
// do is the worst thing this connector can do. So a zero-record observation is
// only accepted as real when the page positively says so — an empty-state
// marker on a page we can tell is the right one.
//
// Login and CAPTCHA are handled earlier, by detectPassiveBarrier in evidence.ts;
// this is about pages we did reach.

import type { DomSnapshotObservation } from "./evidence";
import type { SchoolPageRole, SchoolRecipe } from "./types";

export type EmptyObservation =
  /** The page says it is empty, and it is the page we wanted. Trust it. */
  | { state: "valid_empty"; marker: string }
  /** Skeletons/spinners: the page had not finished rendering when captured. */
  | { state: "loading" }
  /** A real page, but not the capability we were reading. Says nothing about it. */
  | { state: "wrong_page" }
  /** Nothing was extracted and nothing explains why. Never "nothing due". */
  | { state: "unproven" };

// Deliberately phrase-level, not word-level: "no" or "empty" alone appear all
// over an LMS. Spanish included — iBacalao's students are largely bilingual.
const EMPTY_MARKERS: RegExp[] = [
  /\bno (?:upcoming |current |new |unread )?(?:assignments?|tasks?|homework|deadlines?|messages?|announcements?|grades?|results?|submissions?)\b/i,
  /\b(?:you(?:'re| are) all caught up|all caught up|nothing (?:due|to do|here)|no items? to show|nothing to show|no results? found)\b/i,
  /\b(?:sin|no hay) (?:tareas|mensajes|anuncios|notas|calificaciones|entregas|actividades|resultados)\b/i,
  /\b(?:no tienes|no hay) (?:nada|ninguna tarea|ningún mensaje)\b/i,
  /\bno existen archivos adjuntos\b/i,
  /\bempty\b.{0,20}\b(?:list|inbox|state)\b/i,
];

/** Phrase-level empty marker, for active crawls that only have page text. */
export function matchEmptyMarker(text: string): string | undefined {
  for (const pattern of EMPTY_MARKERS) {
    const match = pattern.exec(text);
    if (match) return match[0].slice(0, 80);
  }
  return undefined;
}

const LOADING_MARKERS: RegExp[] = [
  /\b(?:loading|cargando|please wait|un momento)\b/i,
  /\bskeleton\b/i,
];

/** Which page roles can legitimately answer for which recipe entity. */
const ROLE_FOR_ENTITY: Record<SchoolRecipe["entity"], SchoolPageRole[]> = {
  assignment: ["collection", "detail", "unknown"],
  message: ["messages", "collection", "detail", "unknown"],
  grade: ["grades", "collection", "detail", "unknown"],
  submission: ["collection", "detail", "grades", "unknown"],
  deadline: ["collection", "detail", "unknown"],
};

function visibleText(snapshot: DomSnapshotObservation): string {
  const payload = snapshot.payload;
  const rowText = payload.rows.flatMap((row) =>
    Object.values(row).filter((value): value is string => typeof value === "string"),
  );
  const cardText = (payload.cards ?? []).flatMap((card) => [card.text, card.title]
    .filter((value): value is string => typeof value === "string"));
  return [...rowText, ...cardText].join(" ");
}

function looksLikeSkeleton(snapshot: DomSnapshotObservation): boolean {
  const html = snapshot.payload.sanitizedHtml ?? "";
  return /\b(?:skeleton|shimmer|placeholder|aria-busy="true")\b/i.test(html);
}

/**
 * Explains a zero-record observation for one capability.
 *
 * Only `valid_empty` may be treated as a healthy, complete answer. Everything
 * else means we still do not know what the student has, and the capability must
 * not be reported as up to date.
 */
export function classifyEmptyObservation(
  snapshot: DomSnapshotObservation,
  entity: SchoolRecipe["entity"],
): EmptyObservation {
  const text = visibleText(snapshot);

  if (LOADING_MARKERS.some((pattern) => pattern.test(text)) || looksLikeSkeleton(snapshot)) {
    return { state: "loading" };
  }

  const role = snapshot.payload.pageRole ?? "unknown";
  if (!ROLE_FOR_ENTITY[entity].includes(role)) return { state: "wrong_page" };

  const marker = matchEmptyMarker(text);
  if (marker) return { state: "valid_empty", marker };

  return { state: "unproven" };
}

/** A repair must never be learned from a page that cannot answer for itself. */
export function blocksRepairEvidence(observation: EmptyObservation): boolean {
  return observation.state !== "unproven";
}
