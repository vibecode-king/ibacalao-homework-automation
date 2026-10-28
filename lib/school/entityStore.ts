import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { writeFileAtomic } from "./atomicFile";
import type { ScrapedRecord } from "../watcher/types";
import type { NavigationEdgeObservation } from "./evidence";
import type { AttachmentDownloadObservation } from "./evidence";
import type { SchoolAttachmentExtraction } from "./attachments";
import {
  canonicalEntityId,
  canonicalSchoolUrl,
  isStrongSchoolUrl,
  semanticSignature,
  sourceAlias,
  urlAlias,
} from "./identity";

export type SchoolRecordChangeKind = "new_entity" | "source_changed" | "enriched" | "unchanged";

export type CanonicalSchoolAttachment = {
  id: string;
  fileName: string;
  sourceUrl?: string;
  mimeType?: string;
  sizeBytes?: number;
  text?: string;
  observedAt: string;
};

export type CanonicalSchoolEntity = {
  id: string;
  sourceKey: string;
  kind: ScrapedRecord["kind"];
  record: ScrapedRecord;
  /** School-page detail before locally extracted attachment text is appended. */
  sourceDetail?: string;
  aliases: string[];
  attachments: CanonicalSchoolAttachment[];
  learnedAt: string;
  updatedAt: string;
};

type EntityStoreFile = {
  schemaVersion: 1;
  sources: Record<string, { entities: CanonicalSchoolEntity[] }>;
};

export type ReconcileSchoolRecordsResult = {
  records: ScrapedRecord[];
  mutations: Array<{ sourceRecordId: string; changeKind: SchoolRecordChangeKind }>;
};

export const DEFAULT_SCHOOL_ENTITY_FILE = join(homedir(), ".ibacalao", "school", "entities.json");

function emptyStore(): EntityStoreFile {
  return { schemaVersion: 1, sources: {} };
}

function parseStoreFile(file: string): EntityStoreFile | null {
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8")) as EntityStoreFile;
    return parsed?.schemaVersion === 1 && parsed.sources && typeof parsed.sources === "object" ? parsed : null;
  } catch {
    return null;
  }
}

function backupFile(file: string): string {
  return `${file}.bak`;
}

function loadStore(file: string): EntityStoreFile {
  if (!existsSync(file)) return emptyStore();
  const current = parseStoreFile(file);
  if (current) return current;
  const backup = parseStoreFile(backupFile(file));
  if (backup) return backup;
  throw new Error(`school_entity_store_corrupt:${file}`);
}

function saveStore(store: EntityStoreFile, file: string): void {
  mkdirSync(dirname(file), { recursive: true });
  if (parseStoreFile(file)) copyFileSync(file, backupFile(file));
  writeFileAtomic(file, JSON.stringify(store, null, 2));
}

function clean(value: string | undefined): string | undefined {
  const normalized = value?.replace(/\s+/g, " ").trim();
  return normalized || undefined;
}

function comparableDate(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? new Date(ms).toISOString() : clean(value);
}

function fieldChanged(before: string | undefined, after: string | undefined, date = false): boolean {
  const left = date ? comparableDate(before) : clean(before)?.toLowerCase();
  const right = date ? comparableDate(after) : clean(after)?.toLowerCase();
  return Boolean(left && right && left !== right);
}

function classifyMerge(before: ScrapedRecord, incoming: ScrapedRecord): SchoolRecordChangeKind {
  if (
    fieldChanged(before.title, incoming.title)
    || fieldChanged(before.subject, incoming.subject)
    || fieldChanged(before.dueAt, incoming.dueAt, true)
    || fieldChanged(before.status, incoming.status)
    || fieldChanged(before.grade, incoming.grade)
    || fieldChanged(before.detail, incoming.detail)
    || fieldChanged(before.teacher, incoming.teacher)
    || fieldChanged(before.threadId, incoming.threadId)
    || (!clean(before.grade) && Boolean(clean(incoming.grade)))
  ) return "source_changed";

  for (const field of ["subject", "detail", "url", "dueAt", "status", "teacher", "threadId"] as const) {
    if (!clean(before[field]) && Boolean(clean(incoming[field]))) return "enriched";
  }
  return "unchanged";
}

