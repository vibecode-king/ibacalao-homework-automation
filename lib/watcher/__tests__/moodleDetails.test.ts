import assert from "node:assert/strict";
import { test } from "node:test";
import type { BrowserContext } from "playwright";
import { parseMoodleDueDate, readMoodleAssignmentDetail } from "../moodleDetails";

const assignment = { kind: "assignment" as const, title: "Work", url: "https://school.example/mod/assign/view.php?id=42" };

test("parses Moodle dates in Spanish and rejects invalid dates", () => {
  assert.equal(parseMoodleDueDate("martes, 3 de noviembre de 2026, 23:59"), "2026-11-03");
  assert.equal(parseMoodleDueDate("Tuesday, 3 November 2026, 11:59 PM"), "2026-11-03");
  assert.equal(parseMoodleDueDate("2026-11-03T12:00:00"), undefined);
  assert.equal(parseMoodleDueDate("31 de febrero de 2026, 23:59"), undefined);
});

test("does not open non-assignment or cross-origin links", async () => {
  let opened = false;
  const context = { newPage: async () => { opened = true; throw new Error("unexpected"); } } as unknown as BrowserContext;
  assert.equal(await readMoodleAssignmentDetail(context, "https://school.example", { ...assignment, url: "https://other.example/mod/assign/view.php?id=42" }), null);
  assert.equal(await readMoodleAssignmentDetail(context, "https://school.example", { ...assignment, url: "https://school.example/mod/assign/view.php?id=abc" }), null);
  assert.equal(opened, false);
});

test("rejects a login redirect and closes its page", async () => {
  let closed = false;
  const page = {
    route: async () => {},
    goto: async () => ({ ok: () => true }),
    url: () => "https://school.example/login/index.php",
    close: async () => { closed = true; },
  };
  const context = { newPage: async () => page } as unknown as BrowserContext;
  assert.equal(await readMoodleAssignmentDetail(context, "https://school.example", assignment), null);
  assert.equal(closed, true);
});

test("reads assignment instructions and closes the temporary page", async () => {
  let closed = false;
  let routeHandler: ((route: unknown) => Promise<void>) | undefined;
  const page = {
    route: async (_pattern: string, handler: (route: unknown) => Promise<void>) => { routeHandler = handler; },
    goto: async () => ({ ok: () => true }),
    url: () => assignment.url,
    evaluate: async (script: unknown) => typeof script === "function"
      ? { detail: "Explain the water cycle.", dueText: "2026-11-03T12:00:00Z", submissionStatus: "No submissions have been made yet" }
      : [],
    close: async () => { closed = true; },
  };
  const context = { newPage: async () => page } as unknown as BrowserContext;
  const result = await readMoodleAssignmentDetail(context, "https://school.example", assignment);
  assert.match(result?.detail ?? "", /Explain the water cycle\./);
  assert.match(result?.detail ?? "", /Submission status: No submissions have been made yet/);
  assert.equal(result?.dueAt, "2026-11-03T12:00:00.000Z");
  assert.equal(closed, true);
  let action = "";
  await routeHandler?.({ request: () => ({ url: () => assignment.url, method: () => "POST" }), continue: async () => { action = "continue"; }, abort: async () => { action = "abort"; } });
  assert.equal(action, "abort");
});
