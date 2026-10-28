import { appendFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import type { SchoolStudentReportCode } from "./studentReport";

export const DEFAULT_SCHOOL_INCIDENTS_FILE = join(homedir(), ".ibacalao", "school", "incidents.jsonl");

const BLOCKERS: ReadonlySet<SchoolStudentReportCode> = new Set<SchoolStudentReportCode>([
  "school_signin_needed",
  "challenge_paused",
  "checks_failing",
  "mac_not_syncing",
]);

export type SchoolIncidentLine = {
  at: string;
  direction: "enter" | "leave";
  code: SchoolStudentReportCode;
  previousCode: SchoolStudentReportCode | null;
  snapshot?: Record<string, unknown>;
};

export function blockerTransition(
  previous: SchoolStudentReportCode | null,
  next: SchoolStudentReportCode,
): "enter" | "leave" | null {
  const was = previous ? BLOCKERS.has(previous) : false;
  const now = BLOCKERS.has(next);
  if (!was && now) return "enter";
  if (was && !now) return "leave";
  if (was && now && previous !== next) return "enter";
  return null;
}

/** One JSONL line on enter/leave of a sync blocker — never every poll. */
export function appendSchoolIncident(
  line: SchoolIncidentLine,
  file = DEFAULT_SCHOOL_INCIDENTS_FILE,
): void {
  mkdirSync(dirname(file), { recursive: true });
  appendFileSync(file, `${JSON.stringify(line)}\n`);
}

export function recordBlockerTransition(options: {
  previousCode: SchoolStudentReportCode | null;
  nextCode: SchoolStudentReportCode;
  snapshot?: Record<string, unknown>;
  file?: string;
}): void {
  const direction = blockerTransition(options.previousCode, options.nextCode);
  if (!direction) return;
  appendSchoolIncident({
    at: new Date().toISOString(),
    direction,
    code: options.nextCode,
    previousCode: options.previousCode,
    ...(options.snapshot ? { snapshot: options.snapshot } : {}),
  }, options.file);
}
