// lib/school/completeness.ts
// Finding records is not the same as having the whole list.
//
// A first page of assignments can look healthy while twenty more sit behind
// "Next" or infinite scroll. Treating that page as complete would drop work
// the student actually has. Only a page that shows no further pages, or
// positively says it is empty, may be called complete.

import type { EmptyObservation } from "./emptyState";
import type { DomSnapshotObservation } from "./evidence";

export type CollectionCompleteness =
  | { state: "complete"; reason: "explicit_empty" | "single_page" | "last_page" }
  | { state: "partial"; reason: "has_next" | "infinite_scroll" | "truncated" }
  | { state: "unknown" };

/** Matches the card cap in evidence.ts / the extension. Hitting it means we
 *  stopped reading, not that the school stopped listing. */
export const COLLECTION_CARD_CAP = 40;

const PAGE_OF = /\bp(?:age|[aá]gina)\s+(\d+)\s+(?:of|de)\s+(\d+)/i;

const HAS_NEXT = [
  /\bnext\s+page\b/i,
  /\bpage\s+\d+\s+of\s+\d+/i,
  /\bp[aá]gina\s+\d+\s+de\s+\d+/i,
  /\bsiguiente\s+p[aá]gina\b/i,
  /\bp[aá]gina\s+siguiente\b/i,
  /\bshow more\b/i,
  /\bver m[aá]s\b/i,
  /\bload more\b/i,
  /\bcargar m[aá]s\b/i,
];

const LAST_PAGE = [
  /\blast page\b/i,
  /\búltima página\b/i,
  /\bno more (?:results|items|assignments|messages)\b/i,
];

const INFINITE_SCROLL = [
  /\binfinite[- ]scroll\b/i,
  /\bdata-infinite\b/i,
  /\bload-on-scroll\b/i,
];

const RANGE = /\b(?:showing|mostrando)\s+(\d+)\s*(?:-|–|to|a)\s*(\d+)\s+(?:of|de)\s+(\d+)/i;

function haystack(snapshot: DomSnapshotObservation): string {
  const payload = snapshot.payload;
  const rowText = payload.rows.flatMap((row) =>
    Object.values(row).filter((value): value is string => typeof value === "string"),
  );
  const cardText = (payload.cards ?? []).flatMap((card) => [card.text, card.title]
    .filter((value): value is string => typeof value === "string"));
  return [...rowText, ...cardText, payload.sanitizedHtml ?? ""].join(" ");
}

/**
 * Did this observation capture the whole collection, or only what happened
 * to be on screen?
 */
export function classifyCollectionCompleteness(
  snapshot: DomSnapshotObservation,
  options: { recordCount: number; empty?: EmptyObservation; cardCap?: number } = { recordCount: 0 },
): CollectionCompleteness {
  if (options.empty?.state === "valid_empty") {
    return { state: "complete", reason: "explicit_empty" };
  }

  const text = haystack(snapshot);
  const cap = options.cardCap ?? COLLECTION_CARD_CAP;
  const cards = snapshot.payload.cards?.length ?? 0;

  const pageOf = PAGE_OF.exec(text);
  if (pageOf) {
    const current = Number(pageOf[1]);
    const total = Number(pageOf[2]);
    if (Number.isFinite(current) && Number.isFinite(total) && current < total) {
      return { state: "partial", reason: "has_next" };
    }
    if (Number.isFinite(current) && Number.isFinite(total) && current >= total && total > 0) {
      return { state: "complete", reason: "last_page" };
    }
  }

  const range = RANGE.exec(text);
  if (range) {
    const end = Number(range[2]);
    const total = Number(range[3]);
    if (Number.isFinite(end) && Number.isFinite(total) && end < total) {
      return { state: "partial", reason: "has_next" };
    }
    if (Number.isFinite(end) && Number.isFinite(total) && end >= total) {
      return { state: "complete", reason: "last_page" };
    }
  }

  if (INFINITE_SCROLL.some((pattern) => pattern.test(text))) {
    return { state: "partial", reason: "infinite_scroll" };
  }
  if (HAS_NEXT.some((pattern) => pattern.test(text)) && !LAST_PAGE.some((pattern) => pattern.test(text))) {
    return { state: "partial", reason: "has_next" };
  }
  if (cards >= cap || options.recordCount >= cap) {
    return { state: "partial", reason: "truncated" };
  }
  if (LAST_PAGE.some((pattern) => pattern.test(text))) {
    return { state: "complete", reason: "last_page" };
  }
  if (options.recordCount > 0 || cards > 0) {
    return { state: "complete", reason: "single_page" };
  }
  return { state: "unknown" };
}
