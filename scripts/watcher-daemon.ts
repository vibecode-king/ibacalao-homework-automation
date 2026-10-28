/**
 * The caffeinated watcher daemon.
 *
 * Runs on the student's own machine, holds their LMS session in a persistent
 * browser profile, polls on a jittered interval, and uploads only what changed.
 *
 * Usage:
 *   IBACALAO_TOKEN=... npm run watcher:daemon                 # poll forever
 *   npm run watcher:once                                      # ~/.ibacalao/watcher/token or IBACALAO_TOKEN
 *   npm run watcher:token                                     # mint wt_ from Keychain session
 *   npm run watcher:daemon -- --login managebac               # visible re-auth
 *   npm run watcher:daemon -- --discover                      # find + connect school platform
 *
 * "Caffeinated" on macOS: the poll loop runs under `caffeinate -i -m`, which
 * prevents IDLE sleep only. Closing the lid still sleeps the Mac (no caffeinate
 * flag prevents that; `-s` works only on AC power), and a sleeping Mac does not
 * poll. The server detects that through missing heartbeats (lib/school/freshness.ts).
 *
 * WHAT LEAVES THIS MACHINE: normalized academic records only (title, subject,
 * due date, status, grade). Never a password, never a cookie, never the browser
 * profile, never raw page HTML.
 */
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { openSession, openForLogin, profileDir } from "../lib/watcher/session";
import { createSessionCache } from "../lib/watcher/sessionCache";
import { pruneSchoolDocs } from "../lib/watcher/schoolDocs";
import { managebacAdapter } from "../lib/watcher/adapters/managebac";
import { resolveConfiguredAdapter, sourceKeyForConnection } from "../lib/watcher/adapterSelection";
import { loginSignalHoldsSteady, loginWallHoldsSteady, STABLE_LOGIN_POLLS_REQUIRED } from "../lib/watcher/loginSignal";
import { looksLikeAuthWall } from "../lib/watcher/detect";
import { computeDelta, hasUploadableChanges, type CrawlFingerprints } from "../lib/watcher/delta";
import { nextDelayMs, applyOutcome } from "../lib/watcher/schedule";
import { classifySync, type WatcherSyncMode } from "../lib/watcher/syncMode";
import { fileDaemonLockDeps, parentIsGone, takeOverDaemonLock } from "../lib/watcher/singleInstance";
import { emptyHealth, type CrawlOutcome, type PlatformAdapter, type WatcherHealth, type WatcherPlatform } from "../lib/watcher/types";
import type { SchoolActionCapability, SchoolConnectionStatus } from "../lib/school/types";
import { overlayPassiveStatus, higherPriorityAction } from "../lib/school/status";
import { deriveSchoolStudentReport } from "../lib/school/studentReport";
import { recordBlockerTransition } from "../lib/school/incidents";
import { readReliabilitySnapshot } from "../lib/school/reliabilitySnapshot";
import { evaluatePassiveSchoolSource, type PassiveLearningWindow } from "../lib/school/passiveEngine";
import { downloadPlatformMapOnce, proposePlatformMap, reportCapabilityFailures, type PlatformMapTarget } from "../lib/watcher/platformMapSync";
import { goalsForFallback, logNavigationAttempt, startNavigationAttempt, uivisionFallbackEnabled } from "../lib/school/uivisionFallback";
import { attemptNavigationGoal, resolveUivisionExtensionPath } from "../lib/watcher/uivisionNavigator";
import type { DatabaseSync } from "node:sqlite";
import { explainChainState, readChainTelemetry, type ChainState } from "../lib/school/chainTelemetry";
import {
  ackSyncAttempt,
  claimCapturesForSync,
  failSyncAttempt,
  openSchoolJournal,
  recordSyncStage,
  recoverStaleSyncAttempts,
} from "../lib/school/journal";
import {
  SCHOOL_DISCOVERY_PROFILE_KEY,
  inferSchoolPlatform,
  isIgnoredDiscoveryURL,
  samePlatformSite,
  type SchoolPlatformConnection,
  type SchoolPlatformGuess,
} from "../lib/watcher/discovery";

const ADAPTERS: Record<string, PlatformAdapter> = {
  managebac: managebacAdapter,
};

// Kept alive across poll cycles rather than reopened every time: some
// platforms (Learnbox observed so far) authenticate with a plain
// session-only cookie (no Max-Age/Expires), which every standards-compliant
// browser discards the moment its process fully exits. Closing and
// relaunching the browser after every single poll — which used to happen
// here — throws that cookie away before the very next poll, so the session
// looks freshly expired every time even though the login itself succeeded.
// Keyed by profileKey (not platform) since Learnbox's profile key is shared
// across the discovery/login flow and the crawl.
const sessionCache = createSessionCache((platform, profileKey) => openSession(platform, { profileKey }));
const getOrOpenSession = sessionCache.get;
const closeAllSessions = sessionCache.closeAll;

/**
 * Hides the login window without closing it. Best-effort: a window that
 * fails to minimize is a cosmetic problem, not a reason to abandon a session
 * that just authenticated successfully.
 *
 * Why minimize instead of closing the window and reopening headless: for a
 * platform whose auth cookie dies the moment the browser process exits (see
 * sessionCache above), reopening at all — even headless, even instantly —
 * throws the session away before a single poll can use it. The one window
 * that is actually logged in has to be the one that keeps running.
 */
async function minimizeWindow(session: Awaited<ReturnType<typeof openForLogin>>): Promise<void> {
  try {
    const cdp = await session.context.newCDPSession(session.page);
    const { windowId } = await cdp.send("Browser.getWindowForTarget");
    await cdp.send("Browser.setWindowBounds", { windowId, bounds: { windowState: "minimized" } });
  } catch {
    // Non-Chromium-window edge cases (e.g. already closed) — leave it visible.
  }
}

const STATE_DIR = join(homedir(), ".ibacalao", "watcher");
const SCHOOL_DIR = join(homedir(), ".ibacalao", "school");
const stateFile = (platform: string) => join(STATE_DIR, `${platform}.state.json`);
const passiveStateFile = (sourceKey: string) => join(
  STATE_DIR,
  `passive-${createHash("sha256").update(sourceKey).digest("hex").slice(0, 24)}.state.json`,
);
const connectionFile = join(STATE_DIR, "connection.json");
const schoolConnectionFile = join(SCHOOL_DIR, "connection.json");
const schoolStatusFile = join(SCHOOL_DIR, "status.json");
const schoolJournalFile = join(SCHOOL_DIR, "school.db");
const learningSessionFile = join(SCHOOL_DIR, "learning.json");
const LEARNING_WINDOW_MS = 15 * 60 * 1000;
/** Must match MAX_RECORDS in app/api/watcher/ingest/route.ts. */
const INGEST_MAX_RECORDS = 200;
const DISCOVERY_RESULT_PREFIX = "IBACALAO_SCHOOL_CONNECTED\t";
const REQUIRED_LEARNING_CAPABILITIES: SchoolActionCapability[] = [
  "assignments",
  "messages",
  "grades",
  "deadlines",
  "submissions",
];