function mergeRecord(before: ScrapedRecord, incoming: ScrapedRecord, canonicalId: string): ScrapedRecord {
  return {
    ...before,
    ...Object.fromEntries(Object.entries(incoming).filter(([, value]) => value !== undefined && value !== "")),
    sourceRecordId: canonicalId,
    kind: before.kind,
    title: clean(incoming.title) ?? before.title,
    ...(clean(incoming.subject) ?? clean(before.subject) ? { subject: clean(incoming.subject) ?? clean(before.subject) } : {}),
    ...(clean(incoming.detail) ?? clean(before.detail) ? { detail: clean(incoming.detail) ?? clean(before.detail) } : {}),
    ...(clean(incoming.url) ?? clean(before.url) ? { url: clean(incoming.url) ?? clean(before.url) } : {}),
    ...(clean(incoming.dueAt) ?? clean(before.dueAt) ? { dueAt: clean(incoming.dueAt) ?? clean(before.dueAt) } : {}),
    ...(clean(incoming.occurredAt) ?? clean(before.occurredAt) ? { occurredAt: clean(incoming.occurredAt) ?? clean(before.occurredAt) } : {}),
    ...(clean(incoming.status) ?? clean(before.status) ? { status: clean(incoming.status) ?? clean(before.status) } : {}),
    ...(clean(incoming.grade) ?? clean(before.grade) ? { grade: clean(incoming.grade) ?? clean(before.grade) } : {}),
    ...(clean(incoming.teacher) ?? clean(before.teacher) ? { teacher: clean(incoming.teacher) ?? clean(before.teacher) } : {}),
    ...(clean(incoming.threadId) ?? clean(before.threadId) ? { threadId: clean(incoming.threadId) ?? clean(before.threadId) } : {}),
  };
}

function legacySourceDetail(entity: CanonicalSchoolEntity): string | undefined {
  let detail = entity.record.detail ?? "";
  for (const attachment of entity.attachments) {
    const marker = `Attachment: ${attachment.fileName}\n`;
    const markerAt = detail.indexOf(marker);
    if (markerAt < 0) continue;
    const start = markerAt >= 2 && detail.slice(markerAt - 2, markerAt) === "\n\n"
      ? markerAt - 2
      : markerAt;
    const nextAttachment = detail.indexOf("\n\nAttachment: ", markerAt + marker.length);
    const end = nextAttachment < 0 ? detail.length : nextAttachment;
    detail = `${detail.slice(0, start)}${detail.slice(end)}`.trim();
  }
  return clean(detail);
}

function entityDetail(sourceDetail: string | undefined, attachments: CanonicalSchoolAttachment[]): string | undefined {
  const sections = [
    ...(sourceDetail ? [sourceDetail] : []),
    ...attachments.map((attachment) => `Attachment: ${attachment.fileName}\n${attachment.text ?? ""}`),
  ];
  return sections.length ? normalizedDetail(sections.join("\n\n")) : undefined;
}

function promotedNavigationUrls(origin: string, edges: NavigationEdgeObservation[]): Map<string, Set<string>> {
  const result = new Map<string, Set<string>>();
  for (const edge of edges) {
    if (!edge.payload.sourceRecordId || edge.payload.relationship !== "detail") continue;
    try {
      const absolute = canonicalSchoolUrl(new URL(edge.payload.toPath, origin).toString());
      if (!absolute) continue;
      const aliases = result.get(edge.payload.sourceRecordId) ?? new Set<string>();
      aliases.add(absolute);
      result.set(edge.payload.sourceRecordId, aliases);
    } catch {
      // Invalid browser evidence is ignored rather than weakening identity.
    }
  }
  return result;
}

function attachmentAlias(raw: string | undefined): string | undefined {
  const normalized = canonicalSchoolUrl(raw);
  return normalized ? `attachment:${normalized}` : undefined;
}

