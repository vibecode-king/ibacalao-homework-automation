import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import type {
  SchoolAttachmentDownloadPayload,
  SchoolAcademicLink,
  SchoolCaptureEvent,
  SchoolDomCardEvidence,
  SchoolDomSnapshotPayload,
  SchoolNavigationEdgePayload,
  SchoolPageRole,
  SchoolRecipe,
} from "./types";
import { parseSchoolSourceKey } from "./source";
import { isNonAcademicTitle } from "./tableParse";
import { safeMachineHtml, safeRelativePath } from "../security/untrustedContent";
import type { ScrapedRecord } from "../watcher/types";

const CAPTURE_RETENTION_MS = 24 * 60 * 60 * 1000;
export const PASSIVE_HEALTH_FRESHNESS_MS = 5 * 60 * 1000;
const MAX_RING_BYTES = 20 * 1024 * 1024;
const MAX_CARDS = 40;
const MAX_SANITIZED_HTML = 256 * 1024;

export type StoredCapture = SchoolCaptureEvent & { receivedAt?: string; captureEventId?: string };

export type RecentCaptureOptions = {
  sourceKey: string;
  origin: string;
  nowMs?: number;
};

export type DomSnapshotObservation = {
  sourceKey: string;
  origin: string;
  observedAt: string;
  receivedAt?: string;
  payload: SchoolDomSnapshotPayload;
};

export type ClassifiedCard = {
  card: SchoolDomCardEvidence;
  entity: SchoolRecipe["entity"];
  confidence: number;
};

export type NavigationEdgeObservation = {
  sourceKey: string;
  origin: string;
  observedAt: string;
  payload: SchoolNavigationEdgePayload;
};

export type AttachmentDownloadObservation = {
  sourceKey: string;
  origin: string;
  observedAt: string;
  payload: SchoolAttachmentDownloadPayload;
};

function text(value: unknown, max: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.replace(/\s+/g, " ").trim();
  return normalized ? normalized.slice(0, max) : undefined;
}

function stringArray(value: unknown, maxItems: number, maxLength: number): string[] {
  return Array.isArray(value)
    ? value.flatMap((item) => {
        const clean = text(item, maxLength);
        return clean ? [clean] : [];
      }).slice(0, maxItems)
    : [];
}

function normalizeAcademicLink(value: unknown): SchoolAcademicLink | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  const path = safeRelativePath(raw.path, 500);
  if (!path) return null;
  const relationship = raw.relationship === "detail" || raw.relationship === "attachment"
    ? raw.relationship
    : "unknown";
  return {
    path,
    relationship,
    ...(text(raw.text, 240) ? { text: text(raw.text, 240) } : {}),
    ...(text(raw.downloadName, 240) ? { downloadName: text(raw.downloadName, 240) } : {}),
  };
}

function normalizeCard(value: unknown): SchoolDomCardEvidence | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  const captureId = text(raw.captureId, 40);
  const selector = text(raw.selector, 400);
  const groupSelector = text(raw.groupSelector, 400);
  const tag = text(raw.tag, 20)?.toLowerCase();
  const cardText = text(raw.text, 12000);
  if (!captureId || !selector || !groupSelector || !tag || !cardText) return null;

  const attributes: Record<string, string> = {};
  if (raw.attributes && typeof raw.attributes === "object" && !Array.isArray(raw.attributes)) {
    for (const [key, value] of Object.entries(raw.attributes).slice(0, 12)) {
      const cleanKey = text(key, 40);
      const cleanValue = text(value, 160);
      if (cleanKey && cleanValue) attributes[cleanKey] = cleanValue;
    }
  }

  return {
    captureId,
    selector,
    groupSelector,
    tag,
    text: cardText,
    ...(text(raw.title, 300) ? { title: text(raw.title, 300) } : {}),
    ...(text(raw.subject, 180) ? { subject: text(raw.subject, 180) } : {}),
    ...(text(raw.dueAt, 80) ? { dueAt: text(raw.dueAt, 80) } : {}),
    ...(text(raw.status, 160) ? { status: text(raw.status, 160) } : {}),
    ...(text(raw.grade, 120) ? { grade: text(raw.grade, 120) } : {}),
    ...(text(raw.teacher, 180) ? { teacher: text(raw.teacher, 180) } : {}),
    ...(safeRelativePath(raw.path, 500) ? { path: safeRelativePath(raw.path, 500) } : {}),
    ...(text(raw.sourceRecordId, 160) ? { sourceRecordId: text(raw.sourceRecordId, 160) } : {}),
    links: Array.isArray(raw.links)
      ? raw.links.slice(0, 12).flatMap((link) => {
          const normalized = normalizeAcademicLink(link);
          return normalized ? [normalized] : [];
        })
      : [],
    classTokens: stringArray(raw.classTokens, 12, 64),
    childTags: stringArray(raw.childTags, 20, 20).map((item) => item.toLowerCase()),
    attributes,
  };
}

