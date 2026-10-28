import { createHash } from "node:crypto";
import { normalizeNavigableUrl, safeNavigableUrl } from "@/lib/security/untrustedContent";
import { normalizeContentIntegrity, type ContentIntegritySummary } from "@/lib/security/contentIntegrity";
import { redis } from "@/lib/redis";

export const DISPATCH_RECORD_KINDS = [
  "assignment",
  "message",
  "grade",
  "submission",
  "deadline",
] as const;

export type DispatchRecordKind = (typeof DISPATCH_RECORD_KINDS)[number];

export type DispatchRecord = {
  id: string;
  kind: DispatchRecordKind;
  title: string;
  source: string;
  subject?: string;
  detail?: string;
  url?: string;
  dueAt?: string;
  occurredAt?: string;
  status?: string;
  grade?: string;
  teacher?: string;
  threadId?: string;
  urgency?: "low" | "medium" | "high";
  /** Deterministic 0–100 message relevance. Derived metadata, not academic content. */
  importanceScore?: number;
  /** Machine-readable scorer signals; bounded and sanitized by parseDispatchRecords. */
  importanceReasons?: string[];
  /** Bounded evidence that source content may be trying to manipulate an AI reader. */
  contentIntegrity?: ContentIntegritySummary;
  updatedAt: string;
  /** Server-maintained: bumped each time the record's academic content changes.
   *  Never accepted from clients — parseDispatchRecords does not copy it. */
  revision?: number;
};

export type DispatchConnection = "not_connected" | "waiting" | "connected";

export type DispatchState = {
  connection: DispatchConnection;
  /** Sticky server-owned history bit. Once a phone/school connection has
   *  reached `connected`, later disconnects must not look like first setup. */
  hasConnectedBefore: boolean;
  macOnline: boolean;
  phonePaired: boolean;
  macName: string | null;
  source: string | null;
  lastSeenAt: string | null;
  lastSyncAt: string | null;
  lastSyncError: string | null;
  counts: Record<DispatchRecordKind, number>;
};

export type DispatchSnapshot = {
  state: DispatchState;
  records: DispatchRecord[];
};

export type DispatchEvent =
  | "mac_online"
  | "mac_offline"
  | "phone_paired"
  | "phone_unpaired"
  | "sync_started"
  | "sync_completed"
  | "sync_error";

/** A real change to school reality, computed by the server against stored state. */
export type DispatchMutation = {
  /** Same for every retry of one change; different for every real change,
   *  including a revert to earlier content. */
  mutationId: string;
  change: "added" | "changed";
  before?: DispatchRecord;
  after: DispatchRecord;
};

const MAX_RECORDS = 500;
const MAX_BATCH = 200;
const CAS_ATTEMPTS = 5;
const stateKey = (userId: string) => `dispatch:${userId}:state`;
const recordsKey = (userId: string) => `dispatch:${userId}:records`;
const stateVersionKey = (userId: string) => `dispatch:${userId}:state:v`;
const recordsVersionKey = (userId: string) => `dispatch:${userId}:records:v`;

type DispatchRedisClient = {
  mget: (...keys: string[]) => Promise<unknown[]>;
  eval: (script: string, keys: string[], args: string[]) => Promise<unknown>;
  del: (...keys: string[]) => Promise<unknown>;
};

let redisOverride: DispatchRedisClient | null = null;

/** Test-only: swap the Redis client for an in-memory CAS store. */
export function _setDispatchRedisForTests(client: DispatchRedisClient | null): void {
  redisOverride = client;
}

function db(): DispatchRedisClient {
  return redisOverride ?? (redis() as unknown as DispatchRedisClient);
}

// Compare-and-set: write only if nobody else wrote since our read. The JSON
// merge logic stays in TypeScript; Lua only guards the version.
const CAS_SET_SCRIPT = `
local version = redis.call("GET", KEYS[2]) or "0"
if version ~= ARGV[1] then return 0 end
redis.call("SET", KEYS[1], ARGV[2])
redis.call("SET", KEYS[2], tostring(tonumber(version) + 1))
return 1
`;

