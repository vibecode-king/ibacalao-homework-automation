// STATUS: MVP heuristic, deliberately coarse — keyword/regex matching on
// title text only, no learning, no per-school tuning. Good enough to unblock
// the urgency-aware ranking in lib/mission/rank.ts; revisit once there's
// real message data to judge false positive/negative rates against.
//
// Classifies a school-portal message's urgency from its title/preview text
// alone — the part already captured passively from an inbox list view. This
// intentionally never opens a message to read its full body: the school-bridge
// extension's contract is that it issues zero requests and zero clicks against
// the school platform (see browser-extension/school-bridge/README.md), so
// anything that needs a message's full content still requires the student to
// open it themselves. This only decides which unopened messages are worth
// surfacing to the student as something to act on today.

export type MessageUrgencyLevel = "low" | "medium" | "high";

export type MessageUrgencyResult = {
  level: MessageUrgencyLevel;
  score: number;
  reason: string;
};

const LOW_PATTERNS: RegExp[] = [
  /\b(promoci[oó]n|descuento|oferta|publicidad|newsletter|bolet[ií]n|marketing)\b/i,
];

// Words that signal something time-bound and actionable, independent of a
// literal date the title may also carry.
const HIGH_KEYWORD_PATTERNS: RegExp[] = [
  /\b(urgente|importante|atenci[oó]n|aviso)\b/i,
  /\b(recordatorio|reminder)\b/i,
  /\b(examen|prueba|quiz|evaluaci[oó]n|exam|test)\b/i,
  /\b(entrega|fecha l[ií]mite|deadline|vence|vencimiento|due)\b/i,
  /\b(cancelad[oa]|suspendid[oa]|cancelled|suspended|reprogramad[oa]|rescheduled)\b/i,
];

// Near-term time references. "Next week" or a bare weekday name is common but
// not urgent enough on its own; today/tomorrow/first-thing-in-the-morning is.
const NEAR_TERM_PATTERNS: RegExp[] = [
  /\b(hoy|ma[ñn]ana|today|tomorrow)\b/i,
  /\bprimera hora\b/i,
  /\bfirst (period|hour|thing)\b/i,
];

export function classifyMessageUrgency(title: string, detail?: string): MessageUrgencyResult {
  const text = `${title} ${detail ?? ""}`.trim();

  if (LOW_PATTERNS.some((pattern) => pattern.test(text))) {
    return { level: "low", score: 0.5, reason: "promotional_or_marketing" };
  }

  const hasHighKeyword = HIGH_KEYWORD_PATTERNS.some((pattern) => pattern.test(text));
  const hasNearTerm = NEAR_TERM_PATTERNS.some((pattern) => pattern.test(text));

  if (hasHighKeyword && hasNearTerm) {
    return { level: "high", score: 10, reason: "time_bound_and_near_term" };
  }
  if (hasHighKeyword || hasNearTerm) {
    return { level: "high", score: 8, reason: hasHighKeyword ? "time_bound_keyword" : "near_term_reference" };
  }

  return { level: "medium", score: 3, reason: "no_strong_signal" };
}
