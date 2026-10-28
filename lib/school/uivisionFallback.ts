// Phase 1 kill switch, Phase 3 trigger gating, and Phase 5 local evidence
// attribution logging for the UI.Vision fallback navigator.
//
// Plan: documents/SCHOOL_CONNECTOR_UIVISION_FALLBACK_PLAN_2026-09-17.md

import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";
import type { SchoolConnectionStatus } from "./types";
import type { NavigationAttempt, NavigationResult, SchoolNavigationGoal } from "./uivisionTypes";

export const DEFAULT_UIVISION_LOG_FILE = join(homedir(), ".ibacalao", "school", "uivision-navigation.jsonl");

/** Default-off kill switch. The fallback never runs unless a human opted in,
 *  independent of whether the pinned extension artifact is even present. */
export function uivisionFallbackEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.IBACALAO_SCHOOL_UIVISION_FALLBACK === "1";
}

/**
 * Phase 3 — the fallback only ever runs inside the existing learning window,
 * never as a second learning-state machine. `missingCapabilities` comes
 * straight from that window (see scripts/watcher-daemon.ts loadActiveLearningWindow).
 */
export function goalsForFallback(
  status: Pick<SchoolConnectionStatus, "actionReason">,
  missingCapabilities: readonly SchoolNavigationGoal[],
): SchoolNavigationGoal[] {
  if (status.actionReason !== "manual_learning_required") return [];
  return [...missingCapabilities];
}

export function newCorrelationId(): string {
  return randomUUID();
}

export function startNavigationAttempt(goal: SchoolNavigationGoal): NavigationAttempt {
  return { correlationId: newCorrelationId(), goal, startedAt: new Date().toISOString() };
}

/**
 * One bounded JSONL line per navigation attempt. Never logs page text,
 * credentials, raw HTML or screenshots — only the goal, outcome and the
 * observed URL, so a School Bridge capture can be correlated back to the
 * navigation goal that preceded it without carrying any new extraction data.
 */
export function logNavigationAttempt(
  attempt: NavigationAttempt,
  result: NavigationResult,
  file = DEFAULT_UIVISION_LOG_FILE,
): void {
  mkdirSync(dirname(file), { recursive: true });
  const line = {
    correlationId: attempt.correlationId,
    goal: attempt.goal,
    startedAt: attempt.startedAt,
    finishedAt: new Date().toISOString(),
    state: result.state,
    observedUrl: result.observedUrl,
  };
  appendFileSync(file, `${JSON.stringify(line)}\n`);
}