type PersistedState = {
  fingerprints: CrawlFingerprints;
  health: WatcherHealth;
  missingCounts?: Record<string, number>;
};

type PassivePersistedState = {
  fingerprints: CrawlFingerprints;
};

type BrowserCookie = Awaited<ReturnType<Awaited<ReturnType<typeof openForLogin>>["context"]["cookies"]>>[number];

function cookieFingerprint(cookies: BrowserCookie[]): string {
  return cookies
    .map((cookie) => `${cookie.name}\u0000${cookie.domain}\u0000${cookie.path}\u0000${cookie.value}`)
    .sort()
    .join("\u0001");
}

function looksLikeLoginURL(url: string): boolean {
  try {
    const parsed = new URL(url);
    return /(^|[\/_-])(login|signin|sign-in|auth|sso)([\/_-]|$)/i.test(parsed.pathname)
      || /(^|[?&])(login|signin|auth|sso)=/i.test(parsed.search);
  } catch {
    return false;
  }
}

function confirmationBaseURL(rawBaseUrl: string): URL {
  const base = new URL(rawBaseUrl);
  if (base.hostname === "app.ibacalao.com") return new URL("https://www.ibacalao.com");
  return base;
}

const CONFIRMATION_CLOSE_MS = 3_500;

/** Waits for a school sign-in and makes sure it is actually saved. If saving
 *  fails, the login window shows the error screen; its "Try again" link adds
 *  retry=1 and the student is sent back to the school sign-in. Returns false
 *  when the student closes the window or the sign-in never happens. */
async function waitForSavedLogin(
  session: Awaited<ReturnType<typeof openForLogin>>,
  loginUrl: URL,
  siteKey: string,
  platform: string,
  platformLabel: string,
  baseUrl: string,
): Promise<boolean> {
  let baselineCookies = cookieFingerprint(await session.context.cookies());
  for (;;) {
    if (!(await waitForStoredLogin(session, baselineCookies))) return false;
    if (await session.saveSessionCookies(siteKey)) return true;

    console.log(`[${platform}] sign-in was not saved; showing the error screen`);
    const failure = new URL("/school-connected", confirmationBaseURL(baseUrl));
    failure.searchParams.set("status", "error");
    failure.searchParams.set("platform", platformLabel);
    await session.page.goto(failure.toString()).catch(() => undefined);
    await session.page.bringToFront().catch(() => undefined);
    while (!session.page.isClosed() && new URL(session.page.url()).searchParams.get("retry") !== "1") {
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (session.page.isClosed()) return false;
    console.log(`[${platform}] retrying sign-in`);
    await session.page.goto(loginUrl.toString()).catch(() => undefined);
    // Already signed in counts as a fresh login here, so the save is retried.
    baselineCookies = "";
  }
}

async function waitForStoredLogin(
  session: Awaited<ReturnType<typeof openForLogin>>,
  baselineCookies: string,
  timeoutMs = 10 * 60 * 1000,
): Promise<boolean> {
  const startedAt = Date.now();
  const readings: boolean[] = [];
  while (Date.now() - startedAt < timeoutMs) {
    if (session.context.pages().length === 0) return false;
    const cookies = await session.context.cookies();
    const cookiesChanged = cookieFingerprint(cookies) !== baselineCookies;
    const currentURL = session.page.url();
    const passwordVisible = await session.page.locator('input[type="password"]:visible').count().then((count) => count > 0).catch(() => false);

    // A cookie mutation alone is too weak: analytics/CSRF cookies commonly
    // change on the login screen. Require the browser to also look like it has
    // left the credential-entry state before we tell the student it worked —
    // and require that to hold steady, not just be true on one poll.
    readings.push(cookiesChanged && !passwordVisible && !looksLikeLoginURL(currentURL));
    if (loginSignalHoldsSteady(readings)) return true;
    await new Promise((resolve) => setTimeout(resolve, 750));
  }
  return false;
}


function loadSchoolConnection(): SchoolPlatformConnection | null {
  const raw = readConnectionFile(connectionFile) ?? readConnectionFile(schoolConnectionFile);
  if (!raw) return null;
  const inferred = inferSchoolPlatform(raw.origin);
  if (inferred && inferred.platformId === raw.platformId) {
    return { ...raw, recognized: inferred.recognized, siteKey: inferred.siteKey };
  }
  return raw;
}

function readConnectionFile(path: string): SchoolPlatformConnection | null {
  try {
    return JSON.parse(readFileSync(path, "utf8")) as SchoolPlatformConnection;
  } catch {
    return null;
  }
}

function saveSchoolConnection(connection: SchoolPlatformConnection): void {
  const body = JSON.stringify(connection, null, 2);
  mkdirSync(dirname(connectionFile), { recursive: true });
  writeFileSync(connectionFile, body);
  mkdirSync(dirname(schoolConnectionFile), { recursive: true });
  writeFileSync(schoolConnectionFile, body);
}

let lastStudentReportCode: import("../lib/school/studentReport").SchoolStudentReportCode | null = null;
let lastReliabilityCheckAt = 0;
const RELIABILITY_EVERY_MS = 5 * 60 * 1000;

function persistSchoolStatus(status: SchoolConnectionStatus): void {
  mkdirSync(dirname(schoolStatusFile), { recursive: true });
  writeFileSync(schoolStatusFile, JSON.stringify(status, null, 2));
  const report = deriveSchoolStudentReport({
    status,
    ibacalaoSignedIn: true,
    crawlAuthRequired: status.actionReason === "reauth_required",
    chainState: status.chainState,
  });
  recordBlockerTransition({
    previousCode: lastStudentReportCode,
    nextCode: report.code,
    snapshot: {
      actionReason: status.actionReason,
      chainState: status.chainState ?? null,
      connected: status.connected,
    },
  });
  lastStudentReportCode = report.code;
}

function saveSchoolStatus(status: SchoolConnectionStatus): void {
  persistSchoolStatus(status);
}

function loadSchoolStatus(): SchoolConnectionStatus | null {
  try {
    return JSON.parse(readFileSync(schoolStatusFile, "utf8")) as SchoolConnectionStatus;
  } catch {
    return null;
  }
}

function loadActiveLearningWindow(
  connection: SchoolPlatformConnection,
  sourceKey: string,
  nowMs = Date.now(),
): PassiveLearningWindow | null {
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(learningSessionFile, "utf8"));
  } catch {
    return null;
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const value = raw as Record<string, unknown>;
  if (value.sourceKey !== sourceKey || value.origin !== connection.origin || typeof value.startedAt !== "string") return null;
  const startedAtMs = Date.parse(value.startedAt);
  if (!Number.isFinite(startedAtMs) || startedAtMs > nowMs + 60_000 || nowMs - startedAtMs > LEARNING_WINDOW_MS) return null;
  const allowed = new Set<SchoolActionCapability>(REQUIRED_LEARNING_CAPABILITIES);
  const missingCapabilities = Array.isArray(value.missingCapabilities)
    ? value.missingCapabilities.filter((item): item is SchoolActionCapability => typeof item === "string" && allowed.has(item as SchoolActionCapability))
    : [];
  return { startedAt: value.startedAt, missingCapabilities };
}

