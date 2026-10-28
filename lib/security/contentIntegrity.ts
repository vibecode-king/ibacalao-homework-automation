/**
 * Prompt-injection / hidden-instruction integrity signals for untrusted school
 * and document content. This module never decides that a teacher is cheating;
 * it records evidence that content is trying to steer a model or is presented
 * in a way a student is unlikely to see.
 *
 * Important trust rule: content that triggers this detector remains DATA. It
 * never gains authority over system/developer instructions. Strongly concealed
 * chunks can be quarantined before they are sent to a model while the bounded
 * integrity summary is retained for product surfaces and telemetry.
 */

export const CONTENT_INTEGRITY_REASONS = [
  "ai_directive",
  "instruction_override",
  "system_prompt_probe",
  "forced_output",
  "external_link_directive",
  "hidden_text",
  "transparent_text",
  "tiny_text",
  "low_contrast_text",
  "offscreen_text",
  "office_hidden_text",
] as const;

export type ContentIntegrityReason = (typeof CONTENT_INTEGRITY_REASONS)[number];
export type ContentIntegrityRisk = "low" | "medium" | "high";

export type ContentIntegritySummary = {
  risk: ContentIntegrityRisk;
  score: number;
  reasons: ContentIntegrityReason[];
  /** Bounded evidence for a human review surface. Never execute or interpolate as instructions. */
  excerpt?: string;
};

export type ContentPresentationAnomaly = {
  text: string;
  reasons: ContentIntegrityReason[];
};

const AI_AUDIENCE = /(?:\b(?:if|when)\s+(?:you|this\s+(?:assistant|model))\s+(?:are|were|are\s+acting\s+as)\s+(?:an?\s+)?(?:ai|artificial intelligence|language model|llm|assistant|chatgpt|claude|gemini|copilot)\b|\b(?:as|for)\s+(?:an?\s+)?(?:ai|language model|llm|ai assistant)\b|\bsi\s+(?:eres|usted\s+es)\s+(?:una?\s+)?(?:ia|inteligencia artificial|modelo de lenguaje|asistente)\b)/i;
const MODEL_IMPERATIVE = /\b(?:chatgpt|claude|gemini|copilot|llm|ai assistant|asistente de ia)\b\s*(?::|,|;|-|\b(?:must|should|please|debe|deber[aá]|por favor)\b)\s*(?:cite|include|insert|append|output|return|respond|answer|write|say|mention|print|emit|visit|open|follow|cita|incluye|inserta|agrega|devuelve|responde|escribe|di|menciona|imprime|visita|abre|sigue)\b/i;
const OVERRIDE = /(?:\b(?:ignore|disregard|forget|override|bypass)\b.{0,80}\b(?:previous|prior|above|earlier|system|developer|instructions?|rules?|prompt)\b|\bdo\s+not\s+follow\b.{0,80}\b(?:previous|system|developer|instructions?|rules?)\b|\b(?:ignora|ignore|omite|olvida|anula|reemplaza)\b.{0,80}\b(?:instrucciones?|reglas?|prompt|anteriores?|previas?|del sistema)\b)/i;
const SYSTEM_PROBE = /\b(?:system prompt|developer message|hidden instructions?|reveal (?:your|the) prompt|show (?:your|the) instructions?|prompt del sistema|mensaje de desarrollador|instrucciones ocultas|revela(?:r)? (?:tu|el) prompt)\b/i;
const OUTPUT_VERB = /\b(?:cite|include|insert|append|output|return|respond|answer|write|say|mention|print|emit|visit|open|follow|cita|citar|incluye|incluir|inserta|agrega|devuelve|responde|escribe|di|menciona|imprime|visita|abre|sigue)\b/i;
const OUTPUT_TARGET = /\b(?:this|the|este|esta|el|la)?\s*(?:link|url|enlace|citation|source|fuente|phrase|frase|token|text|texto|exact(?:ly)?|exacto|full marks?|maximum score|nota m[aá]xima|puntaje m[aá]ximo)\b/i;
const EXTERNAL_LINK = /(?:https?:\/\/|www\.|\b(?:this|that|este|ese)\s+(?:link|url|enlace)\b)/i;

