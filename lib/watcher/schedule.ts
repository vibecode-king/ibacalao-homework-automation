// lib/watcher/schedule.ts
// When the watcher is allowed to poll next.
//
// Two jobs, both about not looking like a bot and not getting the student's
// account flagged:
//
//  1. JITTER. A poll on an exact interval is a machine signature — the single
//     cheapest thing to detect. Every wait is randomized within a band.
//  2. BACKOFF. Failures, and especially bot challenges, make the next wait
//     longer. Hammering a platform that just showed a captcha is the fastest
//     way to escalate from "challenged" to "blocked".
//
// Pure and I/O-free; the daemon owns the actual sleeping.

import type { WatcherHealth } from "./types";

const MINUTE = 60 * 1000;

/** Baseline gap between polls when everything is healthy. */
export const BASE_INTERVAL_MS = 30 * MINUTE;

/** Jitter band, as a fraction of the interval. ±25% on a 30m base gives a
 *  22–38 minute spread — irregular enough not to look scheduled, tight enough
 *  that a deadline is never missed by long. */
export const JITTER_RATIO = 0.25;

/** Never poll faster than this, whatever the caller asks for. */
export const MIN_INTERVAL_MS = 5 * MINUTE;

/** Ceiling on backoff. Beyond a few hours the watcher is effectively off, and
 *  waiting longer neither helps nor recovers anything. */
export const MAX_INTERVAL_MS = 6 * 60 * MINUTE;

/**
 * A bot challenge backs off far harder than an ordinary error.
 *
 * An error is usually ours (a selector broke, the network blipped) and retrying
 * soon is fine. A challenge is the platform telling us it thinks we are a bot;
 * the correct response is to become much quieter, not to try again in a minute.
 */
export const CHALLENGE_BACKOFF_MULTIPLIER = 8;

/** Applies ±JITTER_RATIO to a delay. `random` is injectable so this is testable. */
export function jitter(ms: number, random: () => number = Math.random): number {
  const spread = ms * JITTER_RATIO;
  // random() in [0,1) → offset in [-spread, +spread)
  const offset = (random() * 2 - 1) * spread;
  return Math.max(0, Math.round(ms + offset));
}

/**
 * How long to wait before the next poll of this platform.
 *
 * Backoff is exponential in consecutive failures, capped, then jittered — so
 * two platforms failing together do not retry in lockstep.
 */
export function nextDelayMs(
  health: Pick<WatcherHealth, "consecutiveFailures" | "authRequired">,
  options: { baseMs?: number; challenged?: boolean; retryAfterMs?: number } = {},
  random: () => number = Math.random,
): number {
  const base = options.baseMs ?? BASE_INTERVAL_MS;

  // A platform explicitly telling us when to come back is more reliable than
  // any heuristic — honour it, still jittered so a fleet does not stampede at
  // the same instant, and still floored by MIN_INTERVAL_MS.
  if (options.retryAfterMs !== undefined && Number.isFinite(options.retryAfterMs)) {
    return clampDelay(jitter(Math.max(options.retryAfterMs, MIN_INTERVAL_MS), random));
  }

  // Re-auth needs a human. Polling cannot fix it, so sit at the ceiling and
  // wait to be told the session was renewed.
  if (health.authRequired) return clampDelay(jitter(MAX_INTERVAL_MS, random));

  const failures = Math.max(0, health.consecutiveFailures);
  let delay = failures === 0 ? base : base * Math.pow(2, Math.min(failures, 10));
  if (options.challenged) delay *= CHALLENGE_BACKOFF_MULTIPLIER;

  return clampDelay(jitter(delay, random));
}

function clampDelay(ms: number): number {
  return Math.min(Math.max(ms, MIN_INTERVAL_MS), MAX_INTERVAL_MS);
}

/**
 * Folds a crawl's result into the platform's health record.
 *
 * `challengeCount` is cumulative and never reset by a success — it is the
 * signal for "this platform is starting to detect us", which a single good
 * crawl does not disprove.
 */
export function applyOutcome(
  health: WatcherHealth,
  outcome:
    | { ok: true }
    | { ok: false; reason: "auth_required" | "challenged" | "error"; message?: string },
  now: string = new Date().toISOString(),
): WatcherHealth {
  const next: WatcherHealth = { ...health, lastAttemptAt: now };

  if (outcome.ok) {
    next.lastSuccessAt = now;
    next.consecutiveFailures = 0;
    next.authRequired = false;
    next.lastError = null;
    return next;
  }

  next.consecutiveFailures = health.consecutiveFailures + 1;
  next.lastError = outcome.reason === "error" ? (outcome.message ?? "error") : outcome.reason;
  if (outcome.reason === "challenged") next.challengeCount = health.challengeCount + 1;
  if (outcome.reason === "auth_required") next.authRequired = true;
  return next;
}