function sourceKeyForLoadedConnection(connection: SchoolPlatformConnection): string {
  return sourceKeyForConnection(connection, ADAPTERS);
}

function statusForConnection(
  connection: SchoolPlatformConnection,
  overrides: Partial<SchoolConnectionStatus> = {},
): SchoolConnectionStatus {
  const hasBundledAdapter = Boolean(resolveConfiguredAdapter(connection, ADAPTERS));
  const needsLearning = !hasBundledAdapter;
  return {
    sourceKey: sourceKeyForLoadedConnection(connection),
    platformLabel: connection.platformLabel,
    ...(connection.schoolLabel ? { schoolLabel: connection.schoolLabel } : {}),
    connected: true,
    syncMode: hasBundledAdapter ? "verified_background" : "passive_browser",
    actionReason: needsLearning ? "manual_learning_required" : "none",
    lastObservedAt: new Date().toISOString(),
    recipe: hasBundledAdapter
      ? { state: "healthy", confidence: 1, version: "bundled-adapter" }
      : { state: "missing" },
    ...(needsLearning ? { missingCapabilities: REQUIRED_LEARNING_CAPABILITIES } : {}),
    ...overrides,
  };
}

function saveWatcherStatus(
  adapter: PlatformAdapter,
  health: WatcherHealth,
  connection: SchoolPlatformConnection | null,
  actionReason: SchoolConnectionStatus["actionReason"],
  outcome?: Extract<CrawlOutcome, { ok: true }>,
): void {
  const matchingConnection = connection?.platformId === adapter.platform ? connection : null;
  const platformLabel = matchingConnection?.platformLabel ?? adapter.label;
  const capabilities = outcome?.capabilities;
  const incompleteCapabilities = capabilities
    ?.filter((entry) => entry.state === "partial" || entry.completeness === "partial")
    .map((entry) => entry.capability);
  const repairing = capabilities?.some((entry) => entry.state === "repairing");
  const resolvedAction = actionReason === "none" && repairing ? "recipe_repairing" : actionReason;
  const status: SchoolConnectionStatus = {
    sourceKey: matchingConnection ? sourceKeyForLoadedConnection(matchingConnection) : `vendor:${adapter.platform}`,
    platformLabel,
    ...(matchingConnection?.schoolLabel ? { schoolLabel: matchingConnection.schoolLabel } : {}),
    connected: resolvedAction !== "reauth_required",
    syncMode: "verified_background",
    actionReason: resolvedAction,
    ...(health.lastSuccessAt ? { lastSuccessAt: health.lastSuccessAt } : {}),
    ...(health.lastAttemptAt ? { lastObservedAt: health.lastAttemptAt } : {}),
    recipe: {
      state: resolvedAction === "none" ? "healthy" : resolvedAction === "recipe_repairing" ? "repairing" : "stale",
      confidence: 1,
      version: "bundled-adapter",
    },
    ...(capabilities && capabilities.length > 0 ? { capabilities } : {}),
    ...(incompleteCapabilities && incompleteCapabilities.length > 0 ? { incompleteCapabilities } : {}),
  };
  saveSchoolStatus(status);
}

function maybeApplyReliability(connection: SchoolPlatformConnection | null): void {
  if (!connection) return;
  const now = Date.now();
  if (now - lastReliabilityCheckAt < RELIABILITY_EVERY_MS) return;
  lastReliabilityCheckAt = now;
  const sourceKey = sourceKeyForLoadedConnection(connection);
  const snapshot = readReliabilitySnapshot({ sourceKey });
  const current = loadSchoolStatus();
  if (!current) return;
  if (snapshot.chain === "healthy" || snapshot.chain === "browser_not_observed") return;
  if (current.actionReason === "reauth_required" || current.actionReason === "challenge_paused") return;
  saveSchoolStatus({
    ...current,
    actionReason: higherPriorityAction(current.actionReason, "connector_stale"),
    connected: false,
    chainState: snapshot.chain,
  });
}

async function hasVisiblePassword(page: Awaited<ReturnType<typeof openForLogin>>["page"]): Promise<boolean> {
  return page.locator('input[type="password"]:visible').count().then((count) => count > 0).catch(() => false);
}

async function waitForDiscoveredLogin(
  session: Awaited<ReturnType<typeof openForLogin>>,
  timeoutMs = 10 * 60 * 1000,
): Promise<SchoolPlatformConnection | null> {
  const startedAt = Date.now();
  let candidate: SchoolPlatformGuess | null = null;
  let candidateCookies = "";
  // Same steady-reading requirement as waitForStoredLogin, and for the same
  // reason: a transient non-login page (forgot-password, an intermediate
  // redirect) can momentarily hide the password field without any real
  // authentication having happened.
  let stableCount = 0;

  while (Date.now() - startedAt < timeoutMs) {
    const pages = session.context.pages();
    if (pages.length === 0) return null;

    for (const page of [...pages].reverse()) {
      const currentURL = page.url();
      if (!currentURL || currentURL === "about:blank" || isIgnoredDiscoveryURL(currentURL)) continue;

      const title = await page.title().catch(() => "");
      const guess = inferSchoolPlatform(currentURL, title);
      if (!guess) continue;
      const passwordVisible = await hasVisiblePassword(page);
      const looksLikeEntry = guess.recognized || passwordVisible || looksLikeLoginURL(currentURL);
      const cookiesNow = cookieFingerprint(await session.context.cookies());

      if (looksLikeEntry && (!candidate || !samePlatformSite(currentURL, candidate))) {
        candidate = guess;
        candidateCookies = cookiesNow;
        stableCount = 0;
        continue;
      }
      if (!candidate || !samePlatformSite(currentURL, candidate)) continue;

      const authenticatedShape = !passwordVisible && !looksLikeLoginURL(currentURL);
      stableCount = authenticatedShape && cookiesNow !== candidateCookies ? stableCount + 1 : 0;
      if (loginSignalHoldsSteady(Array(stableCount).fill(true))) {
        const finalGuess = inferSchoolPlatform(currentURL, title) ?? candidate;
        return {
          ...finalGuess,
          profileKey: SCHOOL_DISCOVERY_PROFILE_KEY,
          connectedAt: new Date().toISOString(),
        };
      }
    }

    await new Promise((resolve) => setTimeout(resolve, 350));
  }
  return null;
}

