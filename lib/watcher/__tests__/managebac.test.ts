import { test } from "node:test";
import assert from "node:assert/strict";
import { createManageBacAdapter, extractTasks, managebacAdapter } from "../adapters/managebac";
import type { WatcherPage } from "../types";

const ROW = `
<li data-task-id="t1">
  <span class="task-title">Biology IA — Criterion C</span>
  <span class="subject">Biology</span>
  <time datetime="2026-09-20T23:59:00Z">Sep 20</time>
</li>`;

const GRADED_ROW = `
<li data-task-id="t2">
  <span class="task-title">Math AA Paper 1</span>
  <span class="subject">Mathematics</span>
  <span class="grade">6</span>
  <span class="status">Graded</span>
</li>`;

function page(html: string, url = "https://school.managebac.com/student/tasks_and_deadlines?view=upcoming"): WatcherPage {
  return {
    async goto() {},
    url: () => url,
    content: async () => html,
    title: async () => "",
  };
}

test("configured adapter uses the school-specific origin and current tasks route", async () => {
  let visited = "";
  const adapter = createManageBacAdapter("https://school.managebac.com/some/path");
  const outcome = await adapter.crawl({
    async goto(url: string) { visited = url; },
    url: () => visited,
    content: async () => `<ul>${ROW}</ul>`,
    title: async () => "Tasks & Deadlines",
  });
  assert.equal(visited, "https://school.managebac.com/student/tasks_and_deadlines?view=upcoming");
  assert.equal(outcome.ok, true);
});

test("a ManageBac 404 is an explicit route error, never a healthy empty page", async () => {
  const adapter = createManageBacAdapter("https://www.managebac.com");
  const outcome = await adapter.crawl({
    async goto() {},
    url: () => "https://www.managebac.com/student/tasks_and_deadlines?view=upcoming",
    content: async () => "<html><body><h1>404 - Page not found!</h1></body></html>",
    title: async () => "404 - 404 - Page not found!",
  });
  assert.deepEqual(outcome, { ok: false, reason: "error", message: "managebac_tasks_route_not_found" });
});

test("extracts a task row", () => {
  const [record] = extractTasks(`<ul>${ROW}</ul>`);
  assert.equal(record.sourceRecordId, "t1");
  assert.equal(record.title, "Biology IA — Criterion C");
  assert.equal(record.subject, "Biology");
  assert.equal(record.dueAt, "2026-09-20T23:59:00Z");
  assert.equal(record.kind, "assignment");
});

test("a posted grade is recorded as a grade, not an assignment", () => {
  const [record] = extractTasks(`<ul>${GRADED_ROW}</ul>`);
  assert.equal(record.kind, "grade");
  assert.equal(record.grade, "6");
  assert.equal(record.status, "Graded");
});

test("multiple rows do not collapse into one", () => {
  const records = extractTasks(`<ul>${ROW}${GRADED_ROW}</ul>`);
  assert.equal(records.length, 2);
  assert.deepEqual(
    records.map((r) => r.sourceRecordId),
    ["t1", "t2"],
  );
});

test("rows without a title are skipped as chrome", () => {
  assert.equal(extractTasks(`<li data-task-id="x"><span>header</span></li>`).length, 0);
});

test("markup and entities are stripped out of titles", () => {
  const [record] = extractTasks(
    `<li data-task-id="t3"><span class="task-title">Physics&nbsp;<b>HL</b> lab</span></li>`,
  );
  assert.ok(!record.title.includes("<"));
  assert.ok(!record.title.includes("&nbsp;"));
});

test("the pure extractor can represent an empty list", () => {
  assert.deepEqual(extractTasks("<ul></ul>"), []);
});

test("an empty adapter extraction is not accepted as an authoritative success", async () => {
  const outcome = await managebacAdapter.crawl(page("<ul></ul>"));
  assert.equal(outcome.ok, false);
  if (!outcome.ok) {
    assert.equal(outcome.reason, "error");
    assert.equal(outcome.message, "managebac_selectors_returned_zero_records");
  }
});

// ── the guard that matters most ───────────────────────────────────────────

test("a login page reports auth_required, never an empty success", async () => {
  // The failure this prevents: extracting zero records from a login page and
  // telling the student they have no work.
  const outcome = await managebacAdapter.crawl(
    page('<form><input type="password"></form>', "https://managebac.com/login"),
  );
  assert.deepEqual(outcome, { ok: false, reason: "auth_required" });
});

test("a bot check reports challenged", async () => {
  const outcome = await managebacAdapter.crawl(page("<title>Just a moment...</title>"));
  assert.deepEqual(outcome, { ok: false, reason: "challenged" });
});

test("a healthy page returns records", async () => {
  const outcome = await managebacAdapter.crawl(page(`<ul>${ROW}</ul>`));
  assert.equal(outcome.ok, true);
  if (outcome.ok) assert.equal(outcome.records.length, 1);
});

test("a navigation failure is an error, not a silent empty crawl", async () => {
  const outcome = await managebacAdapter.crawl({
    async goto() {
      throw new Error("net::ERR_TIMED_OUT");
    },
    url: () => "https://managebac.com/student/tasks",
    content: async () => "",
    title: async () => "",
  });
  assert.equal(outcome.ok, false);
  if (!outcome.ok) assert.equal(outcome.reason, "error");
});