// Records and connection state must move together. A records write that then
// loses the follow-up state CAS used to leave lastSyncAt / counts behind.
const CAS_SET_PAIR_SCRIPT = `
local recordsVersion = redis.call("GET", KEYS[2]) or "0"
local stateVersion = redis.call("GET", KEYS[4]) or "0"
if recordsVersion ~= ARGV[1] or stateVersion ~= ARGV[2] then return 0 end
redis.call("SET", KEYS[1], ARGV[3])
redis.call("SET", KEYS[2], tostring(tonumber(recordsVersion) + 1))
redis.call("SET", KEYS[3], ARGV[4])
redis.call("SET", KEYS[4], tostring(tonumber(stateVersion) + 1))
return 1
`;

function emptyCounts(): Record<DispatchRecordKind, number> {
  return {
    assignment: 0,
    message: 0,
    grade: 0,
    submission: 0,
    deadline: 0,
  };
}

function defaultState(): DispatchState {
  return {
    connection: "not_connected",
    hasConnectedBefore: false,
    macOnline: false,
    phonePaired: false,
    macName: null,
    source: null,
    lastSeenAt: null,
    lastSyncAt: null,
    lastSyncError: null,
    counts: emptyCounts(),
  };
}

function parseStored<T>(value: unknown): T | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "object") return value as T;
  if (typeof value !== "string") return null;
  try {
    return JSON.parse(value) as T;
  } catch {
    return null;
  }
}

function parseState(raw: unknown): DispatchState {
  const stored = parseStored<Partial<DispatchState>>(raw);
  const state = { ...defaultState(), ...(stored ?? {}) };
  // Older stored states predate the sticky history bit. A completed sync,
  // known school source, or a currently-connected state is sufficient proof
  // that this is not first setup. Avoid lastSeenAt/macName: a Mac can be seen
  // before the phone has ever completed school setup.
  const hasConnectedBefore = stored?.hasConnectedBefore === true
    || stored?.connection === "connected"
    || Boolean(stored?.lastSyncAt || stored?.source);
  return {
    ...state,
    hasConnectedBefore,
    counts: { ...emptyCounts(), ...(stored?.counts ?? {}) },
  };
}

function parseRecords(raw: unknown): DispatchRecord[] {
  const stored = parseStored<unknown>(raw);
  if (!Array.isArray(stored)) return [];
  return stored.filter((record): record is DispatchRecord => {
    if (!record || typeof record !== "object") return false;
    const item = record as Partial<DispatchRecord>;
    return typeof item.id === "string" && typeof item.kind === "string" && typeof item.title === "string";
  });
}

async function readVersioned(key: string, versionKey: string): Promise<{ raw: unknown; version: string }> {
  const [raw, version] = await db().mget(key, versionKey);
  return { raw, version: String(version ?? 0) };
}

async function readDispatchBundle(userId: string): Promise<{
  recordsRaw: unknown;
  recordsVersion: string;
  stateRaw: unknown;
  stateVersion: string;
}> {
  const [recordsRaw, recordsVersion, stateRaw, stateVersion] = await db().mget(
    recordsKey(userId),
    recordsVersionKey(userId),
    stateKey(userId),
    stateVersionKey(userId),
  );
  return {
    recordsRaw,
    recordsVersion: String(recordsVersion ?? 0),
    stateRaw,
    stateVersion: String(stateVersion ?? 0),
  };
}

async function casSet(key: string, versionKey: string, version: string, value: string): Promise<boolean> {
  return Number(await db().eval(CAS_SET_SCRIPT, [key, versionKey], [version, value])) === 1;
}

async function casSetPair(
  userId: string,
  recordsVersion: string,
  stateVersion: string,
  recordsJson: string,
  stateJson: string,
): Promise<boolean> {
  return Number(await db().eval(
    CAS_SET_PAIR_SCRIPT,
    [recordsKey(userId), recordsVersionKey(userId), stateKey(userId), stateVersionKey(userId)],
    [recordsVersion, stateVersion, recordsJson, stateJson],
  )) === 1;
}