function normalizeDomPayload(value: unknown): SchoolDomSnapshotPayload | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  if (raw.kind !== "dom-snapshot") return null;
  const path = safeRelativePath(raw.path, 500);
  if (!path) return null;
  const rows = Array.isArray(raw.rows) ? raw.rows.slice(0, 80).filter((row) => row && typeof row === "object") as Array<Record<string, unknown>> : [];
  const cards = Array.isArray(raw.cards)
    ? raw.cards.slice(0, MAX_CARDS).flatMap((card) => {
        const normalized = normalizeCard(card);
        return normalized ? [normalized] : [];
      })
    : [];
  const sanitizedHtml = safeMachineHtml(raw.sanitizedHtml, MAX_SANITIZED_HTML);
  const pageRole = (["collection", "detail", "messages", "grades", "attachments", "unknown"] as SchoolPageRole[])
    .includes(raw.pageRole as SchoolPageRole)
    ? raw.pageRole as SchoolPageRole
    : undefined;
  return {
    kind: "dom-snapshot",
    path,
    ...(pageRole ? { pageRole } : {}),
    rows,
    ...(cards.length ? { cards } : {}),
    ...(cards.length && sanitizedHtml ? { sanitizedHtml } : {}),
  };
}

function normalizeNavigationEdge(value: unknown): SchoolNavigationEdgePayload | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  if (raw.kind !== "navigation-edge") return null;
  const fromPath = safeRelativePath(raw.fromPath, 500);
  const toPath = safeRelativePath(raw.toPath, 500);
  if (!fromPath || !toPath) return null;
  const relationship = raw.relationship === "detail" || raw.relationship === "attachment"
    ? raw.relationship
    : "unknown";
  return {
    kind: "navigation-edge",
    fromPath,
    toPath,
    relationship,
    ...(text(raw.sourceRecordId, 160) ? { sourceRecordId: text(raw.sourceRecordId, 160) } : {}),
    ...(text(raw.fromTitle, 300) ? { fromTitle: text(raw.fromTitle, 300) } : {}),
  };
}

function normalizeAttachmentDownload(value: unknown): SchoolAttachmentDownloadPayload | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const raw = value as Record<string, unknown>;
  if (raw.kind !== "attachment-download") return null;
  const localPath = text(raw.localPath, 2048);
  const fileName = text(raw.fileName, 300);
  if (!localPath || !fileName) return null;
  const sizeBytes = typeof raw.sizeBytes === "number" && Number.isFinite(raw.sizeBytes) && raw.sizeBytes >= 0
    ? Math.min(Math.floor(raw.sizeBytes), 100 * 1024 * 1024)
    : undefined;
  return {
    kind: "attachment-download",
    localPath,
    fileName,
    ...(safeRelativePath(raw.sourcePagePath, 500) ? { sourcePagePath: safeRelativePath(raw.sourcePagePath, 500) } : {}),
    ...(safeRelativePath(raw.sourceUrlPath, 500) ? { sourceUrlPath: safeRelativePath(raw.sourceUrlPath, 500) } : {}),
    ...(text(raw.mimeType, 160) ? { mimeType: text(raw.mimeType, 160) } : {}),
    ...(sizeBytes !== undefined ? { sizeBytes } : {}),
  };
}

/** The NDJSON capture ring is still the source of truth; lib/school/journal.ts
 *  mirrors what this returns so the two stores can be compared. */
