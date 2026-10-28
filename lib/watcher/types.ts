// lib/watcher/types.ts
// Vocabulary for the student-platform watcher: a local daemon that keeps a
// logged-in browser session per platform, polls for new academic reality, and
// pushes only what changed to the server.
//
// SCOPE, deliberately narrow: this reads. It never submits, never fills a form,
// never acts on the student's behalf. Auto-submission is the separate homework
// -automation track (docs/superpowers/specs/2026-08-20-homework-automation-design.md)
// and keeping the two apart is what lets this one run with far weaker
// guarantees — a missed assignment here degrades a recommendation, it does not
// file the wrong work against a real deadline.
//
// WHY LOCAL: the session belongs to the student. Running the browser on their
// machine means their LMS password and cookies never reach our servers; we
// receive normalized academic facts, not credentials. The cost is that the
// watcher only runs while their machine is awake, which is what the daemon's
// keep-awake behaviour is for.

import type { ContentIntegritySummary } from "../security/contentIntegrity";

/** Known bundled adapters. This is NOT the universe of valid school sources. */
export const WATCHER_PLATFORMS = ["managebac", "classroom", "generic", "learnbox"] as const;
export type WatcherPlatform = (typeof WATCHER_PLATFORMS)[number];

/**
 * One academic fact as a platform adapter found it, before normalization.
 *
 * Mirrors DispatchRecord's shape on purpose — lib/dispatch.ts is already the
 * school-ingestion boundary and lib/events/derive.ts already knows how to turn
 * its records into canonical events. Introducing a second parallel shape here
 * would mean a second mapping to keep honest.
 */
export type ScrapedRecord = {
  /** Stable id assigned by the source. New code should use this name. */
  sourceRecordId?: string;
  /** @deprecated Compatibility with already-shipped watcher clients. */
  platformId?: string;
  kind: "assignment" | "message" | "grade" | "submission" | "deadline";
  title: string;
  subject?: string;
  detail?: string;
  url?: string;
  dueAt?: string;
  occurredAt?: string;
  status?: string;
  grade?: string;
  /** Teacher or message sender when the page named one. */
  teacher?: string;
  /** Stable thread/conversation id when the portal exposes one. */
  threadId?: string;
  /** Local observation time from the browser bridge; never mapped to Dispatch. */
  observedAt?: string;
  /**
   * Local reconciliation classification. It is advisory metadata for ingest:
   * enrichment updates current Dispatch state without pretending the school
   * published a new academic change. Older clients omit it and retain the
   * historical behavior.
   */
  changeKind?: "new_entity" | "source_changed" | "enriched" | "unchanged";
  /**
   * Title-only triage for "message" records — never derived from opening the
   * message. See lib/school/messageUrgency.ts for how it's computed and why
   * that boundary matters.
   */
  urgency?: "low" | "medium" | "high";
  /** Deterministic 0–100 relevance score for school messages. */
  importanceScore?: number;
  /** Machine-readable scorer signals; never free-form message content. */
  importanceReasons?: string[];
  /** Potential embedded model-manipulation / concealed-text evidence. */
  contentIntegrity?: ContentIntegritySummary;
};

export function scrapedRecordId(record: ScrapedRecord): string | undefined {
  const value = record.sourceRecordId ?? record.platformId;
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed || undefined;
}

/** Whether this crawl's records are the whole collection or a bounded slice. */
export type CrawlCoverage = {
  pagesSeen: number;
  hasMore: boolean;
  detailsAttempted: number;
  detailsSucceeded: number;
  completeness: "complete" | "partial" | "unknown";
};

export type CrawlOutcome =
  | { ok: true; records: ScrapedRecord[]; coverage?: CrawlCoverage; capabilities?: import("../school/capabilityHealth").CapabilityHealth[] }
  /** The session is dead — cookies expired, or the platform logged us out.
   *  Distinct from an error because it needs the student to re-auth, not a
   *  retry, and retrying only burns rate limit and looks more like a bot. */
  | { ok: false; reason: "auth_required" }
  /** A bot check, captcha or explicit rate limit. Backs off hard. */
  | { ok: false; reason: "challenged"; retryAfterMs?: number }
  | { ok: false; reason: "error"; message: string };

/** What every platform adapter must implement. */
export type PlatformAdapter = {
  platform: WatcherPlatform;
  /** Human label for logs and the health surface. */
  label: string;
  /**
   * Reads current academic reality from an already-authenticated page context.
   * Adapters never handle credentials themselves — the session layer owns that.
   */
  crawl(page: WatcherPage): Promise<CrawlOutcome>;
};

/**
 * The slice of Playwright's Page this module depends on.
 *
 * Declared structurally rather than importing Playwright's type so the pure
 * logic here, the adapters and their tests do not pull a browser dependency
 * into the Next.js build — only lib/watcher/session.ts imports Playwright for
 * real, and only the daemon ever loads it.
 */
export type WatcherPage = {
  goto(url: string, options?: { timeout?: number }): Promise<unknown>;
  url(): string;
  content(): Promise<string>;
  title(): Promise<string>;
  /** Structural subset of Playwright's Page.evaluate — runs `fn` in the
   *  real page DOM and returns its result. Optional: only adapters that read
   *  live DOM elements (e.g. lib/watcher/adapters/learnbox.ts) need it;
   *  managebac.ts's regex-on-HTML approach never calls it. */
  evaluate?<T, Arg>(fn: (arg: Arg) => T, arg: Arg): Promise<T>;
  /** Structural subset of Playwright's Page.waitForSelector. Optional, same
   *  reason as evaluate — lets an adapter wait for a single-page app to
   *  actually render its data before reading the DOM, instead of racing
   *  goto()'s 'load' event (which fires before an async data fetch resolves). */
  waitForSelector?(selector: string, options?: { timeout?: number; state?: "attached" | "visible" | "hidden" }): Promise<unknown>;
  /** Authenticated request helper from the same Playwright browser context.
   * Optional so pure adapter tests and non-Playwright callers stay lightweight.
   * The generic attachment resolver uses it for read-only file fetches after a
   * detail page exposes a likely attachment URL. */
  request?: {
    get(url: string, options?: {
      timeout?: number;
      failOnStatusCode?: boolean;
      maxRedirects?: number;
    }): Promise<{
      ok(): boolean;
      status(): number;
      url(): string;
      headers(): Record<string, string>;
      body(): Promise<Uint8Array>;
    }>;
  };
};

/** Per-platform health, surfaced to the admin view. */
export type WatcherHealth = {
  platform: WatcherPlatform;
  lastAttemptAt: string | null;
  lastSuccessAt: string | null;
  /** Consecutive failures. Drives the backoff in schedule.ts. */
  consecutiveFailures: number;
  /** Times a bot check was hit. A rising count means we are being detected. */
  challengeCount: number;
  /** Set when the session needs the student to log in again. */
  authRequired: boolean;
  lastError: string | null;
};

export function emptyHealth(platform: WatcherPlatform): WatcherHealth {
  return {
    platform,
    lastAttemptAt: null,
    lastSuccessAt: null,
    consecutiveFailures: 0,
    challengeCount: 0,
    authRequired: false,
    lastError: null,
  };
}