function loadState(platform: WatcherPlatform): PersistedState {
  try {
    return JSON.parse(readFileSync(stateFile(platform), "utf8")) as PersistedState;
  } catch {
    return { fingerprints: {}, health: emptyHealth(platform) };
  }
}

function saveState(platform: WatcherPlatform, state: PersistedState): void {
  mkdirSync(dirname(stateFile(platform)), { recursive: true });
  writeFileSync(stateFile(platform), JSON.stringify(state, null, 2));
}

function loadPassiveState(sourceKey: string): PassivePersistedState {
  try {
    return JSON.parse(readFileSync(passiveStateFile(sourceKey), "utf8")) as PassivePersistedState;
  } catch {
    return { fingerprints: {} };
  }
}

function savePassiveState(sourceKey: string, state: PassivePersistedState): void {
  const file = passiveStateFile(sourceKey);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(state, null, 2));
}

/** Best-effort: keep macOS awake while polling. No-op elsewhere. */
function keepAwake(): ChildProcess | null {
  if (process.platform !== "darwin") return null;
  try {
    // -i prevents idle sleep, -m prevents disk sleep. Deliberately NOT -d:
    // there is no reason to keep the display on for a headless crawl.
    // -w: caffeinate exits when this watcher does, even if it is SIGKILLed
    // and never reaches its cleanup — otherwise it kept the Mac awake forever.
    const child = spawn("caffeinate", ["-i", "-m", "-w", String(process.pid)], { stdio: "ignore" });
    child.unref();
    return child;
  } catch {
    return null;
  }
}

export type WatcherIngestResult = {
  recordsStored: number;
  eventsRecorded: number;
  mode?: WatcherSyncMode;
};

async function upload(
  sourceKey: string,
  records: unknown[],
  mode: WatcherSyncMode,
  removedIds: string[],
  baseUrl: string,
  token: string,
  legacyPlatform?: string,
): Promise<WatcherIngestResult> {
  // The ingest route rejects >200 records. A bootstrap crawl can exceed that,
  // and an unsplit upload would fail forever. Re-sending chunks after a partial
  // failure is safe: server writes merge by record id and events are idempotent.
  let last: WatcherIngestResult = { recordsStored: 0, eventsRecorded: 0, mode };
  for (let start = 0; start === 0 || start < records.length; start += INGEST_MAX_RECORDS) {
    const isLast = start + INGEST_MAX_RECORDS >= records.length;
    const response = await fetch(`${baseUrl}/api/watcher/ingest`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({
        sourceKey,
        ...(legacyPlatform ? { platform: legacyPlatform } : {}),
        records: records.slice(start, start + INGEST_MAX_RECORDS),
        mode,
        removedIds: isLast ? removedIds : [],
      }),
    });
    if (!response.ok) {
      throw new Error(`ingest failed: ${response.status} ${await response.text()}`);
    }
    last = (await response.json()) as WatcherIngestResult;
    console.log(
      `[${sourceKey}] uploaded ${last.recordsStored} records, ${last.eventsRecorded} new events (${last.mode ?? mode})`,
    );
  }
  return last;
}

const HEARTBEAT_EVERY_MS = 10 * 60 * 1000;
const lastHeartbeatAt = new Map<string, number>();

/** Proof of life even when nothing changed, so the server can tell a quiet
 *  school from a dead watcher. Throttled per source; best effort. */
async function heartbeat(sourceKey: string, lastSuccessAt: string | null, baseUrl: string, token: string): Promise<void> {
  const now = Date.now();
  if (now - (lastHeartbeatAt.get(sourceKey) ?? 0) < HEARTBEAT_EVERY_MS) return;
  lastHeartbeatAt.set(sourceKey, now);
  await fetch(`${baseUrl}/api/watcher/heartbeat`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ sourceKey, ...(lastSuccessAt ? { lastSuccessAt } : {}) }),
  }).catch((error) => console.warn(`[${sourceKey}] heartbeat failed:`, error));
}

/** An upload interrupted for longer than this is assumed dead and its evidence
 *  is offered again. The server's mutation identity absorbs a double delivery;
 *  a capture nobody ever retries is lost for good. */
const STALE_SYNC_ATTEMPT_MS = 10 * 60 * 1000;

type DeliveryLineage = { db: DatabaseSync; syncAttemptId: string } | null;

/**
 * Opens the journal and claims this poll's evidence. Shadow mode: the NDJSON
 * ring is still the source of truth, so every failure here is reported and
 * swallowed rather than costing the student a sync.
 */
function beginDeliveryLineage(sourceKey: string, syncMode: WatcherSyncMode): DeliveryLineage {
  let db: DatabaseSync | null = null;
  try {
    db = openSchoolJournal(schoolJournalFile);
    recoverStaleSyncAttempts(db, { olderThanMs: STALE_SYNC_ATTEMPT_MS });
    const claimed = claimCapturesForSync(db, { sourceKey, syncMode, syncAttemptId: randomUUID() });
    if (!claimed) {
      db.close();
      return null;
    }
    // Extraction and reconciliation already happened inside the passive engine.
    recordSyncStage(db, claimed.attempt.syncAttemptId, "extract_succeeded_at");
    recordSyncStage(db, claimed.attempt.syncAttemptId, "reconciled_at");
    recordSyncStage(db, claimed.attempt.syncAttemptId, "upload_started_at");
    return { db, syncAttemptId: claimed.attempt.syncAttemptId };
  } catch (error) {
    db?.close();
    console.warn(`[${sourceKey}] delivery lineage unavailable:`, error instanceof Error ? error.message : error);
    return null;
  }
}

function endDeliveryLineage(
  lineage: DeliveryLineage,
  outcome: { acked: boolean; serverAck?: unknown; error?: unknown },
): void {
  if (!lineage) return;
  try {
    if (outcome.acked) {
      ackSyncAttempt(lineage.db, lineage.syncAttemptId, outcome.serverAck ?? { mode: "passive" });
    } else {
      const message = outcome.error instanceof Error ? outcome.error.message : String(outcome.error ?? "unknown");
      failSyncAttempt(lineage.db, lineage.syncAttemptId, message, { blockedByAuth: /\b401\b/.test(message) });
    }
  } catch (error) {
    console.warn("[school] delivery lineage write failed:", error instanceof Error ? error.message : error);
  } finally {
    lineage.db.close();
  }
}

/** Best effort: the journal is still shadow state, so its absence must not
 *  change what the student sees. */
