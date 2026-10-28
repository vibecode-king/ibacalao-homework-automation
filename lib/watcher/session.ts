// lib/watcher/session.ts
// The persistent browser session, per student per platform.
//
// NODE-ONLY. This is the single file in lib/watcher/ that imports Playwright,
// and it is imported only by scripts/watcher-daemon.ts — never by the Next.js
// app. Everything else in this module is pure and browser-free so the app
// build never pulls a browser dependency.
//
// WHY launchPersistentContext RATHER THAN storageState: a persistent profile
// directory keeps cookies, localStorage, IndexedDB and the browser's own
// fingerprint stable across runs, exactly as a real returning browser would.
// Saving and replaying a storageState blob restores cookies but presents a
// freshly-minted browser every time, which is both more fragile (many LMSes
// bind a session to more than a cookie) and more detectable.
//
// The profile lives on the student's machine and never leaves it. This process
// sends normalized academic records to the server; it never transmits the
// profile, cookies, or credentials.

import { chromium, type BrowserContext, type Page } from "playwright";
import { mkdirSync, readFileSync, readlinkSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Browser profiles are intentionally more general than extraction adapters.
 * A student can establish a local authenticated session for any HTTPS school
 * platform today, even when iBacalao does not yet ship an extractor for it.
 *
 * Keep the profile key filesystem-safe: platform ids can arrive from the web
 * shell and must never be allowed to escape ~/.ibacalao/watcher.
 */
export function platformProfileKey(platform: string): string {
  const normalized = platform
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
  if (!normalized) throw new Error("platform id is required");
  return normalized;
}

/** One profile directory per platform, so a broken session on one does not
 *  force a re-login everywhere. */
export function profileDir(platform: string, root?: string): string {
  return join(root ?? join(homedir(), ".ibacalao", "watcher"), platformProfileKey(platform));
}

export type SessionHandle = {
  context: BrowserContext;
  page: Page;
  /** Call after a successful authenticated crawl. See saveSessionCookies. */
  saveSessionCookies(siteKey: string): Promise<boolean>;
  /** Retry a saved session after the school itself has shown an auth wall. */
  restoreSavedSessionCookies(options?: { replaceExisting?: boolean }): Promise<number>;
  /** True once Chromium or the page is gone (sleep, crash, window closed); the handle must be replaced. */
  isClosed(): boolean;
  close(): Promise<void>;
};

type BrowserCookie = Awaited<ReturnType<BrowserContext["cookies"]>>[number];
type CookieJar = Pick<BrowserContext, "cookies" | "addCookies">;

const SESSION_COOKIE_FILE = "session-cookies.json";
const cookieKey = (cookie: Pick<BrowserCookie, "name" | "domain" | "path">) => `${cookie.name}|${cookie.domain}|${cookie.path}`;

/** Session-only cookies (no expiry) that belong to one school site. */
export function sessionOnlyCookies(cookies: BrowserCookie[], siteKey: string): BrowserCookie[] {
  const site = siteKey.trim().toLowerCase();
  if (!site) return [];
  return cookies.filter((cookie) => {
    const domain = cookie.domain.replace(/^\./, "").toLowerCase();
    return cookie.expires === -1 && (domain === site || domain.endsWith(`.${site}`));
  });
}

/**
 * Some platforms (Learnbox) authenticate with a session-only cookie. A
 * persistent profile drops it whenever the browser process exits, so every
 * app relaunch, rebuild or reboot looked like the student had logged out even
 * though the school still considered the session valid. Keeping a copy next to
 * the profile, readable only by this user, lets the next browser resume it. A
 * session the school really expired still shows its login wall and still
 * becomes reauth_required.
 */
/** Returns false when the school sign-in is not kept: the site has no cookies
 * at all, or its session-only cookies could not be written to disk. */
export async function saveSessionCookies(context: CookieJar, dir: string, siteKey: string): Promise<boolean> {
  try {
    const all = await context.cookies();
    const site = siteKey.trim().toLowerCase().replace(/^\./, "");
    const siteHasCookies = all.some((cookie) => {
      const domain = cookie.domain.replace(/^\./, "").toLowerCase();
      // Either direction: a cookie for learnbox.com.ec also serves ukschool.learnbox.com.ec.
      return Boolean(site) && (domain === site || domain.endsWith(`.${site}`) || site.endsWith(`.${domain}`));
    });
    if (!siteHasCookies) return false;
    const cookies = sessionOnlyCookies(all, siteKey);
    if (cookies.length === 0) return true; // persistent cookies live in the profile itself
    const file = join(dir, SESSION_COOKIE_FILE);
    const temporary = `${file}.${process.pid}.tmp`;
    writeFileSync(temporary, JSON.stringify(cookies), { mode: 0o600 });
    renameSync(temporary, file);
    return true;
  } catch (error) {
    console.warn("[watcher] could not keep session cookies:", error instanceof Error ? error.message : error);
    return false;
  }
}

/** Restores saved session cookies. Normal startup only fills missing cookies,
 * so a genuinely newer live browser session wins. After the school has shown
 * a stable auth wall, callers may set replaceExisting=true: the saved copy was
 * captured after a successful authenticated crawl and is then worth one
 * recovery attempt before asking the student to sign in again. */
export async function restoreSessionCookies(
  context: CookieJar,
  dir: string,
  options: { replaceExisting?: boolean } = {},
): Promise<number> {
  try {
    const saved = JSON.parse(readFileSync(join(dir, SESSION_COOKIE_FILE), "utf8")) as unknown;
    if (!Array.isArray(saved)) return 0;
    const valid = (saved as BrowserCookie[]).filter((cookie) =>
      cookie && typeof cookie.name === "string" && typeof cookie.domain === "string" && typeof cookie.path === "string"
    );
    const present = new Set((await context.cookies()).map(cookieKey));
    const restorable = options.replaceExisting
      ? valid
      : valid.filter((cookie) => !present.has(cookieKey(cookie)));
    if (restorable.length > 0) await context.addCookies(restorable);
    return restorable.length;
  } catch {
    // No saved session yet, or an unreadable one: start as a fresh browser.
    return 0;
  }
}

/**
 * Chromium leaves SingletonLock behind in the profile directory to stop two
 * processes from sharing it at once. It's only released when that process
 * exits cleanly — but the native shell replaces the daemon process (app
 * restart, or pausing the background poll to open a visible login window)
 * with SIGTERM, which does not wait for the old Chromium child to finish
 * shutting down before the next launchPersistentContext call. That race is
 * what produces the repeating "Failed to create a ProcessSingleton" polls.
 *
 * Only remove the lock when the pid it names is provably not running
 * (ESRCH) — never on ambiguous errors (EPERM, a foreign lock format), so an
 * actually-live second process is never stepped on.
 */
export function clearStaleSingletonLock(dir: string): void {
  const lockPath = join(dir, "SingletonLock");
  let target: string;
  try {
    target = readlinkSync(lockPath);
  } catch {
    return; // no lock file, or not a symlink — nothing to do
  }
  const pid = Number(target.split("-").pop());
  if (!Number.isFinite(pid) || pid <= 0) return;
  try {
    process.kill(pid, 0);
    return; // alive, or we can't tell (EPERM) — leave it alone either way
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") return;
  }
  try {
    rmSync(lockPath, { force: true });
  } catch {
    // Best-effort: launchPersistentContext will surface its own error if
    // this didn't work, same as before this function existed.
  }
}

/**
 * Opens (or reopens) the persistent session for one platform.
 *
 * `headless` defaults to true for the polling loop, but a first-time login
 * needs a visible window for the student to type into — see openForLogin.
 */
export async function openSession(
  platform: string,
  options: {
    headless?: boolean;
    profileRoot?: string;
    profileKey?: string;
    /**
     * Phase 1 — UI.Vision fallback navigator sessions only. Absolute path to
     * the pinned, unmodified extension directory (see
     * resolveUivisionExtensionPath in uivisionNavigator.ts). Omitted for
     * every normal watcher poll, so the extension startup cost is never paid
     * outside a fallback session — see plan Phase 1 exit criteria.
     */
    extensionPath?: string;
  } = {},
): Promise<SessionHandle> {
  const dir = profileDir(options.profileKey ?? platform, options.profileRoot);
  mkdirSync(dir, { recursive: true });
  clearStaleSingletonLock(dir);

  const context = await chromium.launchPersistentContext(dir, {
    headless: options.headless ?? true,
    // Use Chromium's current full-browser headless mode instead of Playwright's
    // separate legacy headless-shell binary. This lets the DMG ship one browser
    // payload for both background polling and visible interactive login.
    channel: "chromium",
    // A real viewport and a normal locale/timezone: a default-headless
    // fingerprint is one of the easier automation tells.
    viewport: { width: 1280, height: 900 },
    locale: "en-US",
    ...(options.extensionPath
      ? {
          args: [
            `--disable-extensions-except=${options.extensionPath}`,
            `--load-extension=${options.extensionPath}`,
          ],
        }
      : {}),
  });

  await restoreSessionCookies(context, dir);
  const page = context.pages()[0] ?? (await context.newPage());
  let contextClosed = false;
  context.on("close", () => { contextClosed = true; });

  return {
    context,
    page,
    saveSessionCookies: (siteKey) => saveSessionCookies(context, dir, siteKey),
    restoreSavedSessionCookies: (restoreOptions) => restoreSessionCookies(context, dir, restoreOptions),
    isClosed: () => contextClosed || page.isClosed(),
    async close() {
      // Closing the context is what flushes cookies to the profile directory;
      // skipping it loses the session and forces a re-login next run.
      await context.close();
    },
  };
}

/**
 * Opens a VISIBLE window so the student can log in themselves.
 *
 * The daemon never types a password and never stores one. The student
 * authenticates by hand once; the persistent profile carries that session
 * forward until the platform expires it, at which point the watcher reports
 * `auth_required` and waits rather than trying to re-authenticate on its own.
 */
export async function openForLogin(
  platform: string,
  loginUrl: string,
  options: { profileRoot?: string } = {},
): Promise<SessionHandle> {
  const session = await openSession(platform, { headless: false, ...options });
  await session.page.goto(loginUrl);
  return session;
}