export function readRecentCaptures(file: string, options: RecentCaptureOptions): StoredCapture[] {
  let raw: string;
  try {
    const data = readFileSync(file);
    if (data.byteLength > MAX_RING_BYTES) return [];
    raw = data.toString("utf8");
  } catch {
    return [];
  }

  const sourceKey = parseSchoolSourceKey(options.sourceKey);
  if (!sourceKey) return [];
  const nowMs = options.nowMs ?? Date.now();
  const expectedFingerprint = createHash("sha256").update(options.origin).digest("hex").slice(0, 32);
  if (sourceKey.startsWith("portal:") && sourceKey !== `portal:${expectedFingerprint}`) return [];

  const output: StoredCapture[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let parsed: StoredCapture;
    try {
      parsed = JSON.parse(line) as StoredCapture;
    } catch {
      continue;
    }
    if (
      parsed.type !== "school.capture"
      || parsed.sourceKey !== sourceKey
      || parsed.origin !== options.origin
      || parsed.originFingerprint !== expectedFingerprint
    ) continue;
    const observedMs = Date.parse(parsed.observedAt);
    const receivedMs = parsed.receivedAt ? Date.parse(parsed.receivedAt) : observedMs;
    if (!Number.isFinite(observedMs) || !Number.isFinite(receivedMs)) continue;
    if (nowMs - receivedMs < 0 || nowMs - receivedMs > CAPTURE_RETENTION_MS) continue;
    output.push(parsed);
  }
  return output.sort((a, b) => Date.parse(a.observedAt) - Date.parse(b.observedAt));
}

export function snapshotsFromCaptures(captures: StoredCapture[]): DomSnapshotObservation[] {
  return captures.flatMap((parsed) => {
    const payload = normalizeDomPayload(parsed.payload);
    if (!payload) return [];
    return [{
      sourceKey: parsed.sourceKey,
      origin: parsed.origin,
      observedAt: parsed.observedAt,
      ...(parsed.receivedAt ? { receivedAt: parsed.receivedAt } : {}),
      payload,
    }];
  });
}

export function navigationEdgesFromCaptures(captures: StoredCapture[]): NavigationEdgeObservation[] {
  return captures.flatMap((parsed) => {
    const payload = normalizeNavigationEdge(parsed.payload);
    return payload ? [{ sourceKey: parsed.sourceKey, origin: parsed.origin, observedAt: parsed.observedAt, payload }] : [];
  });
}

export function attachmentDownloadsFromCaptures(captures: StoredCapture[]): AttachmentDownloadObservation[] {
  return captures.flatMap((parsed) => {
    const payload = normalizeAttachmentDownload(parsed.payload);
    return payload ? [{ sourceKey: parsed.sourceKey, origin: parsed.origin, observedAt: parsed.observedAt, payload }] : [];
  });
}

export function jsonShapesFromCaptures(captures: StoredCapture[]): Array<{
  sourceKey: string;
  origin: string;
  observedAt: string;
  endpointTemplate: string;
  schema: unknown;
}> {
  return captures.flatMap((parsed) => {
    const payload = parsed.payload as Record<string, unknown>;
    if (payload?.kind !== "json-response-shape") return [];
    const endpointTemplate = text(payload.endpointTemplate, 500);
    if (!endpointTemplate?.startsWith("/")) return [];
    return [{
      sourceKey: parsed.sourceKey,
      origin: parsed.origin,
      observedAt: parsed.observedAt,
      endpointTemplate,
      schema: payload.schema,
    }];
  });
}

export function readRecentDomSnapshots(
  file: string,
  options: RecentCaptureOptions,
): DomSnapshotObservation[] {
  return snapshotsFromCaptures(readRecentCaptures(file, options));
}

export function readRecentNavigationEdges(
  file: string,
  options: RecentCaptureOptions,
): NavigationEdgeObservation[] {
  return navigationEdgesFromCaptures(readRecentCaptures(file, options));
}

export function readRecentAttachmentDownloads(
  file: string,
  options: RecentCaptureOptions,
): AttachmentDownloadObservation[] {
  return attachmentDownloadsFromCaptures(readRecentCaptures(file, options));
}

