import type { SourceFreshness, SourceFreshnessState } from "./freshness";
import type { ChainState } from "./chainTelemetry";
import type { SchoolActionReason, SchoolConnectionStatus } from "./types";
import { higherPriorityAction } from "./status";

export type SchoolStudentReportCode =
  | "signed_out_ibacalao"
  | "school_signin_needed"
  | "challenge_paused"
  | "checks_failing"
  | "mac_not_syncing"
  | "finish_setup"
  | "healthy";

export type SchoolStudentReportCta =
  | "signin_ibacalao"
  | "reconnect_school"
  | "open_portal"
  | "open_ibacalao"
  | "learn"
  | "connect";

export type SchoolStudentReport = {
  code: SchoolStudentReportCode;
  headline: string;
  detail: string;
  ctaLabel: string | null;
  cta: SchoolStudentReportCta | null;
  /** Reauth, challenge, Mac offline, or failing checks — not learning-required. */
  blocksSchoolSync: boolean;
  tone: "danger" | "warning" | "accent" | "success" | "muted";
};

export type DeriveSchoolStudentReportInput = {
  status: SchoolConnectionStatus | null;
  freshness?: SourceFreshness[] | null;
  ibacalaoSignedIn: boolean;
  chainState?: ChainState;
  /** True only when the crawl saw a real login wall (`#txtUser` / auth URL), not missing Keychain. */
  crawlAuthRequired?: boolean;
};

const BLOCKING_CODES: ReadonlySet<SchoolStudentReportCode> = new Set<SchoolStudentReportCode>([
  "school_signin_needed",
  "challenge_paused",
  "checks_failing",
  "mac_not_syncing",
]);

function worstFreshness(
  freshness: SourceFreshness[] | null | undefined,
  sourceKey?: string,
): SourceFreshnessState | null {
  const rows = freshness?.filter((row) => !sourceKey || row.sourceKey === sourceKey) ?? [];
  const pool = rows.length > 0 ? rows : freshness ?? [];
  if (pool.length === 0) return null;
  if (pool.some((row) => row.state === "failing")) return "failing";
  if (pool.some((row) => row.state === "offline")) return "offline";
  return "live";
}

function lastSyncedLine(status: SchoolConnectionStatus | null): string {
  const raw = status?.lastSuccessAt;
  if (!raw) return "School updates are syncing on this Mac.";
  const then = Date.parse(raw);
  if (!Number.isFinite(then)) return "School updates are syncing on this Mac.";
  const minutes = Math.max(0, Math.round((Date.now() - then) / 60_000));
  if (minutes < 1) return "Last synced just now.";
  if (minutes < 60) return `Last synced ${minutes}m ago.`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `Last synced ${hours}h ago.`;
  return `Last synced ${Math.round(hours / 24)}d ago.`;
}

function report(
  code: SchoolStudentReportCode,
  headline: string,
  detail: string,
  cta: SchoolStudentReportCta | null,
  ctaLabel: string | null,
  tone: SchoolStudentReport["tone"],
): SchoolStudentReport {
  return {
    code,
    headline,
    detail,
    cta,
    ctaLabel,
    blocksSchoolSync: BLOCKING_CODES.has(code),
    tone,
  };
}

/**
 * One student-facing school health line. First match wins.
 * Never treat a missing iBacalao session as a school logoff.
 */
export function deriveSchoolStudentReport(input: DeriveSchoolStudentReportInput): SchoolStudentReport {
  const { status, freshness, ibacalaoSignedIn, chainState, crawlAuthRequired } = input;
  const action: SchoolActionReason | undefined = status?.actionReason;
  const freshnessState = worstFreshness(freshness, status?.sourceKey);
  const loginWall = crawlAuthRequired === true
    || (crawlAuthRequired !== false && action === "reauth_required");

  if (!ibacalaoSignedIn) {
    return report(
      "signed_out_ibacalao",
      "Signed out of iBacalao",
      "Sign in to iBacalao so this Mac can sync school work. Your school password stays on the school site.",
      "signin_ibacalao",
      "Sign in to iBacalao",
      "warning",
    );
  }

  if (action === "reauth_required" && loginWall) {
    return report(
      "school_signin_needed",
      "School sign-in needed",
      "Your school portal is showing a login page. Sign in once; syncing resumes after iBacalao verifies the session.",
      "reconnect_school",
      "Sign in to school",
      "danger",
    );
  }

  if (action === "challenge_paused") {
    return report(
      "challenge_paused",
      "School paused us",
      "Your school portal asked iBacalao to stop automatic checks. Use the portal normally; we will not bypass the challenge.",
      "open_portal",
      "Open school portal",
      "warning",
    );
  }

  if (action === "reauth_required") {
    return report(
      "mac_not_syncing",
      "Mac not syncing",
      "School sign-in is not required yet — iBacalao did not see a login wall. Open iBacalao on this Mac.",
      "open_ibacalao",
      "Open iBacalao",
      "warning",
    );
  }

  if (freshnessState === "failing") {
    return report(
      "checks_failing",
      "Connected but checks failing",
      "This Mac is online, but recent school checks did not succeed. Open iBacalao and keep the Mac awake.",
      "open_ibacalao",
      "Open iBacalao",
      "warning",
    );
  }

  const chainUnhealthy = Boolean(chainState && chainState !== "healthy" && chainState !== "browser_not_observed");
  if (action === "connector_stale" || freshnessState === "offline" || chainUnhealthy) {
    return report(
      "mac_not_syncing",
      "Mac not syncing",
      "iBacalao has not received a recent school update. Open iBacalao on this Mac and keep it awake.",
      "open_ibacalao",
      "Open iBacalao",
      "warning",
    );
  }

  if (action === "manual_learning_required" || (action === "none" && (status?.missingCapabilities?.length ?? 0) > 0)) {
    return report(
      "finish_setup",
      "Finish setup (one visit)",
      "Open your school portal once so iBacalao can learn the missing pages. This is not a sign-in problem.",
      "learn",
      "Finish setup",
      "accent",
    );
  }

  const connectedLabel = status
    ? [status.platformLabel, status.schoolLabel].filter(Boolean).join(" / ")
    : null;
  return report(
    "healthy",
    connectedLabel ?? "School connected",
    lastSyncedLine(status),
    status ? null : "connect",
    status ? null : "Open browser & connect",
    "success",
  );
}

/** Keep a higher-priority blocker when overlaying freshness or chain health. */
export function actionFromFreshnessAndStatus(
  current: SchoolActionReason,
  freshnessState: SourceFreshnessState | null,
): SchoolActionReason {
  if (current === "reauth_required" || current === "challenge_paused") return current;
  if (freshnessState === "failing" || freshnessState === "offline") {
    return higherPriorityAction(current, "connector_stale");
  }
  return current;
}