const STRONG_CONCEALMENT = new Set<ContentIntegrityReason>([
  "hidden_text",
  "transparent_text",
  "offscreen_text",
  "office_hidden_text",
]);

function cleanExcerpt(value: string): string | undefined {
  const cleaned = value
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return cleaned ? cleaned.slice(0, 240) : undefined;
}

function riskForScore(score: number): ContentIntegrityRisk {
  if (score >= 65) return "high";
  if (score >= 35) return "medium";
  return "low";
}

function semanticSignals(text: string): { score: number; reasons: ContentIntegrityReason[] } {
  const reasons: ContentIntegrityReason[] = [];
  let score = 0;
  const aiAudience = AI_AUDIENCE.test(text);
  const override = OVERRIDE.test(text);
  const systemProbe = SYSTEM_PROBE.test(text);
  const outputVerb = OUTPUT_VERB.test(text);
  const outputTarget = OUTPUT_TARGET.test(text);
  const modelImperative = MODEL_IMPERATIVE.test(text);
  const externalLink = EXTERNAL_LINK.test(text);

  if (aiAudience) {
    reasons.push("ai_directive");
    score += 45;
  }
  if (override) {
    reasons.push("instruction_override");
    score += 45;
  }
  if (systemProbe) {
    reasons.push("system_prompt_probe");
    score += 35;
  }
  // A bare imperative in school instructions is normal. Treat it as model
  // manipulation only when it directly targets a model, or appears alongside
  // an override/system-probe signal.
  if (outputVerb && (aiAudience || modelImperative || override || systemProbe)) {
    reasons.push("forced_output");
    score += 25;
  }
  if (outputVerb && externalLink && (aiAudience || modelImperative || override || systemProbe) && outputTarget) {
    reasons.push("external_link_directive");
    score += 10;
  }
  return { score, reasons };
}

function presentationWeight(reason: ContentIntegrityReason): number {
  switch (reason) {
    case "hidden_text":
    case "transparent_text":
    case "offscreen_text":
    case "office_hidden_text":
      return 40;
    case "tiny_text":
    case "low_contrast_text":
      return 25;
    default:
      return 0;
  }
}

/**
 * Detects likely model-directed manipulation in text and combines it with
 * independent presentation evidence. Presentation evidence matters even if a
 * future attack uses wording our semantic signatures have never seen.
 */
export function analyzePotentialPromptInjection(
  text: string,
  presentationReasons: ContentIntegrityReason[] = [],
): ContentIntegritySummary | undefined {
  const bounded = text.slice(0, 50_000);
  const semantic = semanticSignals(bounded);
  const presentation = Array.from(new Set(
    presentationReasons.filter((reason): reason is ContentIntegrityReason => CONTENT_INTEGRITY_REASONS.includes(reason)),
  ));
  const reasons = Array.from(new Set([...semantic.reasons, ...presentation])).slice(0, 12);
  let score = semantic.score;
  for (const reason of presentation) score += presentationWeight(reason);
  score = Math.max(0, Math.min(100, score));
  if (score === 0 || reasons.length === 0) return undefined;
  return {
    risk: riskForScore(score),
    score,
    reasons,
    ...(cleanExcerpt(bounded) ? { excerpt: cleanExcerpt(bounded) } : {}),
  };
}

export function mergeContentIntegrity(
  ...values: Array<ContentIntegritySummary | null | undefined>
): ContentIntegritySummary | undefined {
  const reports = values.filter((value): value is ContentIntegritySummary => Boolean(value));
  if (reports.length === 0) return undefined;
  const reasons = Array.from(new Set(reports.flatMap((report) => report.reasons))).slice(0, 12);
  const highest = [...reports].sort((a, b) => b.score - a.score)[0];
  const score = Math.min(100, Math.max(...reports.map((report) => report.score)) + Math.max(0, reasons.length - highest.reasons.length) * 3);
  return {
    risk: riskForScore(score),
    score,
    reasons,
    ...(highest.excerpt ? { excerpt: highest.excerpt } : {}),
  };
}