function readChainState(sourceKey: string): ChainState | null {
  let db: DatabaseSync | null = null;
  try {
    db = openSchoolJournal(schoolJournalFile);
    return explainChainState(readChainTelemetry(db, sourceKey));
  } catch {
    return null;
  } finally {
    db?.close();
  }
}

function platformMapTarget(connection: SchoolPlatformConnection): PlatformMapTarget {
  return {
    platformId: connection.platformId,
    recognized: connection.recognized,
    origin: connection.origin,
    sourceKey: sourceKeyForLoadedConnection(connection),
    journalFile: schoolJournalFile,
  };
}

async function processPassiveConnection(
  connection: SchoolPlatformConnection,
  baseUrl: string,
  token: string,
): Promise<number> {
  const sourceKey = sourceKeyForLoadedConnection(connection);
  const previousCapabilities = loadSchoolStatus()?.capabilities;
  const evaluation = await evaluatePassiveSchoolSource({
    sourceKey,
    origin: connection.origin,
    platformLabel: connection.platformLabel,
    ...(connection.schoolLabel ? { schoolLabel: connection.schoolLabel } : {}),
  }, {
    learningWindow: loadActiveLearningWindow(connection, sourceKey),
    // Shadow mode: mirror the same evidence into the SQLite journal so the two
    // stores can be compared on real browsing. Nothing reads from it yet.
    journalFile: schoolJournalFile,
    // Carry failure streaks across polls: the student browsing only their inbox
    // must not reset what we know about grades.
    ...(previousCapabilities ? { previousCapabilities } : {}),
  });
  const state = loadPassiveState(sourceKey);
  if (evaluation.records.length > 0) {
    const hasBaseline = Object.keys(state.fingerprints).length > 0;
    const delta = computeDelta(evaluation.records, state.fingerprints);
    const mode = hasBaseline ? "incremental" : "bootstrap";
    // Lineage claims this poll's evidence before the upload, so a crash between
    // here and the server's reply leaves it owed rather than quietly finished.
    const lineage = beginDeliveryLineage(sourceKey, mode);
    try {
      let serverAck: unknown = { mode, skipped: "no_uploadable_delta" };
      if (hasUploadableChanges(delta)) {
        serverAck = await upload(sourceKey, [...delta.added, ...delta.changed], mode, [], baseUrl, token);
      }
      endDeliveryLineage(lineage, { acked: true, serverAck });
    } catch (error) {
      endDeliveryLineage(lineage, { acked: false, error });
      throw error;
    }
    // Do not erase the baseline merely because there is no fresh local browser
    // observation or the student is currently on an unrelated portal page.
    // Removals are intentionally non-uploadable, so preserving fingerprints is
    // the only behavior that avoids re-uploading the whole corpus next visit.
    state.fingerprints = delta.fingerprints;
    savePassiveState(sourceKey, state);
  }
  // Only surface a successful passive sync after any required server upload
  // completed. An ingest failure must not look healthy in Settings.
  const chainState = readChainState(sourceKey);
  const nextStatus = chainState ? { ...evaluation.status, chainState } : evaluation.status;
  saveSchoolStatus(overlayPassiveStatus(loadSchoolStatus(), nextStatus));

  if (evaluation.learnedRecipes || evaluation.repairedRecipes) {
    console.log(
      `[${sourceKey}] passive engine learned=${evaluation.learnedRecipes} repaired=${evaluation.repairedRecipes} records=${evaluation.records.length}`,
    );
    await proposePlatformMap(platformMapTarget(connection), baseUrl, token);
  }
  // ponytail: passive sources don't report failures yet (this loop runs every
  // 2s); add reportCapabilityFailures here when a passive-only platform ships.
  await downloadPlatformMapOnce(platformMapTarget(connection), baseUrl, token);
  // The native capture journal retains up to 24 hours so daemon downtime can
  // catch up. Poll only the local file at a short cadence while this source has
  // no bundled adapter; this causes zero traffic to the school platform itself.
  return 2_000;
}

async function pollOnce(
  adapter: PlatformAdapter,
  baseUrl: string,
  token: string,
): Promise<number | null> {
  const platform = adapter.platform;
  const state = loadState(platform);
  const connection = loadSchoolConnection();
  const ingestKey = connection?.platformId === platform
    ? sourceKeyForLoadedConnection(connection)
    : platform;
  const profileKey = connection?.platformId === platform ? connection.profileKey : platform;
  const session = await getOrOpenSession(platform, profileKey);

  const outcome = await adapter.crawl(session.page);

  if (!outcome.ok) {
    state.health = applyOutcome(state.health, outcome);
    saveState(platform, state);
    if (outcome.reason === "challenged") {
      saveWatcherStatus(adapter, state.health, connection, "challenge_paused");
      console.warn(`[${platform}] ${outcome.reason}`);
      return null;
    }
    if (outcome.reason === "auth_required") {
      // One immediate retry handles transient login-wall-shaped responses
      // without touching a live browser session. If the school still says the
      // session is dead, replay the last session cookies captured after a
      // successful crawl and give that saved session exactly one chance before
      // asking the student to sign in again. This is what recovers Learnbox
      // when Chromium kept a stale same-name session cookie in the profile.
      let retry = await adapter.crawl(session.page);
      if (!retry.ok && retry.reason === "auth_required") {
        const restored = await session.restoreSavedSessionCookies({ replaceExisting: true });
        if (restored > 0) {
          console.log(`[${platform}] auth wall persisted; retrying once with saved session cookies`);
          retry = await adapter.crawl(session.page);
        }
      }
      if (retry.ok) {
        if (connection?.siteKey) await session.saveSessionCookies(connection.siteKey);
        return applySuccessfulCrawl(adapter, baseUrl, token, state, connection, ingestKey, retry);
      }
      if (retry.reason === "challenged") {
        state.health = applyOutcome(state.health, retry);
        saveState(platform, state);
        saveWatcherStatus(adapter, state.health, connection, "challenge_paused");
        console.warn(`[${platform}] ${retry.reason}`);
        return null;
      }
      if (retry.reason !== "auth_required") {
        console.warn(`[${platform}] auth recovery retry failed: ${retry.reason}`);
        return nextDelayMs(state.health, {});
      }
      const readings: boolean[] = [];
      for (let i = 0; i < STABLE_LOGIN_POLLS_REQUIRED; i++) {
        const url = session.page.url();
        const html = await session.page.content().catch(() => "");
        const passwordVisible = await hasVisiblePassword(session.page);
        readings.push(looksLikeAuthWall(url, html) || looksLikeLoginURL(url) || passwordVisible);
        await new Promise((resolve) => setTimeout(resolve, 750));
      }
      if (loginWallHoldsSteady(readings)) {
        saveWatcherStatus(adapter, state.health, connection, "reauth_required");
        console.warn(`[${platform}] login wall held steady — pausing LMS traffic, keeping the browser profile`);
        return null;
      }
      console.warn(`[${platform}] transient auth_required — not closing the session`);
      return nextDelayMs(state.health, {});
    }
    console.warn(`[${platform}] ${outcome.reason}`);
    return nextDelayMs(state.health, {});
  }

  // Keeps a session-only school login alive across app relaunches and reboots.
  if (connection?.siteKey) await session.saveSessionCookies(connection.siteKey);
  return applySuccessfulCrawl(adapter, baseUrl, token, state, connection, ingestKey, outcome);
}

