import type { BrowserContext } from "playwright";
import { discoverAndExtractSchoolAttachments } from "./attachmentDiscovery";
import type { ScrapedRecord, WatcherPage } from "./types";

export function parseMoodleDueDate(value: string | undefined): string | undefined {
  if (!value) return undefined;
  const spanish = value.toLowerCase().match(/\b(\d{1,2})\s+de\s+(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre)\s+(?:de\s+)?(\d{4})(?:[^\d]+(\d{1,2}):(\d{2}))?/);
  if (spanish) {
    const months = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre"];
    const month = months.indexOf(spanish[2] === "setiembre" ? "septiembre" : spanish[2]);
    const year = Number(spanish[3]), day = Number(spanish[1]), hour = Number(spanish[4] ?? 0), minute = Number(spanish[5] ?? 0);
    const parsed = new Date(Date.UTC(year, month, day));
    if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month || parsed.getUTCDate() !== day || hour > 23 || minute > 59) return undefined;
    // Moodle displays text in the account's timezone, which may differ from
    // the Mac's timezone. Keep the date rather than inventing an instant.
    return `${spanish[3]}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  }
  const englishMonths = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"];
  const english = value.toLowerCase().match(/\b(\d{1,2})\s+(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{4})\b/);
  if (english) {
    const day = Number(english[1]), month = englishMonths.indexOf(english[2]), year = Number(english[3]);
    const parsed = new Date(Date.UTC(year, month, day));
    if (parsed.getUTCFullYear() !== year || parsed.getUTCMonth() !== month || parsed.getUTCDate() !== day) return undefined;
    return `${english[3]}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  }
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    const time = Date.parse(value);
    return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value ? value : undefined;
  }
  if (!/(?:Z|[+-]\d{2}:?\d{2})$/i.test(value.trim())) return undefined;
  const time = Date.parse(value);
  return Number.isFinite(time) ? new Date(time).toISOString() : undefined;
}

/** Read one Moodle assignment using the student's existing browser profile. */
export async function readMoodleAssignmentDetail(
  context: BrowserContext,
  origin: string,
  record: ScrapedRecord,
): Promise<Pick<ScrapedRecord, "detail" | "dueAt" | "contentIntegrity"> | null> {
  let target: URL;
  try {
    target = new URL(record.url ?? "");
    const id = target.searchParams.get("id") ?? "";
    if (target.username || target.password || target.origin !== new URL(origin).origin || target.pathname !== "/mod/assign/view.php" || !/^\d+$/.test(id)) return null;
    target.search = new URLSearchParams({ id }).toString();
    target.hash = "";
  } catch { return null; }

  const page = await context.newPage();
  try {
    await page.route("**/*", async (route) => {
      const request = route.request();
      let allowed = false;
      try { allowed = new URL(request.url()).origin === target.origin && ["GET", "HEAD"].includes(request.method()); } catch { /* invalid URL */ }
      if (allowed) await route.continue(); else await route.abort();
    });
    const response = await page.goto(target.href, { waitUntil: "domcontentloaded", timeout: 30000 });
    const current = new URL(page.url());
    if (!response?.ok() || current.origin !== target.origin || current.pathname !== target.pathname || current.searchParams.get("id") !== target.searchParams.get("id")) return null;
    const fields = await page.evaluate(() => {
      const root = document.querySelector(".activity-description, #intro, .activity-description-content");
      const detail = (root as HTMLElement | null)?.innerText?.trim() ?? "";
      const rows = Array.from(document.querySelectorAll("tr"));
      const due = rows.find((row) => /^(due date|fecha de entrega|fecha de vencimiento)$/i.test(row.querySelector("th")?.textContent?.trim() ?? ""));
      const dueText = due?.querySelector("td time")?.getAttribute("datetime") ?? due?.querySelector("td")?.textContent?.trim();
      const submission = rows.find((row) => /^(submission status|estado de la entrega|estado de entrega|estado de env[ií]o)$/i.test(row.querySelector("th")?.textContent?.replace(/\s+/g, " ").trim() ?? ""));
      const submissionStatus = submission?.querySelector("td")?.textContent?.replace(/\s+/g, " ").trim().slice(0, 300);
      const attachmentNames = Array.from(root?.querySelectorAll('a[href*="/pluginfile.php/"], a[download]') ?? [])
        .map((link) => link.textContent?.replace(/\s+/g, " ").trim().slice(0, 200))
        .filter((name): name is string => Boolean(name)).slice(0, 8);
      return { detail: detail.slice(0, 12000), dueText, submissionStatus, attachmentNames };
    });
    if (/required parameter|par[aá]metro necesario/i.test(fields.detail)) return null;
    const attachments = await discoverAndExtractSchoolAttachments(page as unknown as WatcherPage, target.origin, {
      rootSelector: ".activity-description, #intro, .activity-description-content",
      enableRevealInteractions: false,
      enableDownloadInteractions: false,
      maxCandidates: 8,
    });
    // The production Dispatch parser accepts at most 16,000 characters.
    const names = fields.attachmentNames?.length ? `Attachments: ${fields.attachmentNames.join(", ")}` : "";
    const submissionStatus = fields.submissionStatus ? `Submission status: ${fields.submissionStatus}` : "";
    const detail = [fields.detail, submissionStatus, names, attachments.text].filter(Boolean).join("\n\n").slice(0, 16000);
    if (!detail) return null;
    let dueAt = parseMoodleDueDate(fields.dueText);
    if (dueAt?.length === 10 && record.dueAt?.startsWith(`${dueAt}T`)) dueAt = record.dueAt;
    return { detail, ...(dueAt ? { dueAt } : {}), ...(attachments.contentIntegrity ? { contentIntegrity: attachments.contentIntegrity } : {}) };
  } finally {
    await page.close().catch(() => undefined);
  }
}