/** Fail-closed parsing for integrity metadata crossing the watcher→server boundary. */
export function normalizeContentIntegrity(value: unknown): ContentIntegritySummary | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const raw = value as Record<string, unknown>;
  if (raw.risk !== "low" && raw.risk !== "medium" && raw.risk !== "high") return undefined;
  if (typeof raw.score !== "number" || !Number.isFinite(raw.score)) return undefined;
  if (!Array.isArray(raw.reasons)) return undefined;
  const reasons = Array.from(new Set(raw.reasons.filter(
    (reason): reason is ContentIntegrityReason => typeof reason === "string"
      && CONTENT_INTEGRITY_REASONS.includes(reason as ContentIntegrityReason),
  ))).slice(0, 12);
  if (reasons.length === 0) return undefined;
  const excerpt = typeof raw.excerpt === "string" ? cleanExcerpt(raw.excerpt) : undefined;
  const score = Math.max(0, Math.min(100, Math.round(raw.score)));
  return { risk: riskForScore(score), score, reasons, ...(excerpt ? { excerpt } : {}) };
}

export function normalizePresentationAnomalies(value: unknown): ContentPresentationAnomaly[] {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 80).flatMap((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) return [];
    const raw = item as Record<string, unknown>;
    if (typeof raw.text !== "string") return [];
    const text = raw.text.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim().slice(0, 2000);
    if (!text || !Array.isArray(raw.reasons)) return [];
    const reasons = Array.from(new Set(raw.reasons.filter(
      (reason): reason is ContentIntegrityReason => typeof reason === "string"
        && CONTENT_INTEGRITY_REASONS.includes(reason as ContentIntegrityReason),
    ))).slice(0, 8);
    return reasons.length > 0 ? [{ text, reasons }] : [];
  });
}

/**
 * Only presentation-backed evidence may be removed. Visible prose is retained
 * for grading even when it talks about prompt injection; it is merely flagged
 * and remains inside the untrusted-data boundary.
 */
export function shouldQuarantinePresentedText(
  report: ContentIntegritySummary | undefined,
  presentationReasons: ContentIntegrityReason[],
): boolean {
  if (!report || presentationReasons.length === 0) return false;
  if (presentationReasons.some((reason) => STRONG_CONCEALMENT.has(reason))) return true;
  const weakConcealment = presentationReasons.includes("tiny_text")
    && presentationReasons.includes("low_contrast_text");
  return weakConcealment || report.risk === "high";
}

/**
 * Reconciles DOM-extracted text with style anomalies. Each anomalous snippet is
 * assessed independently; only that exact snippet is removed when quarantine
 * is justified, while its integrity evidence remains available to the caller.
 */
export function sanitizePresentedText(
  text: string,
  anomalies: ContentPresentationAnomaly[] = [],
): { text: string; integrity?: ContentIntegritySummary } {
  let safeText = text.replace(/\s+/g, " ").trim();
  let integrity = analyzePotentialPromptInjection(safeText);
  for (const anomaly of anomalies.slice(0, 80)) {
    const snippet = anomaly.text.replace(/\s+/g, " ").trim().slice(0, 2000);
    if (!snippet) continue;
    const reasons = Array.from(new Set(anomaly.reasons)).filter(
      (reason): reason is ContentIntegrityReason => CONTENT_INTEGRITY_REASONS.includes(reason),
    );
    if (reasons.length === 0) continue;
    const report = analyzePotentialPromptInjection(snippet, reasons);
    integrity = mergeContentIntegrity(integrity, report);
    if (!shouldQuarantinePresentedText(report, reasons)) continue;
    const index = safeText.indexOf(snippet);
    if (index >= 0) {
      safeText = `${safeText.slice(0, index)} ${safeText.slice(index + snippet.length)}`.replace(/\s+/g, " ").trim();
    }
  }
  return { text: safeText, ...(integrity ? { integrity } : {}) };
}
