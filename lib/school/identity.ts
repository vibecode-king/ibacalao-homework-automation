import { createHash } from "node:crypto";
import type { ScrapedRecord } from "../watcher/types";

const STABLE_QUERY_KEY = /^(?:id|(?:assignment|task|message|grade|item|resource|activity|course)[_-]?id)$/i;
const ID_SEGMENT = /^(?:\d{2,}|[0-9a-f]{8}-[0-9a-f-]{27,}|[A-Za-z0-9_-]{20,})$/i;

function normalizeText(value: string | undefined): string {
  return (value ?? "").replace(/\s+/g, " ").trim().toLowerCase();
}

export function canonicalSchoolUrl(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  try {
    const url = new URL(raw);
    url.hash = "";
    const stable = Array.from(url.searchParams.entries())
      .filter(([key, value]) => STABLE_QUERY_KEY.test(key) && value.length > 0 && value.length <= 160)
      .sort(([a], [b]) => a.localeCompare(b));
    url.search = "";
    for (const [key, value] of stable.slice(0, 4)) url.searchParams.append(key, value);
    return url.toString();
  } catch {
    return undefined;
  }
}

export function isStrongSchoolUrl(raw: string | undefined): boolean {
  const normalized = canonicalSchoolUrl(raw);
  if (!normalized) return false;
  const url = new URL(normalized);
  if (Array.from(url.searchParams.keys()).some((key) => STABLE_QUERY_KEY.test(key))) return true;
  return url.pathname.split("/").filter(Boolean).some((segment) => ID_SEGMENT.test(segment));
}

export function sourceAlias(kind: ScrapedRecord["kind"], sourceRecordId: string | undefined): string | undefined {
  const value = sourceRecordId?.trim();
  return value ? `source:${kind}:${value}` : undefined;
}

export function urlAlias(kind: ScrapedRecord["kind"], raw: string | undefined): string | undefined {
  const normalized = canonicalSchoolUrl(raw);
  return normalized ? `url:${kind}:${normalized}` : undefined;
}

export function semanticSignature(record: ScrapedRecord): string | undefined {
  const title = normalizeText(record.title);
  const subject = normalizeText(record.subject);
  const due = record.dueAt && Number.isFinite(Date.parse(record.dueAt))
    ? new Date(record.dueAt).toISOString()
    : "";
  // Semantic identity is intentionally strict. Generic titles like "Homework"
  // are common, so the fallback only participates when title + subject + due
  // all agree exactly and stronger source/url aliases were unavailable.
  if (!title || !subject || !due) return undefined;
  return `semantic:${record.kind}:${title}\u0000${subject}\u0000${due}`;
}

export function canonicalEntityId(sourceKey: string, kind: ScrapedRecord["kind"], seed: string): string {
  return `school_${createHash("sha256")
    .update([sourceKey, kind, seed].join("\u0000"))
    .digest("hex")
    .slice(0, 32)}`;
}
