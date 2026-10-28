// Phase 4 — safety and fail-closed behavior for the UI.Vision fallback
// navigator. Pure, browser-free checks so they can run against real DOM
// snapshots in the navigator controller (lib/watcher/uivisionNavigator.ts)
// and be unit-tested without Playwright.
//
// Plan: documents/SCHOOL_CONNECTOR_UIVISION_FALLBACK_PLAN_2026-09-17.md

/** Password fields are never typed into by the fallback navigator. */
export function isPasswordField(inputType: string): boolean {
  return inputType.trim().toLowerCase() === "password";
}

const DESTRUCTIVE_WORDS = [
  "delete",
  "remove",
  "send",
  "submit",
  "pay",
  "confirm purchase",
  "eliminar",
  "enviar",
  "borrar",
  "pagar",
];

/** Controls the navigator must never click: delete/remove/send/submit and
 *  Spanish equivalents, checked against the control's accessible label. */
export function isDestructiveControl(accessibleLabel: string): boolean {
  const label = accessibleLabel.trim().toLowerCase();
  if (!label) return false;
  return DESTRUCTIVE_WORDS.some((word) => label.includes(word));
}

const CHALLENGE_PATTERNS: RegExp[] = [
  /captcha/i,
  /verify you are human/i,
  /verifica que (no )?eres (un )?robot/i,
  /two-factor|2fa|two factor authentication/i,
  /verificaci[oó]n en dos pasos/i,
  /access (denied|restricted)/i,
  /acceso (denegado|restringido)/i,
];

export type FailClosedSignal = "challenge" | "login_wall" | "restricted" | null;

/** Bounded text scan for the signals that must stop navigation immediately.
 *  Never inspects credentials; only looks for challenge/restriction copy. */
export function detectFailClosedSignal(pageText: string): FailClosedSignal {
  const text = pageText.slice(0, 20_000); // bounded — never scan an unbounded page
  for (const pattern of CHALLENGE_PATTERNS) {
    if (pattern.test(text)) return "challenge";
  }
  return null;
}

function originOf(url: string): string | null {
  try {
    return new URL(url).origin;
  } catch {
    return null;
  }
}

/** The navigator may only stay on the connected school's HTTPS origin, plus
 *  already-approved identity-provider redirect origins for auth. No
 *  arbitrary web browsing. */
export function isOriginAllowed(
  url: string,
  schoolOrigin: string,
  approvedRedirectOrigins: readonly string[] = [],
): boolean {
  const origin = originOf(url);
  if (!origin || !origin.startsWith("https://")) return false;
  if (origin === originOf(schoolOrigin)) return true;
  return approvedRedirectOrigins.some((allowed) => origin === originOf(allowed));
}

export type NavigationStopCheck = {
  url: string;
  pageText: string;
  schoolOrigin: string;
  approvedRedirectOrigins?: readonly string[];
  /** Whether the current page has a visible password input. A login wall
   *  never shows up in `pageText` keyword matching (e.g. "Nombre de usuario"
   *  / "Contraseña" say nothing about a challenge), so it must be checked
   *  separately — see Phase 4's explicit "SSO/login wall" stop condition. */
  hasPasswordField?: boolean;
};

export type NavigationStopResult = {
  stop: boolean;
  reason?: FailClosedSignal | "origin_not_allowed";
};

/** Single entry point the navigator controller calls before and after every
 *  step. Any true result must halt the whole fallback session, never just
 *  the current goal — see Phase 4 exit criteria. */
export function shouldStopNavigation(check: NavigationStopCheck): NavigationStopResult {
  if (!isOriginAllowed(check.url, check.schoolOrigin, check.approvedRedirectOrigins)) {
    return { stop: true, reason: "origin_not_allowed" };
  }
  if (check.hasPasswordField) {
    return { stop: true, reason: "login_wall" };
  }
  const signal = detectFailClosedSignal(check.pageText);
  if (signal) return { stop: true, reason: signal };
  return { stop: false };
}