async function applySuccessfulCrawl(
  adapter: PlatformAdapter,
  baseUrl: string,
  token: string,
  state: PersistedState,
  connection: SchoolPlatformConnection | null,
  ingestKey: string,
  outcome: Extract<CrawlOutcome, { ok: true }>,
): Promise<number | null> {
  const platform = adapter.platform;
  // Classified BEFORE fingerprints are overwritten below — "did we have
  // anything to compare against" is exactly what state.fingerprints being
  // empty right now means.
  const mode = classifySync(Object.keys(state.fingerprints).length > 0, state.health.lastSuccessAt);
  const delta = computeDelta(outcome.records, state.fingerprints);

  // A single disappearance is not authoritative: portals paginate and
  // transiently hide rows. Require the same id to be absent on two
  // consecutive successful crawls before removing it from server state.
  const missingCounts = { ...(state.missingCounts ?? {}) };
  for (const id of Object.keys(delta.fingerprints)) delete missingCounts[id];
  for (const id of delta.removedIds) missingCounts[id] = (missingCounts[id] ?? 0) + 1;
  const confirmedRemovedIds = delta.removedIds.filter((id) => missingCounts[id] >= 2);

  if (hasUploadableChanges(delta) || confirmedRemovedIds.length > 0) {
    if (mode === "bootstrap") {
      console.log(`[${platform}] bootstrap sync — ${delta.added.length} pre-existing records establishing the baseline, not new work`);
    }
    try {
      await upload(ingestKey, [...delta.added, ...delta.changed], mode, confirmedRemovedIds, baseUrl, token, platform);
    } catch (error) {
      // The crawl already succeeded; only our API failed (expired token,
      // outage). Back off exponentially instead of letting the main loop
      // re-crawl the school platform every 5 minutes. Fingerprints stay
      // unsaved so the next poll re-uploads the same delta.
      state.health = applyOutcome(state.health, { ok: false, reason: "error", message: String(error) });
      saveState(platform, state);
      // The school session just worked, so never leave an old
      // reauth_required telling the student to sign in to school again.
      saveWatcherStatus(adapter, state.health, connection, "connector_stale", outcome);
      console.error(`[${platform}] upload failed:`, error);
      return nextDelayMs(state.health, {});
    }
    for (const id of confirmedRemovedIds) delete missingCounts[id];
  } else {
    console.log(`[${platform}] no changes (${outcome.records.length} records seen)`);
  }
  state.missingCounts = missingCounts;

  // Keep a once-missing id in the comparison baseline until a second
  // successful crawl confirms the absence. Otherwise it disappears from the
  // baseline immediately and can never accumulate the second strike.
  const nextFingerprints = { ...delta.fingerprints };
  for (const id of delta.removedIds) {
    if (!confirmedRemovedIds.includes(id) && state.fingerprints[id] !== undefined) {
      nextFingerprints[id] = state.fingerprints[id];
    }
  }

  // Fingerprints are persisted only AFTER a successful upload, so a failed
  // upload is retried next poll rather than being silently forgotten.
  state.fingerprints = nextFingerprints;
  state.health = applyOutcome(state.health, { ok: true });
  saveState(platform, state);
  saveWatcherStatus(adapter, state.health, connection, "none", outcome);

  if (connection?.platformId === platform) {
    // Shared platform map: additive and best effort, none of these can throw.
    const target = platformMapTarget(connection);
    await downloadPlatformMapOnce(target, baseUrl, token);
    await proposePlatformMap(target, baseUrl, token);
    await reportCapabilityFailures(target, outcome.capabilities, baseUrl, token);
  }

  return nextDelayMs(state.health, {});
}

/**
 * Phase 1-5 fallback entry point: `npm run watcher:daemon -- --uivision-fallback`.
 * Deliberately its own session (never the polling session) so ordinary polls
 * never pay the extension startup cost. Fails closed at every step: missing
 * flag, missing connection, missing extension artifact, or a wrong
 * actionReason all end in "did nothing", never a crash or a false success.
 */
async function runUivisionFallbackOnce(): Promise<void> {
  if (!uivisionFallbackEnabled()) {
    console.log("[uivision] fallback disabled (set IBACALAO_SCHOOL_UIVISION_FALLBACK=1 to enable)");
    return;
  }
  const runtimeRoot = process.env.IBACALAO_UIVISION_RUNTIME_ROOT ?? join(homedir(), ".ibacalao", "watcher-runtime");
  const extensionPath = resolveUivisionExtensionPath(runtimeRoot);
  if (!extensionPath) {
    console.log(`[uivision] no pinned extension artifact at ${runtimeRoot}/uivision/extension — Phase 0/6 not shipped yet`);
    return;
  }
  const connection = loadSchoolConnection();
  const status = loadSchoolStatus();
  if (!connection || !status) {
    console.log("[uivision] no active school connection — nothing to fall back for");
    return;
  }
  const goals = goalsForFallback(status, status.missingCapabilities ?? []);
  if (goals.length === 0) {
    console.log(`[uivision] actionReason is "${status.actionReason}", not manual_learning_required — nothing to do`);
    return;
  }

  console.log(`[uivision] attempting ${goals.length} goal(s) in a dedicated fallback session`);
  // Reuse the SAME persistent profile as the normal watcher session for this
  // platform — the fallback must never force a second login. Only the
  // extension and visibility differ from the ordinary poll session.
  const session = await openSession(connection.platformId, {
    headless: false,
    extensionPath,
    profileKey: connection.profileKey,
  });
  try {
    await session.page.goto(connection.origin);
    for (const goal of goals) {
      const attempt = startNavigationAttempt(goal);
      const result = await attemptNavigationGoal(session.page, goal, { schoolOrigin: connection.origin });
      logNavigationAttempt(attempt, result);
      console.log(`[uivision] ${goal}: ${result.state}${result.observedUrl ? ` (${result.observedUrl})` : ""}`);
      if (result.state === "challenged" || result.state === "auth_required") {
        console.log("[uivision] stopping the whole fallback session on a fail-closed signal");
        break;
      }
    }
  } finally {
    await session.close();
  }
}