const WORDS = {
  assignment: /\b(assignment|task|homework|assessment|project|tarea|deber|actividad|trabajo)\b/i,
  message: /\b(message|announcement|inbox|notice|mensaje|anuncio|comunicado)\b/i,
  grade: /\b(grade|score|mark|result|nota|calificaci[oó]n|puntaje)\b/i,
  submission: /\b(submission|submitted|turned in|handed in|entregado|enviado|entrega realizada)\b/i,
  deadline: /\b(due|deadline|due date|vence|vencimiento|fecha de entrega|entrega)\b/i,
};

export function classifyDomCard(
  card: SchoolDomCardEvidence,
  routePath = "",
  pageRole: SchoolPageRole = "unknown",
): ClassifiedCard | null {
  const title = card.title ?? card.text;
  if (title && isNonAcademicTitle(title)) return null;
  const localHaystack = [card.text, card.title, card.subject, card.status, card.groupSelector, card.selector]
    .filter(Boolean)
    .join(" ");
  const routeHaystack = routePath;

  if (card.grade || WORDS.grade.test(localHaystack)) {
    return { card, entity: "grade", confidence: card.grade ? 0.99 : 0.9 };
  }
  if (WORDS.submission.test(localHaystack)) {
    return { card, entity: "submission", confidence: card.status ? 0.97 : 0.91 };
  }
  // Route/page-role classification is stronger than menu/card wording for old
  // table-based portals. A message row often contains only sender/subject/date
  // and therefore has no literal "message" token in the row itself.
  if (pageRole === "messages") {
    return { card, entity: "message", confidence: 0.96 };
  }
  if (WORDS.message.test(localHaystack)) {
    return { card, entity: "message", confidence: 0.93 };
  }
  if (card.dueAt && WORDS.assignment.test(localHaystack)) {
    return { card, entity: "assignment", confidence: 0.98 };
  }
  if (WORDS.assignment.test(localHaystack)) {
    return { card, entity: "assignment", confidence: 0.92 };
  }
  if (card.dueAt && WORDS.assignment.test(routeHaystack)) {
    return { card, entity: "assignment", confidence: 0.91 };
  }
  if (card.dueAt || WORDS.deadline.test(localHaystack)) {
    return { card, entity: "deadline", confidence: card.dueAt ? 0.94 : 0.9 };
  }
  return null;
}

export type PassiveBarrier = {
  reason: "reauth_required" | "challenge_paused";
  observedAt: string;
};