function applyDispatchEvent(
  state: DispatchState,
  event: DispatchEvent,
  details: { macName?: string; source?: string } = {},
  now: string,
): DispatchState {
  if (details.macName) state.macName = details.macName.slice(0, 120);
  if (details.source) state.source = details.source.slice(0, 80);
  state.lastSeenAt = now;

  switch (event) {
    case "mac_online":
      state.macOnline = true;
      break;
    case "mac_offline":
      state.macOnline = false;
      state.phonePaired = false;
      break;
    case "phone_paired":
      // ponytail: phonePaired only. macOnline must come from the Mac's own
      // mac_online event — a phone tapping "connect" is not proof the Mac
      // app is actually running, and faking it here made SC-02 show a
      // fabricated "connected"/"waiting" status with no real handshake.
      state.phonePaired = true;
      break;
    case "phone_unpaired":
      state.phonePaired = false;
      break;
    case "sync_started":
      state.lastSyncError = null;
      break;
    case "sync_completed":
      state.lastSyncAt = now;
      state.lastSyncError = null;
      break;
    case "sync_error":
      state.lastSyncError = "The computer could not finish the last sync.";
      break;
  }

  state.connection = state.macOnline && state.phonePaired ? "connected" : state.macOnline ? "waiting" : "not_connected";
  if (state.connection === "connected") state.hasConnectedBefore = true;
  return state;
}

function countRecords(records: DispatchRecord[]): Record<DispatchRecordKind, number> {
  const counts = emptyCounts();
  for (const record of records) counts[record.kind] += 1;
  return counts;
}

export function normalizeText(value: string | undefined): string {
  if (!value) return "";
  return value.replace(/\s+/g, " ").trim().toLowerCase();
}

function normalizeInstant(value: string | undefined): string {
  if (!value) return "";
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? String(ms) : normalizeText(value);
}

/**
 * The fields that carry academic meaning. Excludes `updatedAt` (when we last
 * saw the record, not what it says) and `revision` (derived from this).
 */
export function dispatchContentFingerprint(record: DispatchRecord): string {
  const parts = [
    record.kind,
    normalizeText(record.title),
    normalizeText(record.subject),
    normalizeText(record.detail),
    normalizeInstant(record.dueAt),
    normalizeText(record.status),
    normalizeText(record.grade),
  ];
  if (record.kind === "assignment" && record.url) parts.push(`url:${normalizeNavigableUrl(record.url)}`);
  // Optional fields are omitted when absent so older records keep the same
  // fingerprint until a teacher/thread actually appears.
  if (record.teacher) parts.push(`teacher:${normalizeText(record.teacher)}`);
  if (record.threadId) parts.push(`thread:${normalizeText(record.threadId)}`);
  if (record.contentIntegrity) {
    parts.push(`integrity:${record.contentIntegrity.risk}:${record.contentIntegrity.score}:${record.contentIntegrity.reasons.join(",")}`);
  }
  return parts.join(" ");
}

/**
 * Identity of one revision of one record. The content hash keeps a record that
 * is removed and later re-added with different content (revision restarts at 1)
 * from colliding with its earlier history.
 * ponytail: identical content re-added after removal reuses the old id and is
 * deduped; add removal tombstones if that ever needs to count as new work.
 */
export function dispatchMutationId(record: DispatchRecord): string {
  const hash = createHash("sha256").update(dispatchContentFingerprint(record)).digest("hex").slice(0, 16);
  return `${record.source}:${record.id}:r${record.revision ?? 1}:${hash}`;
}

function validOptionalDate(value: unknown, preserveCalendarDate = false): string | undefined {
  if (typeof value !== "string" || !value.trim()) return undefined;
  const trimmed = value.trim();
  const date = new Date(trimmed);
  if (Number.isNaN(date.getTime())) return undefined;
  // dueAt carries a school deadline's local calendar date. Converting an
  // offset timestamp to UTC can move it to the previous/next day and make the
  // phone classify a valid deadline as overdue. Preserve the validated source
  // representation for due dates; storage timestamps still normalize to UTC.
  return preserveCalendarDate ? trimmed : date.toISOString();
}

function validString(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, maxLength) : undefined;
}

