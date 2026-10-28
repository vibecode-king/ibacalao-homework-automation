// Deterministic school-message ranking. This intentionally has no LLM or
// network dependency: the watcher must be able to rank a newly-fetched inbox
// even when everything else is offline.

export type MessageImportanceLevel = "low" | "medium" | "high";

export type MessageImportanceReason =
  | "academic_action"
  | "assessment_or_deadline"
  | "near_term"
  | "teacher_or_staff_sender"
  | "academic_attachment"
  | "attachment"
  | "promotional_noise"
  | "social_event_noise"
  | "weak_content";

export type MessageImportanceInput = {
  sender?: string;
  heading?: string;
  body?: string;
  attachments?: string[];
};

export type MessageImportanceResult = {
  /** Stable 0–100 score. */
  score: number;
  level: MessageImportanceLevel;
  reasons: MessageImportanceReason[];
};

const ACADEMIC_ACTION = /\b(tarea|actividad|assignment|homework|ensayo|essay|monograf[ií]a|extended essay|\bia\b|internal assessment|entregar|entrega|submit|submission|completar|complete|corregir|correcci[oó]n|feedback|retroalimentaci[oó]n|revisi[oó]n|revision)\b/i;
const ASSESSMENT_OR_DEADLINE = /\b(examen|exam|prueba|test|quiz|evaluaci[oó]n|assessment|fecha l[ií]mite|deadline|vence|vencimiento|due|calificaci[oó]n|grade)\b/i;
const NEAR_TERM = /\b(hoy|ma[ñn]ana|today|tomorrow|esta tarde|esta noche|this afternoon|tonight|primera hora|first period|first thing)\b/i;
const STAFF_SENDER = /\b(prof(?:esor|esora)?|teacher|docente|coordinador(?:a)?|coordinator|rector(?:a)?|principal|secretar[ií]a|secretary|tutor(?:a)?|advisor|head of|jefe de)\b/i;
const PROMOTIONAL = /\b(promoci[oó]n|descuento|oferta|publicidad|marketing|newsletter|venta|sale|sponsor|patrocin)\b/i;
const SOCIAL_EVENT = /\b(fiesta|party|festival|feria|bazaar|bazar|celebraci[oó]n|celebration|social event|club social|foto(?:s)? del evento|event photos)\b/i;
const ACADEMIC_ATTACHMENT = /\.(pdf|docx?|pptx?|xlsx?)(?:\?|$)/i;

function addReason(reasons: MessageImportanceReason[], reason: MessageImportanceReason): void {
  if (!reasons.includes(reason)) reasons.push(reason);
}

export function scoreMessageImportance(input: MessageImportanceInput): MessageImportanceResult {
  const sender = (input.sender ?? "").trim();
  const heading = (input.heading ?? "").trim();
  const body = (input.body ?? "").trim();
  const attachments = (input.attachments ?? []).filter((item) => typeof item === "string" && item.trim());
  const content = `${heading} ${body}`.trim();

  let score = 20;
  const reasons: MessageImportanceReason[] = [];
  const academicAction = ACADEMIC_ACTION.test(content);
  const assessmentOrDeadline = ASSESSMENT_OR_DEADLINE.test(content);
  const nearTerm = NEAR_TERM.test(content);

  if (academicAction) {
    score += 32;
    addReason(reasons, "academic_action");
  }
  if (assessmentOrDeadline) {
    score += 28;
    addReason(reasons, "assessment_or_deadline");
  }
  if (nearTerm) {
    score += 14;
    addReason(reasons, "near_term");
  }
  if (sender && STAFF_SENDER.test(sender)) {
    score += 10;
    addReason(reasons, "teacher_or_staff_sender");
  }

  if (attachments.length > 0) {
    const hasAcademicAttachment = attachments.some((item) => ACADEMIC_ATTACHMENT.test(item));
    // An attachment is supporting evidence, never enough on its own to make a
    // content-free message high priority.
    if (hasAcademicAttachment && (academicAction || assessmentOrDeadline || body.length >= 40)) {
      score += 10;
      addReason(reasons, "academic_attachment");
    } else if (body.length >= 40 || heading.length >= 20) {
      score += 4;
      addReason(reasons, "attachment");
    }
  }

  if (PROMOTIONAL.test(content)) {
    score -= 42;
    addReason(reasons, "promotional_noise");
  }
  if (SOCIAL_EVENT.test(content) && !academicAction && !assessmentOrDeadline) {
    score -= 24;
    addReason(reasons, "social_event_noise");
  }
  if (content.length < 30) {
    score -= 10;
    addReason(reasons, "weak_content");
  }

  score = Math.max(0, Math.min(100, Math.round(score)));
  const level: MessageImportanceLevel = score >= 65 ? "high" : score >= 35 ? "medium" : "low";
  return { score, level, reasons };
}
