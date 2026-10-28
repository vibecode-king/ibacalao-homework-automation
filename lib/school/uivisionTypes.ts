// Phase 2 controller contract for the UI.Vision fallback navigator.
// Plan: documents/SCHOOL_CONNECTOR_UIVISION_FALLBACK_PLAN_2026-09-17.md
//
// Pure types only — no Playwright import here. The Playwright-driving
// controller lives in lib/watcher/uivisionNavigator.ts, the one place (besides
// session.ts) allowed to touch a browser, so the Next.js app build never pulls
// a browser dependency in through lib/school.

import type { SchoolActionCapability } from "./types";

export type SchoolNavigationGoal = SchoolActionCapability;

export type NavigationState =
  | "reached_candidate"
  | "not_found"
  | "auth_required"
  | "challenged"
  | "failed";

export type NavigationResult = {
  goal: SchoolNavigationGoal;
  state: NavigationState;
  observedUrl?: string;
  detail?: string;
};

/** One fallback navigation attempt, for local correlation with School Bridge
 *  captures. See Phase 5 — evidence attribution. */
export type NavigationAttempt = {
  correlationId: string;
  goal: SchoolNavigationGoal;
  startedAt: string;
};