/**
 * Accepts only the small, normalized school-data envelope that Dispatch needs.
 * Credentials, cookies, screenshots, and arbitrary portal HTML are intentionally
 * not part of this contract.
 */
export function parseDispatchRecords(value: unknown): DispatchRecord[] | null {
  if (!Array.isArray(value) || value.length > MAX_BATCH) return null;

  const records: DispatchRecord[] = [];
  for (const item of value) {
    if (!item || typeof item !== "object") return null;
    const input = item as Record<string, unknown>;
    const id = validString(input.id, 160);
    const title = validString(input.title, 240);
    const source = validString(input.source, 80);
    const kind = input.kind;
    if (!id || !title || !source || !DISPATCH_RECORD_KINDS.includes(kind as DispatchRecordKind)) return null;

    const record: DispatchRecord = {
      id,
      kind: kind as DispatchRecordKind,
      title,
      source,
      updatedAt: validOptionalDate(input.updatedAt) ?? new Date().toISOString(),
    };

    const optionalFields: Array<[
      "subject" | "detail" | "status" | "grade" | "teacher" | "threadId",
      number,
    ]> = [
      ["subject", 120],
      ["detail", 16000],
      ["status", 80],
      ["grade", 40],
      ["teacher", 180],
      ["threadId", 160],
    ];
    for (const [field, maxLength] of optionalFields) {
      const parsed = validString(input[field], maxLength);
      if (parsed) record[field] = parsed;
    }
    const safeUrl = safeNavigableUrl(input.url, 500);
    if (safeUrl) record.url = safeUrl;

    const dueAt = validOptionalDate(input.dueAt, true);
    const occurredAt = validOptionalDate(input.occurredAt);
    if (dueAt) record.dueAt = dueAt;
    if (occurredAt) record.occurredAt = occurredAt;

    if (input.urgency === "low" || input.urgency === "medium" || input.urgency === "high") {
      record.urgency = input.urgency;
    }
    if (typeof input.importanceScore === "number" && Number.isFinite(input.importanceScore)) {
      record.importanceScore = Math.max(0, Math.min(100, Math.round(input.importanceScore)));
    }
    if (Array.isArray(input.importanceReasons)) {
      const reasons = input.importanceReasons
        .filter((value): value is string => typeof value === "string")
        .map((value) => value.trim())
        .filter(Boolean)
        .slice(0, 12)
        .map((value) => value.slice(0, 64));
      if (reasons.length > 0) record.importanceReasons = Array.from(new Set(reasons));
    }
    const contentIntegrity = normalizeContentIntegrity(input.contentIntegrity);
    if (contentIntegrity) record.contentIntegrity = contentIntegrity;
    records.push(record);
  }

  return records;
}

/**
 * Pure: folds incoming records into stored ones and reports what really changed.
 *
 * The server decides added/changed by comparing content against what it holds,
 * never by trusting the client's own delta classification. Re-sending the same
 * payload (a retry after a lost response) yields zero mutations.
 */