// Timestamp every daemon.log line so incidents.jsonl can be matched to what the
// watcher was doing. Machine-readable IBACALAO_* lines stay bare: the Mac app
// matches them with hasPrefix (SchoolWatcherService.parseDiscoveryOutput).
for (const level of ["log", "warn", "error"] as const) {
  const write = console[level].bind(console);
  console[level] = (...args: unknown[]) => {
    if (typeof args[0] === "string" && args[0].startsWith("IBACALAO_")) write(...args);
    else write(new Date().toISOString(), ...args);
  };
}

async function main(): Promise<void> {
  // Isolated fallback CLI entry (Phase 1-5). Never runs during --discover,
  // --login or the normal polling loop below — those paths are unchanged.
  // Kill switch is default-off (uivisionFallbackEnabled), and the extension
  // artifact is absent until Phase 0/6 ship it, so this is a no-op today.
  if (process.argv.slice(2).includes("--uivision-fallback")) {
    await runUivisionFallbackOnce();
    return;
  }

  const args = process.argv.slice(2);
  // ponytail: prune once per launch; the app's SchoolDocHandler also prunes on
  // every list, so a long-running daemon doesn't leave files past 30 days.
  pruneSchoolDocs();

  const valueAfter = (flag: string): string | undefined => {
    const index = args.indexOf(flag);
    return index === -1 ? undefined : args[index + 1];
  };

  if (args.includes("--discover")) {
    console.log("Opening the iBacalao browser. Search for your school platform and sign in normally.");
    console.log(`Profile: ${profileDir(SCHOOL_DISCOVERY_PROFILE_KEY)}`);
    const session = await openForLogin(SCHOOL_DISCOVERY_PROFILE_KEY, "https://www.google.com/");
    const connection = await waitForDiscoveredLogin(session);
    if (connection) {
      saveSchoolConnection(connection);
      saveSchoolStatus(statusForConnection(connection));
      console.log(`${DISCOVERY_RESULT_PREFIX}${JSON.stringify(connection)}`);

      if (session.context.pages().length > 0) {
        const baseUrl = valueAfter("--base-url") ?? process.env.IBACALAO_URL ?? "https://app.ibacalao.com";
        const confirmation = new URL("/school-connected", confirmationBaseURL(baseUrl));
        confirmation.searchParams.set("platform", connection.platformLabel);
        if (connection.schoolLabel) confirmation.searchParams.set("school", connection.schoolLabel);
        confirmation.searchParams.set("returning", "1");
        const page = session.context.pages().at(-1) ?? session.page;
        await page.goto(confirmation.toString()).catch(() => undefined);
        await new Promise((resolve) => setTimeout(resolve, CONFIRMATION_CLOSE_MS));
      }
      await session.close();
      return;
    }

    // Discovery timed out or the student closed the browser. Close cleanly so
    // Chromium flushes whatever local profile state exists, but do not claim a
    // connection unless the authenticated platform was actually detected.
    await session.close().catch(() => undefined);
    return;
  }

  const loginIndex = args.indexOf("--login");
  if (loginIndex !== -1) {
    const platform = args[loginIndex + 1] ?? "school-platform";
    const platformLabel = valueAfter("--label")?.trim() || platform;
    const loginUrl = valueAfter("--url") ?? (platform === "managebac" ? "https://managebac.com/login" : undefined);
    if (!loginUrl) {
      throw new Error("--login for a non-ManageBac platform requires --url https://…");
    }
    const parsed = new URL(loginUrl);
    if (parsed.protocol !== "https:" && !(parsed.protocol === "http:" && ["localhost", "127.0.0.1"].includes(parsed.hostname))) {
      throw new Error("school login URL must use HTTPS");
    }
    console.log(`Opening a browser for ${platform}. Log in, then close the window.`);
    console.log(`Profile: ${profileDir(platform)}`);
    const profileKey = valueAfter("--profile-key")?.trim() || platform;
    const session = await openForLogin(profileKey, parsed.toString());
    const baseUrl = valueAfter("--base-url") ?? process.env.IBACALAO_URL ?? "https://app.ibacalao.com";
    const knownConnection = loadSchoolConnection();
    const loginSite = (knownConnection?.platformId === platform && knownConnection.siteKey) || parsed.hostname;
    const stored = await waitForSavedLogin(session, parsed, loginSite, platform, platformLabel, baseUrl);
    if (stored && session.context.pages().length > 0) {
      const connection = loadSchoolConnection();
      if (
        connection
        && connection.platformId === platform
        && !resolveConfiguredAdapter(connection, ADAPTERS)
      ) {
        // Unknown portals still need the passive learning path. For a bundled
        // adapter, deliberately leave reauth_required in place until the
        // restarted daemon completes a real successful crawl and clears it.
        saveSchoolStatus(statusForConnection(connection, {
          actionReason: "manual_learning_required",
        }));
      }
      const confirmation = new URL("/school-connected", confirmationBaseURL(baseUrl));
      confirmation.searchParams.set("platform", platformLabel);
      const confirmationPage = await session.context.newPage();
      await confirmationPage.goto(confirmation.toString());
      await confirmationPage.bringToFront();
      console.log(`[${platform}] login persisted; confirmation opened`);
      // The page counts "Closing in 3, 2, 1"; close the tab here too in case the
      // browser blocks window.close().
      await new Promise((resolve) => setTimeout(resolve, CONFIRMATION_CLOSE_MS));
      await confirmationPage.close().catch(() => undefined);

      // Seamless handoff: a token means this process can become the
      // background watcher itself, using the browser that is already
      // authenticated, instead of exiting and making a second, cold-started
      // process open a fresh browser — which for a session-cookie platform
      // like Learnbox is already logged out by the time it opens (the login
      // browser closing is exactly what discards that cookie).
      const token = await resolveToken(args);
      if (token) {
        sessionCache.adopt(profileKey, session);
        await minimizeWindow(session);
        console.log(`[${platform}] continuing as the background watcher — no second login needed`);
        await runPollingLoop(args, baseUrl, token);
        return;
      }
    }
    // Hold the process open until the student closes the browser themselves.
    // Closing it for them could discard the newly-established session before
    // Chromium flushes the persistent profile to disk.
    if (session.context.pages().length > 0) {
      await new Promise<void>((resolve) => session.context.on("close", () => resolve()));
    }
    return;
  }

  const token = await resolveToken(args);
  if (!token) {
    console.error("No iBacalao session token was supplied.");
    process.exit(1);
  }
  const baseUrl = valueAfter("--base-url") ?? process.env.IBACALAO_URL ?? "https://app.ibacalao.com";
  await runPollingLoop(args, baseUrl, token);
}

