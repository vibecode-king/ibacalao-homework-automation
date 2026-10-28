// lib/school/journal.ts
// The durable local evidence journal.
//
// Captures currently live in an append-only NDJSON ring written by the native
// host. That file cannot express "this evidence was consumed" or "this upload
// was acknowledged", so the daemon cannot prove it never dropped a capture.
// SQLite gives us transactional claims and checkpoints to build that on.
//
// This is shadow mode: NDJSON remains the source of truth until a journal
// read succeeds, at which point extraction prefers the checkpointed rows so
// ACK lineage can be tested without a live LMS.
//
// What must never be written here: passwords, cookies, session secrets, auth
// tokens, or the account credential. Only sanitized academic evidence, under
// the same 0700 directory / 0600 file rules as the rest of ~/.ibacalao/school.

import { createHash } from "node:crypto";
import { chmodSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { readRecentCaptures, type RecentCaptureOptions } from "./evidence";
import { ensurePlatformGraphSchema } from "./platformGraph";
import type { SchoolCaptureEvent } from "./types";

export const DEFAULT_SCHOOL_JOURNAL_FILE = join(homedir(), ".ibacalao", "school", "school.db");

/** Matches the NDJSON ring: evidence older than this is not replayed. */
const CAPTURE_RETENTION_MS = 24 * 60 * 60 * 1000;

export type JournalCapture = SchoolCaptureEvent & {
  receivedAt?: string;
  /** Assigned by the extension; the local idempotency key end to end. */
  captureEventId?: string;
};

export type JournalReadOptions = {
  sourceKey: string;
  origin: string;
  nowMs?: number;
};

const MIGRATIONS: string[] = [
  `CREATE TABLE captures (
     seq                INTEGER PRIMARY KEY AUTOINCREMENT,
     capture_event_id   TEXT NOT NULL UNIQUE,
     source_key         TEXT NOT NULL,
     origin             TEXT NOT NULL,
     origin_fingerprint TEXT NOT NULL,
     capture_type       TEXT NOT NULL,
     observed_at        TEXT NOT NULL,
     received_at        TEXT,
     envelope_json      TEXT NOT NULL,
     consumed_at        TEXT,
     created_at         TEXT NOT NULL
   );
   CREATE INDEX captures_source_observed ON captures (source_key, observed_at);`,

  // Delivery lineage: one row per upload attempt, joined to the exact evidence
  // it carried, so "was this capture ever acknowledged by the server?" becomes
  // a query instead of an assumption.
  `ALTER TABLE captures ADD COLUMN claimed_at TEXT;
   ALTER TABLE captures ADD COLUMN sync_attempt_id TEXT;
   CREATE TABLE sync_attempts (
     sync_attempt_id      TEXT PRIMARY KEY,
     source_key           TEXT NOT NULL,
     sync_mode            TEXT NOT NULL,
     state                TEXT NOT NULL,
     request_hash         TEXT,
     attempt_count        INTEGER NOT NULL DEFAULT 0,
     created_at           TEXT NOT NULL,
     last_attempt_at      TEXT,
     extract_succeeded_at TEXT,
     reconciled_at        TEXT,
     upload_started_at    TEXT,
     acked_at             TEXT,
     last_error           TEXT,
     server_ack_json      TEXT
   );
   CREATE TABLE sync_attempt_captures (
     sync_attempt_id  TEXT NOT NULL REFERENCES sync_attempts (sync_attempt_id) ON DELETE CASCADE,
     capture_event_id TEXT NOT NULL REFERENCES captures (capture_event_id) ON DELETE CASCADE,
     PRIMARY KEY (sync_attempt_id, capture_event_id)
   );
   CREATE INDEX sync_attempts_source_state ON sync_attempts (source_key, state);`,
];

/**
 * A damaged journal must never look like an empty one: an empty school reads as
 * "no work due", which is the most dangerous wrong answer this system can give.
 */
export class SchoolJournalCorruptError extends Error {
  constructor(file: string, cause: unknown) {
    super(`school_journal_corrupt:${file}`);
    this.name = "SchoolJournalCorruptError";
    this.cause = cause;
  }
}

export function openSchoolJournal(file = DEFAULT_SCHOOL_JOURNAL_FILE): DatabaseSync {
  mkdirSync(dirname(file), { recursive: true, mode: 0o700 });
  let db: DatabaseSync;
  try {
    db = new DatabaseSync(file);
    // Durability over throughput: this journal sees a handful of writes per
    // browsing session, and losing one capture costs more than an fsync.
    db.exec("PRAGMA journal_mode = WAL");
    db.exec("PRAGMA synchronous = FULL");
    db.exec("PRAGMA foreign_keys = ON");
    db.exec("PRAGMA busy_timeout = 5000");
    migrate(db);
  } catch (error) {
    throw new SchoolJournalCorruptError(file, error);
  }
  try {
    chmodSync(file, 0o600);
  } catch {
    // A journal we cannot lock down is still better than losing evidence; the
    // directory is already 0700.
  }
  return db;
}

function migrate(db: DatabaseSync): void {
  db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)");
  const applied = db.prepare("SELECT MAX(version) AS version FROM schema_migrations").get() as { version: number | null };
  const current = applied?.version ?? 0;
  for (let version = current + 1; version <= MIGRATIONS.length; version += 1) {
    db.exec("BEGIN IMMEDIATE");
    try {
      db.exec(MIGRATIONS[version - 1]);
      db.prepare("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)")
        .run(version, new Date().toISOString());
      db.exec("COMMIT");
    } catch (error) {
      db.exec("ROLLBACK");
      throw error;
    }
  }
}