export function mergeDispatchRecords(
  current: DispatchRecord[],
  incoming: DispatchRecord[],
  options: { replaceSource?: string; removeIds?: string[] } = {},
): { next: DispatchRecord[]; mutations: DispatchMutation[] } {
  // Kind is part of identity: LMSs number assignments and messages in separate
  // id spaces, so `managebac:1` alone can name two unrelated school objects.
  const keyOf = (record: DispatchRecord) => `${record.source}:${record.kind}:${record.id}`;
  const removeIds = new Set(options.removeIds ?? []);
  // Revisions continue from the full stored set, so a record re-sent through
  // replaceSource/removeIds in the same batch keeps its history.
  const storedByKey = new Map(current.map((record) => [keyOf(record), record]));
  const retained = (options.replaceSource
    ? current.filter((record) => record.source !== options.replaceSource)
    : current
  ).filter((record) => !removeIds.has(record.id));
  const byKey = new Map(retained.map((record) => [keyOf(record), record]));
  const mutations: DispatchMutation[] = [];

  // Passive school records are progressively enriched as the student moves from
  // a list to detail pages and attachments. A sparse later observation must
  // never erase fields we already learned from the same canonical item, and an
  // explicitly-undefined key counts as absent rather than as a cleared field.
  const enrich = (previous: DispatchRecord, record: DispatchRecord): DispatchRecord => ({
    ...previous,
    ...Object.fromEntries(Object.entries(record).filter(([, value]) => value !== undefined)),
  });

  // One upload describes one observed reality, so fold repeats of a record
  // within the batch before comparing. Otherwise a batch that contradicts
  // itself would report two changes and never settle across retries.
  const observed = new Map<string, DispatchRecord>();
  for (const record of incoming) {
    const key = keyOf(record);
    const earlier = observed.get(key);
    observed.set(key, earlier ? enrich(earlier, record) : { ...record });
  }

  for (const [key, record] of Array.from(observed.entries())) {
    const previous = byKey.get(key) ?? storedByKey.get(key);
    const merged: DispatchRecord = previous ? enrich(previous, record) : { ...record };
    const unchanged = previous !== undefined
      && dispatchContentFingerprint(previous) === dispatchContentFingerprint(merged);
    merged.revision = unchanged ? (previous.revision ?? 1) : (previous?.revision ?? 0) + 1;
    if (!unchanged) {
      mutations.push({
        mutationId: dispatchMutationId(merged),
        change: previous ? "changed" : "added",
        ...(previous ? { before: previous } : {}),
        after: merged,
      });
    }
    byKey.set(key, merged);
  }

  const next = Array.from(byKey.values())
    .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    .slice(0, MAX_RECORDS);
  return { next, mutations };
}

export async function getDispatchSnapshot(userId: string): Promise<DispatchSnapshot> {
  const [rawState, rawRecords] = await db().mget(stateKey(userId), recordsKey(userId));
  const records = parseRecords(rawRecords);
  // Counts are derived on read; writing them back here raced every other writer.
  return { state: { ...parseState(rawState), counts: countRecords(records) }, records };
}

export async function recordDispatchEvent(
  userId: string,
  event: DispatchEvent,
  details: { macName?: string; source?: string } = {},
): Promise<DispatchState> {
  for (let attempt = 0; attempt < CAS_ATTEMPTS; attempt += 1) {
    const { raw, version } = await readVersioned(stateKey(userId), stateVersionKey(userId));
    const state = applyDispatchEvent(parseState(raw), event, details, new Date().toISOString());
    if (await casSet(stateKey(userId), stateVersionKey(userId), version, JSON.stringify(state))) return state;
  }
  throw new Error("Dispatch state kept changing concurrently; retry.");
}

export async function saveDispatchRecords(
  userId: string,
  records: DispatchRecord[],
  options: {
    replaceSource?: string;
    removeIds?: string[];
    /** Runs before the write, on every attempt. It must be idempotent per
     *  mutationId. If it throws, nothing is written and a retry recomputes the
     *  same mutation ids — so history can't be lost behind already-saved state. */
    beforeCommit?: (mutations: DispatchMutation[]) => Promise<void>;
  } = {},
): Promise<DispatchSnapshot> {
  for (let attempt = 0; attempt < CAS_ATTEMPTS; attempt += 1) {
    const bundle = await readDispatchBundle(userId);
    const { next, mutations } = mergeDispatchRecords(parseRecords(bundle.recordsRaw), records, options);
    if (options.beforeCommit) await options.beforeCommit(mutations);
    const state = applyDispatchEvent(
      parseState(bundle.stateRaw),
      "sync_completed",
      { source: options.replaceSource },
      new Date().toISOString(),
    );
    if (await casSetPair(userId, bundle.recordsVersion, bundle.stateVersion, JSON.stringify(next), JSON.stringify(state))) {
      return getDispatchSnapshot(userId);
    }
  }
  throw new Error("Dispatch records kept changing concurrently; retry.");
}

/** Account deletion: removes every Dispatch key for the user. */
export async function deleteDispatchData(userId: string): Promise<void> {
  await db().del(stateKey(userId), recordsKey(userId), stateVersionKey(userId), recordsVersionKey(userId));
}