/** Reads the token from `IBACALAO_TOKEN`, falling back to one line of stdin
 *  when `--token-stdin` is passed. Extracted so the `--login` path can also
 *  resolve a token and continue straight into polling with the same
 *  already-authenticated browser, instead of exiting and forcing a second,
 *  cold-started process to open a fresh (and for a session-cookie platform
 *  like Learnbox, already-dead) browser. */
function readStoredWatcherToken(): string | null {
  try {
    const stored = readFileSync(join(homedir(), ".ibacalao", "watcher", "token"), "utf8").trim();
    if (stored) return stored;
  } catch {
    // No file credential yet.
  }
  if (process.platform !== "darwin") return null;
  try {
    const session = execFileSync(
      "security",
      ["find-generic-password", "-s", "com.ibacalao.LiveExaminerOverlay", "-a", "ibacalao-session", "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
    ).trim();
    return session || null;
  } catch {
    return null;
  }
}

async function resolveToken(args: string[]): Promise<string | null> {
  const envToken = process.env.IBACALAO_TOKEN?.trim();
  if (envToken) return envToken;
  // The token the app just minted wins over the file. The file is only for
  // CLI runs, and the app revokes every watcher token when it quits, so
  // preferring the file made every restarted daemon upload with a dead token.
  if (!args.includes("--token-stdin")) return readStoredWatcherToken();
  return new Promise<string>((resolve, reject) => {
    let input = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      input += chunk;
      if (input.includes("\n")) {
        process.stdin.pause();
        resolve(input.slice(0, input.indexOf("\n")).trim());
      }
    });
    process.stdin.on("end", () => resolve(input.trim()));
    process.stdin.on("error", reject);
  });
}

async function runPollingLoop(args: string[], baseUrl: string, token: string): Promise<void> {
  const once = args.includes("--once");
  const configuredConnection = loadSchoolConnection();
  const configuredAdapter = resolveConfiguredAdapter(configuredConnection, ADAPTERS);
  const adapters = configuredConnection
    ? (configuredAdapter ? [configuredAdapter] : [])
    : Object.values(ADAPTERS);

  // One polling watcher per Mac (lib/watcher/singleInstance.ts). A one-shot
  // CLI run never takes the lock, so it can't stop the app's own watcher.
  const lock = once ? null : fileDaemonLockDeps(join(STATE_DIR, "daemon.pid"));
  const caffeine = once ? null : keepAwake();
  let stopping = false;
  const shutdown = () => {
    if (stopping) return;
    stopping = true;
    // Closing the context (not just killing the process) is what flushes
    // cookies to the profile directory — an unflushed session-only cookie
    // would otherwise look logged-out on the next start for no reason.
    closeAllSessions().finally(() => {
      caffeine?.kill();
      lock?.release(process.pid);
      process.exit(0);
    });
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);

  if (lock) {
    mkdirSync(STATE_DIR, { recursive: true });
    if (!(await takeOverDaemonLock(process.pid, lock))) {
      console.error("Another school watcher is running (another iBacalao app owns it, or it did not stop); exiting instead of sharing its browser.");
      caffeine?.kill();
      process.exit(1);
    }
  }
  if (!once && process.env.IBACALAO_DESKTOP_BUNDLED === "1") {
    // The app stops this process on a clean quit; a crash or Force Quit skips
    // that, so notice the parent disappearing instead of running orphaned.
    const startPpid = process.ppid;
    setInterval(() => {
      if (!parentIsGone(startPpid, process.ppid)) return;
      console.log("iBacalao app is gone; stopping this watcher so the next launch starts clean");
      shutdown();
    }, 10_000).unref();
  }

  try {
    const pausedPlatforms = new Set<WatcherPlatform>();
    for (;;) {
      let nextWait = Number.POSITIVE_INFINITY;
      for (const adapter of adapters) {
        const ingestKey = configuredConnection?.platformId === adapter.platform
          ? sourceKeyForLoadedConnection(configuredConnection)
          : adapter.platform;
        // Before the pause check: a paused (reauth) source still proves the
        // daemon is alive, and its stale lastSuccessAt tells the server why.
        await heartbeat(ingestKey, loadState(adapter.platform).health.lastSuccessAt, baseUrl, token);
        if (pausedPlatforms.has(adapter.platform)) continue;
        try {
          const delay = await pollOnce(adapter, baseUrl, token);
          if (delay === null) {
            pausedPlatforms.add(adapter.platform);
            continue;
          }
          nextWait = Math.min(nextWait, delay);
        } catch (error) {
          // One platform failing must not take the loop down; its own health
          // record already governs when it is tried again.
          console.error(`[${adapter.platform}] poll threw:`, error);
          nextWait = Math.min(nextWait, 5 * 60 * 1000);
        }
      }
      maybeApplyReliability(configuredConnection);
      const runPassive = Boolean(
        configuredConnection
        && (!configuredAdapter || pausedPlatforms.has(configuredAdapter.platform)),
      );
      if (runPassive && configuredConnection) {
        // Proof of life comes first: a passive run that throws still means the
        // daemon is alive, and that must read as failing, not offline.
        await heartbeat(sourceKeyForLoadedConnection(configuredConnection), loadSchoolStatus()?.lastSuccessAt ?? null, baseUrl, token);
        try {
          nextWait = Math.min(nextWait, await processPassiveConnection(configuredConnection, baseUrl, token));
        } catch (error) {
          // This path reads only local browser-bridge captures and talks to the
          // iBacalao ingest API. A failure must not fall back to active LMS
          // crawling or create a new browser session. Never leave an older
          // healthy status behind after the local chain itself has failed.
          saveSchoolStatus(statusForConnection(configuredConnection, {
            connected: false,
            actionReason: "connector_stale",
            lastObservedAt: undefined,
            recipe: { state: "stale" },
          }));
          console.error(`[${sourceKeyForLoadedConnection(configuredConnection)}] passive engine threw:`, error);
          nextWait = Math.min(nextWait, 5_000);
        }
      }
      if (once) return;
      if (!Number.isFinite(nextWait)) {
        // All active adapters are suspended. The native app restarts this
        // daemon after a verified reconnect; until then do zero LMS traffic.
        nextWait = 60 * 60 * 1000;
      }
      // Short waits repeat every few seconds while paused; logging them buries real events.
      if (nextWait >= 60_000) console.log(`Sleeping ${Math.round(nextWait / 60000)}m`);
      await new Promise((resolve) => setTimeout(resolve, nextWait));
    }
  } finally {
    // Reached on --once completion (the loop's only in-try `return`) and on
    // an unhandled crash. The continuous daemon's normal exit path is the
    // SIGINT/SIGTERM `shutdown` handler above, which already closes sessions
    // itself — this covers the cases that never reach that handler.
    await closeAllSessions();
    caffeine?.kill();
    lock?.release(process.pid);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