export function reconcileSchoolRecords(
  sourceKey: string,
  origin: string,
  incomingRecords: ScrapedRecord[],
  options: {
    file?: string;
    observedAt?: string;
    navigationEdges?: NavigationEdgeObservation[];
  } = {},
): ReconcileSchoolRecordsResult {
  const file = options.file ?? DEFAULT_SCHOOL_ENTITY_FILE;
  const now = options.observedAt ?? new Date().toISOString();
  const store = loadStore(file);
  const bucket = store.sources[sourceKey] ?? { entities: [] };
  const entities = bucket.entities.filter((entity) => entity.sourceKey === sourceKey);
  const promoted = promotedNavigationUrls(origin, options.navigationEdges ?? []);
  const baselineById = new Map<string, ScrapedRecord | null>();

  const aliasIndex = new Map<string, CanonicalSchoolEntity>();
  const rebuildIndex = () => {
    aliasIndex.clear();
    for (const entity of entities) for (const alias of entity.aliases) aliasIndex.set(alias, entity);
  };
  rebuildIndex();

  const orderedRecords = [...incomingRecords].sort((left, right) => {
    const leftMs = left.observedAt ? Date.parse(left.observedAt) : Number.NaN;
    const rightMs = right.observedAt ? Date.parse(right.observedAt) : Number.NaN;
    if (!Number.isFinite(leftMs) && !Number.isFinite(rightMs)) return 0;
    if (!Number.isFinite(leftMs)) return -1;
    if (!Number.isFinite(rightMs)) return 1;
    return leftMs - rightMs;
  });

  for (const incoming of orderedRecords) {
    const originalSourceId = incoming.sourceRecordId ?? incoming.platformId;
    const aliases = new Set<string>();
    const source = sourceAlias(incoming.kind, originalSourceId);
    if (source) aliases.add(source);
    const canonicalUrl = canonicalSchoolUrl(incoming.url);
    const promotedUrls = originalSourceId ? promoted.get(originalSourceId) ?? new Set<string>() : new Set<string>();
    const url = urlAlias(incoming.kind, canonicalUrl);
    if (url && (isStrongSchoolUrl(canonicalUrl) || promotedUrls.has(canonicalUrl ?? ""))) aliases.add(url);
    for (const promotedUrl of Array.from(promotedUrls)) {
      const alias = urlAlias(incoming.kind, promotedUrl);
      if (alias) aliases.add(alias);
    }

    const lookupAliases = new Set(aliases);
    // A weak URL is never allowed to create identity on its own. It may,
    // however, resolve to a URL that was already promoted by an observed
    // user navigation edge from a strongly identified record.
    if (url && aliasIndex.has(url)) lookupAliases.add(url);
    let entity = Array.from(lookupAliases).map((alias) => aliasIndex.get(alias)).find(Boolean);
    if (!entity) {
      const semantic = semanticSignature(incoming);
      if (semantic) {
        const matches = entities.filter((candidate) => candidate.kind === incoming.kind && semanticSignature(candidate.record) === semantic);
        if (matches.length === 1) entity = matches[0];
      }
    }

    if (!entity) {
      const seed = Array.from(aliases)[0] ?? semanticSignature(incoming) ?? `${incoming.kind}:${incoming.title}:${now}:${entities.length}`;
      const id = canonicalEntityId(sourceKey, incoming.kind, seed);
      entity = {
        id,
        sourceKey,
        kind: incoming.kind,
        record: { ...incoming, sourceRecordId: id },
        sourceDetail: clean(incoming.detail),
        aliases: Array.from(aliases),
        attachments: [],
        learnedAt: now,
        updatedAt: now,
      };
      entities.push(entity);
      baselineById.set(id, null);
    } else {
      if (!baselineById.has(entity.id)) baselineById.set(entity.id, { ...entity.record });
      entity.sourceDetail ??= legacySourceDetail(entity);
      entity.sourceDetail = clean(incoming.detail) ?? entity.sourceDetail;
      entity.record = mergeRecord(entity.record, incoming, entity.id);
      entity.record.detail = entityDetail(entity.sourceDetail, entity.attachments);
      entity.updatedAt = now;
      entity.aliases = Array.from(new Set(entity.aliases.concat(Array.from(aliases))));
    }
    rebuildIndex();
  }

  // A natural click from an already-identified academic record to a file is a
  // strong parent/attachment edge. Persist it so the later download completion
  // can be stitched even if the browser download API has no referrer.
  for (const edge of options.navigationEdges ?? []) {
    if (edge.payload.relationship !== "attachment") continue;
    let entity: CanonicalSchoolEntity | undefined;
    if (edge.payload.sourceRecordId) {
      for (const kind of ["assignment", "message", "grade", "submission", "deadline"] as ScrapedRecord["kind"][]) {
        const source = sourceAlias(kind, edge.payload.sourceRecordId);
        if (source && aliasIndex.has(source)) {
          entity = aliasIndex.get(source);
          break;
        }
      }
    }
    if (!entity) {
      try {
        const fromUrl = canonicalSchoolUrl(new URL(edge.payload.fromPath, origin).toString());
        entity = entities.find((candidate) => canonicalSchoolUrl(candidate.record.url) === fromUrl);
      } catch {
        entity = undefined;
      }
    }
    if (!entity) continue;
    try {
      const absolute = new URL(edge.payload.toPath, origin).toString();
      const alias = attachmentAlias(absolute);
      if (alias && !entity.aliases.includes(alias)) entity.aliases.push(alias);
    } catch {
      // Ignore malformed edge evidence.
    }
  }

  bucket.entities = entities;
  store.sources[sourceKey] = bucket;
  saveStore(store, file);

  const mutationById = new Map<string, SchoolRecordChangeKind>();
  for (const [id, baseline] of Array.from(baselineById.entries())) {
    const entity = entities.find((candidate) => candidate.id === id);
    if (!entity) continue;
    mutationById.set(id, baseline === null ? "new_entity" : classifyMerge(baseline, entity.record));
  }
  const touched = new Set(mutationById.keys());
  const records = entities
    .filter((entity) => touched.has(entity.id))
    .map((entity) => ({ ...entity.record, sourceRecordId: entity.id, changeKind: mutationById.get(entity.id) ?? "unchanged" }));
  return {
    records,
    mutations: records.map((record) => ({
      sourceRecordId: record.sourceRecordId!,
      changeKind: record.changeKind ?? "unchanged",
    })),
  };
}

