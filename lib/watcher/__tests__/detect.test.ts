import { test } from "node:test";
import assert from "node:assert/strict";
import {
  classifyPage,
  looksLikeAuthWall,
  looksLikeChallenge,
  parseRetryAfterMs,
} from "../detect";

const PAGE = "<html><body><h1>Assignments</h1></body></html>";

test("a normal page is ok", () => {
  assert.deepEqual(classifyPage("https://school.managebac.com/student/tasks", PAGE), {
    state: "ok",
  });
});

test("a redirect to a login URL is an auth wall", () => {
  assert.ok(looksLikeAuthWall("https://school.managebac.com/login", PAGE));
  assert.ok(looksLikeAuthWall("https://accounts.google.com/o/oauth2/v2/auth", PAGE));
  assert.ok(looksLikeAuthWall("https://login.microsoftonline.com/common", PAGE));
});

test("an inline password form is an auth wall even without a login URL", () => {
  assert.ok(
    looksLikeAuthWall(
      "https://school.managebac.com/dashboard",
      '<form><input type="password" name="password"></form>',
    ),
  );
  assert.ok(
    looksLikeAuthWall(
      "https://school.learnbox.com/home",
      '<input id="txtUser"><input id="txtPassword">',
    ),
  );
});

test("prose mentioning sign-in is NOT an auth wall", () => {
  // The dangerous false positive is the other direction, but this one matters
  // too: a real assignment must not be misread as a dead session.
  assert.ok(
    !looksLikeAuthWall(
      "https://school.managebac.com/student/tasks",
      "<li>Please sign in to the lab portal before Friday</li>",
    ),
  );
});

test("a bot check is a challenge", () => {
  assert.ok(looksLikeChallenge("https://x/tasks", "<title>Just a moment...</title>"));
  assert.ok(looksLikeChallenge("https://x/tasks", "<div id='cf-browser-verification'>"));
  assert.ok(looksLikeChallenge("https://x/tasks", "please complete the CAPTCHA"));
  assert.ok(looksLikeChallenge("https://x/tasks", "We detected unusual traffic"));
});

test("a challenge sitting on a login URL is classified as a challenge, not auth", () => {
  // Misreading this as an expired session would tell the student to log in
  // when nothing is wrong, and would keep polling a platform that just asked
  // us to stop.
  const verdict = classifyPage(
    "https://school.managebac.com/login",
    "<title>Just a moment...</title><div id='cf-browser-verification'>",
  );
  assert.deepEqual(verdict, { state: "challenged" });
});

test("an empty page is ok, not an auth wall", () => {
  // A genuinely empty assignment list is a legitimate answer.
  assert.deepEqual(classifyPage("https://school.managebac.com/student/tasks", ""), {
    state: "ok",
  });
});

// ── Retry-After ───────────────────────────────────────────────────────────

test("parses delta-seconds", () => {
  assert.equal(parseRetryAfterMs("120"), 120_000);
});

test("parses an HTTP date", () => {
  const now = Date.parse("2026-09-07T12:00:00.000Z");
  assert.equal(parseRetryAfterMs("Mon, 07 Sep 2026 12:05:00 GMT", now), 300_000);
});

test("a past date clamps to zero rather than going negative", () => {
  const now = Date.parse("2026-09-07T12:00:00.000Z");
  assert.equal(parseRetryAfterMs("Mon, 07 Sep 2026 11:00:00 GMT", now), 0);
});

test("missing or unparseable values yield undefined", () => {
  assert.equal(parseRetryAfterMs(null), undefined);
  assert.equal(parseRetryAfterMs(""), undefined);
  assert.equal(parseRetryAfterMs("soon"), undefined);
});
