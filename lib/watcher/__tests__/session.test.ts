// A watcher restart must not log a student out of a school whose session is
// still valid (Learnbox authenticates with a session-only cookie).

import assert from "node:assert/strict";
import { lstatSync, mkdtempSync, rmSync, statSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { clearStaleSingletonLock, restoreSessionCookies, saveSessionCookies, sessionOnlyCookies } from "../session";

function symlinkExists(path: string): boolean {
  try {
    lstatSync(path);
    return true;
  } catch {
    return false;
  }
}

type Cookie = Parameters<typeof sessionOnlyCookies>[0][number];

function cookie(overrides: Partial<Cookie>): Cookie {
  return {
    name: "PHPSESSID",
    value: "live",
    domain: "ukschool.learnbox.com.ec",
    path: "/",
    expires: -1,
    httpOnly: true,
    secure: true,
    sameSite: "Lax",
    ...overrides,
  };
}

function jar(initial: Cookie[]) {
  let cookies = [...initial];
  return {
    get all() {
      return cookies;
    },
    async cookies() {
      return cookies;
    },
    async addCookies(added: Cookie[]) {
      for (const next of added) {
        const index = cookies.findIndex((current) =>
          current.name === next.name && current.domain === next.domain && current.path === next.path
        );
        if (index >= 0) cookies[index] = next;
        else cookies.push(next);
      }
    },
  };
}

test("only session-only cookies for the school site are kept", () => {
  const kept = sessionOnlyCookies([
    cookie({}),
    cookie({ name: "remember", expires: 1_900_000_000 }),
    cookie({ name: "NID", domain: ".google.com" }),
    cookie({ name: "evil", domain: "learnbox.com.ec.evil.example" }),
    cookie({ name: "root", domain: ".learnbox.com.ec" }),
  ], "learnbox.com.ec");
  assert.deepEqual(kept.map((entry) => entry.name), ["PHPSESSID", "root"]);
});

test("a restarted browser gets the school session back, readable only by this user", async () => {
  const dir = mkdtempSync(join(tmpdir(), "watcher-session-"));
  try {
    await saveSessionCookies(jar([cookie({})]), dir, "learnbox.com.ec");
    assert.equal(statSync(join(dir, "session-cookies.json")).mode & 0o777, 0o600);

    const restarted = jar([]);
    assert.equal(await restoreSessionCookies(restarted, dir), 1);
    assert.equal(restarted.all[0].value, "live");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a fresher live cookie is never overwritten by the saved copy", async () => {
  const dir = mkdtempSync(join(tmpdir(), "watcher-session-"));
  try {
    await saveSessionCookies(jar([cookie({ value: "old" })]), dir, "learnbox.com.ec");
    const browser = jar([cookie({ value: "new" })]);
    assert.equal(await restoreSessionCookies(browser, dir), 0);
    assert.deepEqual(browser.all.map((entry) => entry.value), ["new"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an auth-wall recovery can replace a stale same-name browser cookie once", async () => {
  const dir = mkdtempSync(join(tmpdir(), "watcher-session-"));
  try {
    await saveSessionCookies(jar([cookie({ value: "last-known-good" })]), dir, "learnbox.com.ec");
    const browser = jar([cookie({ value: "stale-profile-cookie" })]);

    assert.equal(await restoreSessionCookies(browser, dir), 0, "normal startup must preserve the current browser cookie");
    assert.equal(browser.all[0].value, "stale-profile-cookie");

    assert.equal(await restoreSessionCookies(browser, dir, { replaceExisting: true }), 1);
    assert.deepEqual(browser.all.map((entry) => entry.value), ["last-known-good"]);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("no saved session means a normal fresh browser, not a crash", async () => {
  const dir = mkdtempSync(join(tmpdir(), "watcher-session-"));
  try {
    assert.equal(await restoreSessionCookies(jar([]), dir), 0);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("no lock file: clearStaleSingletonLock is a no-op", () => {
  const dir = mkdtempSync(join(tmpdir(), "watcher-lock-"));
  try {
    assert.doesNotThrow(() => clearStaleSingletonLock(dir));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a lock naming a dead pid is removed", () => {
  const dir = mkdtempSync(join(tmpdir(), "watcher-lock-"));
  try {
    // A pid this high cannot exist on macOS/Linux (PID_MAX_DEFAULT is far
    // below it), so process.kill(pid, 0) is guaranteed to raise ESRCH.
    symlinkSync("test-host-999999", join(dir, "SingletonLock"));
    clearStaleSingletonLock(dir);
    assert.equal(symlinkExists(join(dir, "SingletonLock")), false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a lock naming this still-running process is left alone", () => {
  const dir = mkdtempSync(join(tmpdir(), "watcher-lock-"));
  try {
    symlinkSync(`test-host-${process.pid}`, join(dir, "SingletonLock"));
    clearStaleSingletonLock(dir);
    assert.equal(symlinkExists(join(dir, "SingletonLock")), true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("saving reports failure when the school sign-in would not be kept", async () => {
  const dir = mkdtempSync(join(tmpdir(), "watcher-session-"));
  try {
    assert.equal(await saveSessionCookies(jar([cookie({})]), dir, "learnbox.com.ec"), true);
    assert.equal(await saveSessionCookies(jar([cookie({ expires: 1_900_000_000 })]), dir, "learnbox.com.ec"), true, "persistent cookies live in the profile");
    assert.equal(await saveSessionCookies(jar([cookie({ domain: ".learnbox.com.ec", expires: 1_900_000_000 })]), dir, "ukschool.learnbox.com.ec"), true, "parent-domain cookie serves the host");
    assert.equal(await saveSessionCookies(jar([cookie({ domain: ".google.com" })]), dir, "learnbox.com.ec"), false, "no school cookies at all");
    assert.equal(await saveSessionCookies(jar([cookie({})]), join(dir, "missing"), "learnbox.com.ec"), false, "write failed");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