const CHALLENGE_WORDS = /\b(captcha|verify (?:you are|you're) human|checking your browser|security check|unusual traffic|access denied|bot check|cloudflare|just a moment)\b/i;
const LOGIN_PATH = /(?:^|\/)(?:login|log-in|signin|sign-in|sso)(?:\/|$)/i;
const LOGIN_TITLE = /\b(?:log in|login|sign in|single sign-on)\b/i;

/**
 * Passive sources never probe the LMS to determine health. We only interpret
 * what the student's already-open browser reported. A later academic snapshot
 * clears an earlier login/challenge signal so transient SSO routes do not leave
 * the connector stuck in an action-required state.
 */
export function detectPassiveBarrier(file: string, options: RecentCaptureOptions): PassiveBarrier | null {
  let latestAcademicMs = Number.NEGATIVE_INFINITY;
  let latestAuth: PassiveBarrier | null = null;
  let latestChallenge: PassiveBarrier | null = null;

  for (const capture of readRecentCaptures(file, options)) {
    const observedMs = Date.parse(capture.observedAt);
    const payload = capture.payload as Record<string, unknown>;
    const kind = payload.kind;

    if (kind === "route" || kind === "hello") {
      const path = text(payload.path, 300) ?? "";
      const title = text(payload.title, 160) ?? "";
      if (LOGIN_PATH.test(path) || LOGIN_TITLE.test(title)) {
        latestAuth = { reason: "reauth_required", observedAt: capture.observedAt };
      }
    }

    if (kind !== "dom-snapshot") continue;
    const normalized = normalizeDomPayload(payload);
    if (!normalized) continue;
    if ((normalized.cards ?? []).some((card) => Boolean(classifyDomCard(card, normalized.path, normalized.pageRole ?? "unknown")))) {
      latestAcademicMs = Math.max(latestAcademicMs, observedMs);
    }
    const visibleText = [
      ...normalized.rows.flatMap((row) => typeof row.text === "string" ? [row.text] : []),
      ...(normalized.cards ?? []).map((card) => card.text),
    ].join(" ");
    if (CHALLENGE_WORDS.test(visibleText)) {
      latestChallenge = { reason: "challenge_paused", observedAt: capture.observedAt };
    }
  }

  if (latestChallenge && Date.parse(latestChallenge.observedAt) > latestAcademicMs) return latestChallenge;
  if (latestAuth && Date.parse(latestAuth.observedAt) > latestAcademicMs) return latestAuth;
  return null;
}

function cleanDate(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : undefined;
}

function absoluteSameOriginPath(origin: string, value: string | undefined): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value, origin);
    return url.origin === new URL(origin).origin ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function extractTeacher(card: SchoolDomCardEvidence, entity: SchoolRecipe["entity"]): string | undefined {
  if (text(card.teacher, 180)) return text(card.teacher, 180);
  const haystack = card.text;
  if (entity === "message") {
    const match = haystack.match(/\b(?:de|from)\s*:\s*([A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ.' -]{1,80})/i);
    return match?.[1]?.trim().slice(0, 180);
  }
  const match = haystack.match(/\b(?:teacher|profesor[ae]?|docente)\s*[:\-]\s*([A-ZÁÉÍÓÚÑ][\wÁÉÍÓÚÑáéíóúñ.' -]{1,80})/i);
  return match?.[1]?.trim().slice(0, 180);
}

function extractThreadId(card: SchoolDomCardEvidence, routePath: string): string | undefined {
  const fromCard = text(card.sourceRecordId, 160);
  if (fromCard && /message|thread|inbox/i.test(`${card.path ?? ""} ${routePath}`)) return fromCard;
  const path = card.path ?? routePath;
  const segment = path.split("/").filter(Boolean).at(-1);
  if (segment && /fViewMessage|thread|inbox/i.test(path) && segment.length <= 160) return segment;
  return undefined;
}

export function recordFromCard(
  entity: SchoolRecipe["entity"],
  card: SchoolDomCardEvidence,
  origin: string,
  routePath: string,
  pageRole: SchoolPageRole = "unknown",
  observedAt?: string,
): ScrapedRecord | null {
  const title = text(card.title, 300) ?? text(card.text, 300);
  if (!title || isNonAcademicTitle(title)) return null;
  const dueAt = cleanDate(card.dueAt);
  const grade = text(card.grade, 120);
  const status = text(card.status, 160);
  const teacher = extractTeacher(card, entity);
  const threadId = entity === "message" ? extractThreadId(card, routePath) : undefined;
  const detail = pageRole === "detail"
    ? (() => {
        const full = text(card.text, 12000);
        if (!full || full.length < Math.max(120, title.length + 40)) return undefined;
        return full;
      })()
    : undefined;
  if (entity === "grade" && !grade) return null;
  if (entity === "submission" && !status && !WORDS.submission.test(card.text)) return null;
  if (entity === "deadline" && !dueAt) return null;

  const sourceRecordId = text(card.sourceRecordId, 160) ?? createHash("sha256")
    // A deadline can move without changing the identity of the assignment.
    // Keep volatile academic state out of the synthetic fallback id.
    .update([entity, routePath, card.path ?? "", title, card.subject ?? ""].join("\u0000"))
    .digest("hex")
    .slice(0, 32);

  return {
    sourceRecordId,
    kind: entity,
    title,
    ...(text(card.subject, 180) ? { subject: text(card.subject, 180) } : {}),
    ...(absoluteSameOriginPath(origin, card.path ?? routePath) ? { url: absoluteSameOriginPath(origin, card.path ?? routePath) } : {}),
    ...(detail ? { detail } : {}),
    ...(dueAt ? { dueAt } : {}),
    ...(status ? { status } : {}),
    ...(grade ? { grade } : {}),
    ...(teacher ? { teacher } : {}),
    ...(threadId ? { threadId } : {}),
    ...(observedAt ? { observedAt } : {}),
  };
}
