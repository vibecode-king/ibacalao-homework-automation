// lib/watcher/adapters/managebac.ts
// ManageBac extractor.
//
// ⚠️ SELECTORS ARE UNVERIFIED. Nobody has run this against a live ManageBac
// account — I have no credentials for one. The control flow below (classify the
// page, refuse to report success on a wall, extract, normalize) IS tested; the
// specific DOM shapes are an informed first draft and should be expected to be
// wrong until someone opens a real account and checks. Treat a zero-record
// crawl from this adapter as "selectors are stale" until proven otherwise, not
// as "the student has no work".
//
// The extraction deliberately parses the HTML string rather than using
// page.$$eval, so the parsing half is pure and testable without a browser.

import { classifyPage } from "../detect";
import type { CrawlOutcome, PlatformAdapter, ScrapedRecord, WatcherPage } from "../types";

const TASKS_PATH = "/student/tasks_and_deadlines?view=upcoming";

/**
 * Pulls records out of a tasks page's HTML.
 *
 * Exported for tests: this is the half that can be verified against captured
 * fixtures once someone can save a real page, without needing a live session.
 */
export function extractTasks(html: string): ScrapedRecord[] {
  const records: ScrapedRecord[] = [];

  // ManageBac renders task lists server-side with a data-task-id per row. The
  // non-greedy row split is intentional: a greedy match would swallow the whole
  // list into one "record".
  const rowPattern = /<(?:li|tr|div)[^>]*data-task-id=["']([^"']+)["'][^>]*>([\s\S]*?)<\/(?:li|tr|div)>/gi;

  // exec-in-a-loop rather than matchAll: this repo's tsconfig target predates
  // downlevelIteration, so iterating a RegExp match iterator does not compile.
  let match: RegExpExecArray | null;
  while ((match = rowPattern.exec(html)) !== null) {
    const [, sourceRecordId, body] = match;
    const title = textOf(body, /class=["'][^"']*task-title[^"']*["'][^>]*>([\s\S]*?)</i);
    if (!title) continue; // a row with no title is chrome, not a task

    const record: ScrapedRecord = {
      sourceRecordId,
      kind: "assignment",
      title,
    };

    const subject = textOf(body, /class=["'][^"']*subject[^"']*["'][^>]*>([\s\S]*?)</i);
    const due = attrOf(body, /<time[^>]*datetime=["']([^"']+)["']/i);
    const grade = textOf(body, /class=["'][^"']*grade[^"']*["'][^>]*>([\s\S]*?)</i);
    const status = textOf(body, /class=["'][^"']*status[^"']*["'][^>]*>([\s\S]*?)</i);

    if (subject) record.subject = subject;
    if (due) record.dueAt = due;
    if (grade) {
      record.grade = grade;
      // A posted grade is a different academic fact from an assignment being
      // set, and downstream ranking treats them differently.
      record.kind = "grade";
    }
    if (status) record.status = status;

    records.push(record);
  }

  return records;
}

function textOf(html: string, pattern: RegExp): string | undefined {
  const value = html.match(pattern)?.[1];
  if (!value) return undefined;
  const stripped = value
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/\s+/g, " ")
    .trim();
  return stripped.length > 0 ? stripped : undefined;
}

function attrOf(html: string, pattern: RegExp): string | undefined {
  return html.match(pattern)?.[1]?.trim() || undefined;
}

function managebacTasksUrl(origin: string): string | null {
  try {
    const parsed = new URL(origin);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return null;
    return new URL(TASKS_PATH, `${parsed.origin}/`).toString();
  } catch {
    return null;
  }
}

function looksLikeManageBacNotFound(title: string, html: string): boolean {
  return /\b404\b.*page not found|page not found.*\b404\b/i.test(`${title} ${html.slice(0, 4000)}`);
}

export function createManageBacAdapter(origin: string): PlatformAdapter {
  return {
    platform: "managebac",
    label: "ManageBac",

    async crawl(page: WatcherPage): Promise<CrawlOutcome> {
      try {
        const tasksUrl = managebacTasksUrl(origin);
        if (!tasksUrl) return { ok: false, reason: "error", message: "managebac_invalid_origin" };
        await page.goto(tasksUrl, { timeout: 30_000 });
        const html = await page.content();
        const title = await page.title();

      // Classify BEFORE extracting. An adapter that extracts from a login page
      // reports zero records and the product silently tells the student they
      // have no work.
        const verdict = classifyPage(page.url(), html);
        if (verdict.state === "auth_required") return { ok: false, reason: "auth_required" };
        if (verdict.state === "challenged") return { ok: false, reason: "challenged" };
        if (looksLikeManageBacNotFound(title, html)) {
          return { ok: false, reason: "error", message: "managebac_tasks_route_not_found" };
        }

        const records = extractTasks(html);
      // Selectors are not yet live-verified. Zero extracted records are not
      // authoritative evidence that the student has no work; accepting them
      // would erase the baseline and make existing work disappear.
        if (records.length === 0) {
          return { ok: false, reason: "error", message: "managebac_selectors_returned_zero_records" };
        }
        return { ok: true, records };
      } catch (error) {
        return {
          ok: false,
          reason: "error",
          message: error instanceof Error ? error.message : String(error),
        };
      }
    },
  };
}

/** Legacy static adapter for the no-connection fallback. Configured school
 * connections always use createManageBacAdapter(connection.origin). */
export const managebacAdapter = createManageBacAdapter("https://www.managebac.com");