/** Older captures predate extension-assigned ids; content identifies them. */
function captureEventId(capture: JournalCapture): string {
  if (typeof capture.captureEventId === "string" && capture.captureEventId.trim()) return capture.captureEventId;
  return `sha256:${createHash("sha256").update(JSON.stringify(capture)).digest("hex").slice(0, 32)}`;
}

/**
 * Mirrors captures into the journal. Re-mirroring the same evidence is a no-op,
 * so the daemon can call this every poll without growing the journal.
 * Returns how many rows were new.
 */
export function recordJournalCaptures(db: DatabaseSync, captures: JournalCapture[]): number {
  if (captures.length === 0) return 0;
  const insert = db.prepare(
    `INSERT INTO captures (
       capture_event_id, source_key, origin, origin_fingerprint,
       capture_type, observed_at, received_at, envelope_json, created_at
     ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (capture_event_id) DO NOTHING`,
  );
  const now = new Date().toISOString();
  let inserted = 0;
  db.exec("BEGIN IMMEDIATE");
  try {
    for (const capture of captures) {
      const result = insert.run(
        captureEventId(capture),
        capture.sourceKey,
        capture.origin,
        capture.originFingerprint,
        capture.payload?.kind ?? "unknown",
        capture.observedAt,
        capture.receivedAt ?? null,
        JSON.stringify(capture),
        now,
      );
      inserted += Number(result.changes);
    }
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
  return inserted;
}

/**
 * Shadow write: mirrors the NDJSON ring into the journal for one source.
 *
 * Best effort on purpose. While NDJSON is the source of truth, a journal
 * failure must never cost the student an extraction, so this reports the
 * problem and gets out of the way. That changes the day the daemon starts
 * reading from here instead.
 */
export function mirrorCapturesToJournal(
  captureFile: string,
  options: RecentCaptureOptions,
  journalFile?: string,
): { mirrored: number } | null {
  if (!journalFile) return null;
  let db: DatabaseSync | null = null;
  try {
    // The passive loop polls every couple of seconds and is usually idle, so
    // don't open (or create) the database until there is evidence to store.
    const captures = readRecentCaptures(captureFile, options);
    if (captures.length === 0) return { mirrored: 0 };
    db = openSchoolJournal(journalFile);
    ensurePlatformGraphSchema(db);
    return { mirrored: recordJournalCaptures(db, captures) };
  } catch (error) {
    console.warn("[school] capture journal shadow write failed:", error instanceof Error ? error.message : error);
    return null;
  } finally {
    db?.close();
  }
}

/**
 * Reads back exactly what the NDJSON reader would return for the same source:
 * same origin/fingerprint checks, same retention window, same observed-at order.
 * Shadow mode depends on that equivalence being testable.
 */
export function readJournalCaptures(db: DatabaseSync, options: JournalReadOptions): JournalCapture[] {
  const nowMs = options.nowMs ?? Date.now();
  const expectedFingerprint = createHash("sha256").update(options.origin).digest("hex").slice(0, 32);
  if (options.sourceKey.startsWith("portal:") && options.sourceKey !== `portal:${expectedFingerprint}`) return [];

  const rows = db.prepare(
    `SELECT envelope_json FROM captures
      WHERE source_key = ? AND origin = ? AND origin_fingerprint = ?
      ORDER BY observed_at ASC, seq ASC`,
  ).all(options.sourceKey, options.origin, expectedFingerprint) as Array<{ envelope_json: string }>;

  const captures: JournalCapture[] = [];
  for (const row of rows) {
    let capture: JournalCapture;
    try {
      capture = JSON.parse(row.envelope_json) as JournalCapture;
    } catch {
      continue;
    }
    const observedMs = Date.parse(capture.observedAt);
    const receivedMs = capture.receivedAt ? Date.parse(capture.receivedAt) : observedMs;
    if (!Number.isFinite(observedMs) || !Number.isFinite(receivedMs)) continue;
    if (nowMs - receivedMs < 0 || nowMs - receivedMs > CAPTURE_RETENTION_MS) continue;
    captures.push(capture);
  }
  return captures.sort((left, right) => Date.parse(left.observedAt) - Date.parse(right.observedAt));
}

// ---------------------------------------------------------------------------
// Delivery lineage
//
// `captureEventId` only proves the browser handed evidence to the native host.
// It says nothing about whether that evidence was extracted, uploaded, or
// actually acknowledged by the server. A sync attempt carries that story: it
// names the exact captures it included and records when each stage happened,
// so a crash at any point leaves the evidence claimable again rather than
// silently gone.
// ---------------------------------------------------------------------------

export type SyncAttemptState = "queued" | "sending" | "acked" | "failed_retryable" | "blocked_auth";

export type SyncAttempt = {
  syncAttemptId: string;
  sourceKey: string;
  syncMode: string;
  state: SyncAttemptState;
  requestHash: string | null;
  attemptCount: number;
  createdAt: string;
  lastAttemptAt: string | null;
  extractSucceededAt: string | null;
  reconciledAt: string | null;
  uploadStartedAt: string | null;
  ackedAt: string | null;
  lastError: string | null;
};

type SyncAttemptRow = {
  sync_attempt_id: string;
  source_key: string;
  sync_mode: string;
  state: string;
  request_hash: string | null;
  attempt_count: number;
  created_at: string;
  last_attempt_at: string | null;
  extract_succeeded_at: string | null;
  reconciled_at: string | null;
  upload_started_at: string | null;
  acked_at: string | null;
  last_error: string | null;
};

function toSyncAttempt(row: SyncAttemptRow): SyncAttempt {
  return {
    syncAttemptId: row.sync_attempt_id,
    sourceKey: row.source_key,
    syncMode: row.sync_mode,
    state: row.state as SyncAttemptState,
    requestHash: row.request_hash,
    attemptCount: row.attempt_count,
    createdAt: row.created_at,
    lastAttemptAt: row.last_attempt_at,
    extractSucceededAt: row.extract_succeeded_at,
    reconciledAt: row.reconciled_at,
    uploadStartedAt: row.upload_started_at,
    ackedAt: row.acked_at,
    lastError: row.last_error,
  };
}

/**
 * Claims every unacknowledged capture for a source into one new sync attempt.
 *
 * Claiming is a transaction, so two daemons (or a daemon racing its own
 * restart) cannot carry the same evidence in two live attempts. Nothing is
 * deleted here — a claim is a lease, and it is released again by
 * `failSyncAttempt` or by `recoverStaleSyncAttempts` after a crash.
 */
export function claimCapturesForSync(
  db: DatabaseSync,
  options: { sourceKey: string; syncMode: string; syncAttemptId: string; now?: string },
): { attempt: SyncAttempt; captures: JournalCapture[] } | null {
  const now = options.now ?? new Date().toISOString();
  db.exec("BEGIN IMMEDIATE");
  try {
    const rows = db.prepare(
      `SELECT capture_event_id, envelope_json FROM captures
        WHERE source_key = ? AND consumed_at IS NULL AND claimed_at IS NULL
        ORDER BY observed_at ASC, seq ASC`,
    ).all(options.sourceKey) as Array<{ capture_event_id: string; envelope_json: string }>;

    if (rows.length === 0) {
      db.exec("COMMIT");
      return null;
    }

    // Identifies a retry carrying identical evidence, so the server's own
    // idempotency and ours agree on what "the same upload" means.
    const requestHash = createHash("sha256")
      .update(rows.map((row) => row.capture_event_id).sort().join("\u0000"))
      .digest("hex")
      .slice(0, 32);

    db.prepare(
      `INSERT INTO sync_attempts (
         sync_attempt_id, source_key, sync_mode, state, request_hash, attempt_count, created_at, last_attempt_at
       ) VALUES (?, ?, ?, 'sending', ?, 1, ?, ?)`,
    ).run(options.syncAttemptId, options.sourceKey, options.syncMode, requestHash, now, now);

    const link = db.prepare(
      "INSERT INTO sync_attempt_captures (sync_attempt_id, capture_event_id) VALUES (?, ?)",
    );
    const claim = db.prepare(
      "UPDATE captures SET claimed_at = ?, sync_attempt_id = ? WHERE capture_event_id = ?",
    );
    for (const row of rows) {
      link.run(options.syncAttemptId, row.capture_event_id);
      claim.run(now, options.syncAttemptId, row.capture_event_id);
    }

    const attempt = toSyncAttempt(
      db.prepare("SELECT * FROM sync_attempts WHERE sync_attempt_id = ?").get(options.syncAttemptId) as SyncAttemptRow,
    );
    db.exec("COMMIT");

    const captures: JournalCapture[] = [];
    for (const row of rows) {
      try {
        captures.push(JSON.parse(row.envelope_json) as JournalCapture);
      } catch {
        // A single unreadable envelope must not sink the whole attempt; it
        // stays claimed and is visible as evidence we could not interpret.
      }
    }
    return { attempt, captures };
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

/** Stage timestamps between claim and ACK, for answering "how far did it get?". */
export function recordSyncStage(
  db: DatabaseSync,
  syncAttemptId: string,
  stage: "extract_succeeded_at" | "reconciled_at" | "upload_started_at",
  at = new Date().toISOString(),
): void {
  db.prepare(`UPDATE sync_attempts SET ${stage} = ? WHERE sync_attempt_id = ?`).run(at, syncAttemptId);
}

/**
 * The server acknowledged this upload. Only now may its evidence be considered
 * consumed — that is the checkpoint the NDJSON ring never had.
 */
export function ackSyncAttempt(
  db: DatabaseSync,
  syncAttemptId: string,
  serverAck: unknown,
  at = new Date().toISOString(),
): void {
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(
      "UPDATE sync_attempts SET state = 'acked', acked_at = ?, server_ack_json = ?, last_error = NULL WHERE sync_attempt_id = ?",
    ).run(at, JSON.stringify(serverAck ?? null), syncAttemptId);
    db.prepare(
      `UPDATE captures SET consumed_at = ?
        WHERE sync_attempt_id = ? AND consumed_at IS NULL`,
    ).run(at, syncAttemptId);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}

/**
 * Releases the claim so the evidence is picked up again next poll. Retryable
 * attempts are never discarded: an upload we cannot deliver is a problem to
 * surface, not one to forget.
 */
export function failSyncAttempt(
  db: DatabaseSync,
  syncAttemptId: string,
  error: string,
  options: { blockedByAuth?: boolean; at?: string } = {},
): void {
  const at = options.at ?? new Date().toISOString();
  db.exec("BEGIN IMMEDIATE");
  try {
    db.prepare(
      `UPDATE sync_attempts
          SET state = ?, last_error = ?, last_attempt_at = ?
        WHERE sync_attempt_id = ?`,
    ).run(options.blockedByAuth ? "blocked_auth" : "failed_retryable", error.slice(0, 500), at, syncAttemptId);
    db.prepare(
      "UPDATE captures SET claimed_at = NULL, sync_attempt_id = NULL WHERE sync_attempt_id = ? AND consumed_at IS NULL",
    ).run(syncAttemptId);
    db.exec("COMMIT");
  } catch (rollbackError) {
    db.exec("ROLLBACK");
    throw rollbackError;
  }
}

/**
 * A daemon killed mid-upload leaves an attempt stuck in `sending` and its
 * evidence claimed forever. On startup, and periodically, hand that evidence
 * back — the upload may well have reached the server, and the server's own
 * mutation identity is what stops a duplicate from becoming a duplicate change.
 */
export function recoverStaleSyncAttempts(
  db: DatabaseSync,
  options: { olderThanMs: number; now?: string },
): number {
  const now = options.now ? Date.parse(options.now) : Date.now();
  const cutoff = new Date(now - options.olderThanMs).toISOString();
  const stale = db.prepare(
    "SELECT sync_attempt_id FROM sync_attempts WHERE state = 'sending' AND last_attempt_at < ?",
  ).all(cutoff) as Array<{ sync_attempt_id: string }>;

  for (const row of stale) {
    failSyncAttempt(db, row.sync_attempt_id, "daemon_stopped_before_ack", {
      at: options.now ?? new Date(now).toISOString(),
    });
  }
  return stale.length;
}

/** Attempts that still owe the student a delivery. */
export function unacknowledgedSyncAttempts(db: DatabaseSync, sourceKey: string): SyncAttempt[] {
  return (db.prepare(
    `SELECT * FROM sync_attempts
      WHERE source_key = ? AND state IN ('queued', 'sending', 'failed_retryable', 'blocked_auth')
      ORDER BY created_at ASC`,
  ).all(sourceKey) as SyncAttemptRow[]).map(toSyncAttempt);
}

/** Evidence that has never been acknowledged by the server, claimed or not. */
export function unacknowledgedCaptureCount(db: DatabaseSync, sourceKey: string): number {
  const row = db.prepare(
    "SELECT COUNT(*) AS count FROM captures WHERE source_key = ? AND consumed_at IS NULL",
  ).get(sourceKey) as { count: number };
  return Number(row?.count ?? 0);
}