export function enrichCanonicalEntityFromAttachment(
  sourceKey: string,
  origin: string,
  observation: AttachmentDownloadObservation,
  extraction: SchoolAttachmentExtraction,
  file = DEFAULT_SCHOOL_ENTITY_FILE,
): ScrapedRecord | null {
  if (!extraction.ok) return null;
  const store = loadStore(file);
  const bucket = store.sources[sourceKey];
  if (!bucket) return null;

  let sourceUrl: string | undefined;
  let sourcePageUrl: string | undefined;
  try {
    if (observation.payload.sourceUrlPath) sourceUrl = new URL(observation.payload.sourceUrlPath, origin).toString();
    if (observation.payload.sourcePagePath) sourcePageUrl = new URL(observation.payload.sourcePagePath, origin).toString();
  } catch {
    return null;
  }
  const fileAlias = attachmentAlias(sourceUrl);
  const pageUrl = canonicalSchoolUrl(sourcePageUrl);
  const candidates = bucket.entities.filter((entity) =>
    (fileAlias ? entity.aliases.includes(fileAlias) : false)
    || (pageUrl ? canonicalSchoolUrl(entity.record.url) === pageUrl : false),
  );
  if (candidates.length !== 1) return null;
  const entity = candidates[0];
  if (entity.attachments.some((attachment) => attachment.id === extraction.sha256)) {
    return { ...entity.record, sourceRecordId: entity.id, changeKind: "unchanged" };
  }

  entity.sourceDetail ??= legacySourceDetail(entity);
  const canonicalFileUrl = canonicalSchoolUrl(sourceUrl);
  entity.attachments = entity.attachments.filter((attachment) => {
    const existingUrl = canonicalSchoolUrl(attachment.sourceUrl);
    const sameUrl = canonicalFileUrl && existingUrl && canonicalFileUrl === existingUrl;
    const sameFallbackName = (!canonicalFileUrl || !existingUrl)
      && attachment.fileName.trim().toLowerCase() === observation.payload.fileName.trim().toLowerCase();
    return !sameUrl && !sameFallbackName;
  });
  entity.attachments.push({
    id: extraction.sha256,
    fileName: observation.payload.fileName,
    ...(sourceUrl ? { sourceUrl } : {}),
    ...(observation.payload.mimeType ? { mimeType: observation.payload.mimeType } : {}),
    sizeBytes: extraction.bytes,
    text: extraction.text,
    observedAt: observation.observedAt,
  });
  entity.record = {
    ...entity.record,
    detail: entityDetail(entity.sourceDetail, entity.attachments),
    sourceRecordId: entity.id,
  };
  entity.updatedAt = observation.observedAt;
  saveStore(store, file);
  return { ...entity.record, sourceRecordId: entity.id, changeKind: "enriched" };
}

function normalizedDetail(value: string): string {
  return value.replace(/\n{3,}/g, "\n\n").trim().slice(0, 16_000);
}

export function loadCanonicalSchoolEntities(sourceKey: string, file = DEFAULT_SCHOOL_ENTITY_FILE): CanonicalSchoolEntity[] {
  return loadStore(file).sources[sourceKey]?.entities ?? [];
}

export function updateCanonicalSchoolEntity(
  sourceKey: string,
  entity: CanonicalSchoolEntity,
  file = DEFAULT_SCHOOL_ENTITY_FILE,
): void {
  const store = loadStore(file);
  const bucket = store.sources[sourceKey] ?? { entities: [] };
  const index = bucket.entities.findIndex((candidate) => candidate.id === entity.id);
  if (index === -1) bucket.entities.push(entity);
  else bucket.entities[index] = entity;
  store.sources[sourceKey] = bucket;
  saveStore(store, file);
}
