// Phase 2 deterministic navigator controller, Phase 4 wiring of the safety
// invariants against a real Page, and Phase 0 pinned-extension path
// resolution. NODE-ONLY — this file imports Playwright, like session.ts next
// to it, and must never be imported from the Next.js app.
//
// Plan: documents/SCHOOL_CONNECTOR_UIVISION_FALLBACK_PLAN_2026-09-17.md

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Page } from "playwright";
import { shouldStopNavigation } from "../school/uivisionSafety";
import type { NavigationResult, SchoolNavigationGoal } from "../school/uivisionTypes";

/**
 * Phase 0 — the pinned, unmodified UI.Vision extension is expected at
 * <runtimeRoot>/uivision/extension (decision still open in Phase 0: bundled
 * vs. copied at release time). Returns null whenever the artifact is not
 * present, which the caller must treat exactly like "fallback unavailable" —
 * never a crash, never a false-healthy status.
 */
export function resolveUivisionExtensionPath(runtimeRoot: string): string | null {
  const dir = join(runtimeRoot, "uivision", "extension");
  return existsSync(join(dir, "manifest.json")) ? dir : null;
}

/** Phase 6 release diagnostic — logs the shipped manifest's checksum so a
 *  release can be confirmed to carry the exact pinned artifact (see Phase 0
 *  pin + checksum requirement). */
export function uivisionManifestChecksum(extensionDir: string): string | null {
  try {
    return createHash("sha256").update(readFileSync(join(extensionDir, "manifest.json"))).digest("hex");
  } catch {
    return null;
  }
}

/** Declarative, bounded EN/ES label dictionary per goal. DOM/role/text
 *  semantics are preferred first; UI.Vision visual/OCR matching is only a
 *  further fallback the controller does not implement in this phase — see
 *  Phase 2 exit criteria (DOM-first attempt only, no OCR yet). */
const GOAL_LABELS: Record<SchoolNavigationGoal, readonly string[]> = {
  assignments: ["assignments", "homework", "tareas", "actividades"],
  messages: ["messages", "inbox", "mensajes", "bandeja"],
  grades: ["grades", "marks", "notas", "calificaciones"],
  deadlines: ["deadlines", "calendar", "agenda", "fechas"],
  submissions: ["submissions", "entregas", "envios", "entregar"],
};

const MAX_ATTEMPTS_PER_GOAL = 3;
const STEP_TIMEOUT_MS = 8_000;

/** School nav is not always real <a> links — many SPA menus use buttons,
 *  tabs or menu items with no href. Tried in this order per label. */
const CANDIDATE_ROLES = ["link", "button", "menuitem", "tab"] as const;

export type NavigatorOptions = {
  schoolOrigin: string;
  approvedRedirectOrigins?: readonly string[];
};

/**
 * Attempts one capability goal against the current page. Hard-bounded:
 * MAX_ATTEMPTS_PER_GOAL candidate links, STEP_TIMEOUT_MS per navigation.
 * Reports the outcome only — it never decides a capability was learned. That
 * decision stays with School Bridge capture + the existing recipe pipeline
 * (Phase 3).
 */
export async function attemptNavigationGoal(
  page: Page,
  goal: SchoolNavigationGoal,
  options: NavigatorOptions,
): Promise<NavigationResult> {
  // The page is often still hydrating a client-rendered SPA nav right after
  // navigation. Give it a bounded chance to settle before searching —
  // isVisible() alone does not wait, so skipping this made every goal fail
  // instantly against a still-empty DOM.
  await page.waitForLoadState("networkidle", { timeout: STEP_TIMEOUT_MS }).catch(() => undefined);

  const stopBefore = shouldStopNavigation({
    url: page.url(),
    pageText: await safeInnerText(page),
    schoolOrigin: options.schoolOrigin,
    approvedRedirectOrigins: options.approvedRedirectOrigins,
    hasPasswordField: await hasVisiblePasswordField(page),
  });
  if (stopBefore.stop) {
    return { goal, state: stopReasonToState(stopBefore.reason), observedUrl: page.url() };
  }

  const labels = GOAL_LABELS[goal];
  for (const label of labels.slice(0, MAX_ATTEMPTS_PER_GOAL)) {
    let clicked = false;
    // Real school nav is not always a real <a> link — try each clickable
    // role in turn rather than assuming "link". First matching, visible
    // candidate wins; declarative and bounded, no DOM inspection needed.
    for (const role of CANDIDATE_ROLES) {
      const candidate = page.getByRole(role, { name: new RegExp(label, "i") }).first();
      try {
        // waitFor actually waits, unlike isVisible(), which returns instantly.
        await candidate.waitFor({ state: "visible", timeout: 3_000 });
        await candidate.click({ timeout: STEP_TIMEOUT_MS });
        clicked = true;
        break;
      } catch {
        continue; // this role/label combo not present — try the next one
      }
    }
    if (!clicked) continue; // no role matched this label — try the next label

    const pageText = await safeInnerText(page);
    const stopAfter = shouldStopNavigation({
      url: page.url(),
      pageText,
      schoolOrigin: options.schoolOrigin,
      approvedRedirectOrigins: options.approvedRedirectOrigins,
      hasPasswordField: await hasVisiblePasswordField(page),
    });
    if (stopAfter.stop) {
      return { goal, state: stopReasonToState(stopAfter.reason), observedUrl: page.url() };
    }
    return { goal, state: "reached_candidate", observedUrl: page.url() };
  }

  return { goal, state: "not_found", observedUrl: page.url() };
}

async function safeInnerText(page: Page): Promise<string> {
  try {
    return await page.innerText("body", { timeout: 2_000 });
  } catch {
    return "";
  }
}

/** Never types into a password field (Phase 4 invariant), so this checks
 *  presence, not focus — a visible password input on the page means the
 *  navigator landed on a login wall, whether or not it is about to touch it. */
async function hasVisiblePasswordField(page: Page): Promise<boolean> {
  try {
    return (await page.locator('input[type="password"]:visible').count()) > 0;
  } catch {
    return false;
  }
}

function stopReasonToState(reason: ReturnType<typeof shouldStopNavigation>["reason"]): NavigationResult["state"] {
  if (reason === "challenge") return "challenged";
  if (reason === "origin_not_allowed") return "failed";
  return "auth_required";
}
