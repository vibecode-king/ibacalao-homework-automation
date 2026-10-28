// lib/watcher/detect.ts
// Reading what a page is telling us, before trying to extract anything from it.
//
// Every adapter needs this and none of it is platform-specific: if the session
// died we must stop and ask the student to log in, and if we tripped a bot
// check we must back off hard. Getting this wrong is worse than a failed crawl
// — an adapter that mistakes a login page for an empty assignment list will
// happily report "no homework" and the whole product silently lies.
//
// Pure and I/O-free: takes the URL and HTML a page already produced.

/**
 * A login/SSO wall.
 *
 * Matched on URL first because it is far more reliable than page text — a
 * genuine assignment titled "Please sign in to the lab portal" must not be read
 * as an auth wall, whereas a redirect to /login is unambiguous.
 */
const AUTH_URL_PATTERNS = [
  /\/login\b/i,
  /\/signin\b/i,
  /\/sign_in\b/i,
  /\/auth\b/i,
  /\/sessions\/new\b/i,
  /accounts\.google\.com/i,
  /login\.microsoftonline\.com/i,
];

/**
 * Body markers, used only as a fallback when the URL is inconclusive — some
 * platforms render a login form in place without navigating.
 *
 * Each requires a form-ish context to co-occur, so prose mentioning a password
 * does not trip it.
 */
const AUTH_BODY_PATTERNS = [
  /<input[^>]+type=["']password["']/i,
  /name=["']password["']/i,
  /id=["']txtUser["']/i,
  /id=["']txtPassword["']/i,
];

/** Bot checks and rate limiting. */
const CHALLENGE_PATTERNS = [
  /cf-browser-verification/i,
  /challenge-platform/i,
  /just a moment/i,
  /checking your browser/i,
  /captcha/i,
  /recaptcha/i,
  /hcaptcha/i,
  /unusual traffic/i,
  /rate limit/i,
  /too many requests/i,
];

export function looksLikeAuthWall(url: string, html: string): boolean {
  if (AUTH_URL_PATTERNS.some((pattern) => pattern.test(url))) return true;
  return AUTH_BODY_PATTERNS.some((pattern) => pattern.test(html));
}

export function looksLikeChallenge(url: string, html: string): boolean {
  return CHALLENGE_PATTERNS.some((pattern) => pattern.test(html) || pattern.test(url));
}

/**
 * Parses a `Retry-After` value into milliseconds.
 *
 * Accepts both forms the header takes: delta-seconds, and an HTTP date. A past
 * date yields 0 rather than a negative delay.
 */
export function parseRetryAfterMs(value: string | null | undefined, now = Date.now()): number | undefined {
  if (!value) return undefined;
  const trimmed = value.trim();
  if (/^\d+$/.test(trimmed)) return Number(trimmed) * 1000;
  const at = Date.parse(trimmed);
  if (!Number.isFinite(at)) return undefined;
  return Math.max(0, at - now);
}

export type PageVerdict =
  | { state: "ok" }
  | { state: "auth_required" }
  | { state: "challenged" };

/**
 * The single check every adapter runs before extraction.
 *
 * Challenge is tested BEFORE auth: an interstitial bot check frequently sits on
 * a URL containing /login and would otherwise be misread as an expired session,
 * which would tell the student to re-authenticate when nothing is wrong with
 * their session and would keep hammering a platform that just asked us to stop.
 */
export function classifyPage(url: string, html: string): PageVerdict {
  if (looksLikeChallenge(url, html)) return { state: "challenged" };
  if (looksLikeAuthWall(url, html)) return { state: "auth_required" };
  return { state: "ok" };
}
