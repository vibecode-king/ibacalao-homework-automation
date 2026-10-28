import type { DomSnapshotObservation } from "./evidence";
import type { SchoolPageRole } from "./types";

const ID_SEGMENT = /^(?:\d{2,}|[0-9a-f]{8}-[0-9a-f-]{27,}|[A-Za-z0-9_-]{20,})$/i;

export function classifySchoolPage(snapshot: DomSnapshotObservation): SchoolPageRole {
  if (snapshot.payload.pageRole && snapshot.payload.pageRole !== "unknown") {
    return snapshot.payload.pageRole;
  }

  const path = snapshot.payload.path;
  if (/\b(message|messages|inbox|announcement|mensajes|bandeja)\b/i.test(path)) return "messages";
  if (/\b(grade|grades|marks|results|notas|calificaciones)\b/i.test(path)) return "grades";

  const cards = snapshot.payload.cards ?? [];
  const attachmentCount = cards
    .flatMap((card) => card.links ?? [])
    .filter((link) => link.relationship === "attachment")
    .length;
  if (attachmentCount >= 2 && cards.length <= 2) return "attachments";

  const groups = new Map<string, number>();
  for (const card of cards) groups.set(card.groupSelector, (groups.get(card.groupSelector) ?? 0) + 1);
  if (Array.from(groups).some(([, count]) => count >= 2)) return "collection";

  const hasStablePathId = path
    .split(/[/?]/)
    .filter(Boolean)
    .some((segment) => ID_SEGMENT.test(segment.split("=").at(-1) ?? segment));
  const richestCard = cards.reduce((max, card) => Math.max(max, card.text.length), 0);
  if (cards.length === 1 && (richestCard >= 400 || hasStablePathId)) return "detail";

  return "unknown";
}
