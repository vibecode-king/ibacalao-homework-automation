import { test } from "node:test";
import assert from "node:assert/strict";
import { createSessionCache } from "../sessionCache";

function fakeSession(id: number) {
  const session = { id, closed: false, closeCalls: 0, isClosed: () => session.closed, close: async () => { session.closeCalls += 1; session.closed = true; } };
  return session;
}

test("reuses a live session across polls", async () => {
  let opened = 0;
  const cache = createSessionCache(async () => fakeSession(++opened));
  const a = await cache.get("learnbox", "learnbox");
  const b = await cache.get("learnbox", "learnbox");
  assert.equal(a, b);
  assert.equal(opened, 1);
});

test("replaces a session whose browser died instead of reusing the dead page", async () => {
  let opened = 0;
  const cache = createSessionCache(async () => fakeSession(++opened));
  const dead = await cache.get("learnbox", "learnbox");
  dead.closed = true; // Chromium crashed, Mac slept, or the student closed the window
  const fresh = await cache.get("learnbox", "learnbox");
  assert.notEqual(fresh, dead);
  assert.equal(fresh.id, 2);
  assert.equal(dead.closeCalls, 1);
});

test("an adopted login window is replaced once the student closes it", async () => {
  let opened = 0;
  const cache = createSessionCache(async () => fakeSession(100 + ++opened));
  const loginWindow = fakeSession(1);
  cache.adopt("learnbox", loginWindow);
  assert.equal(await cache.get("learnbox", "learnbox"), loginWindow);
  loginWindow.closed = true;
  assert.equal((await cache.get("learnbox", "learnbox")).id, 101);
});

test("closeAll closes every cached session once", async () => {
  let opened = 0;
  const cache = createSessionCache(async () => fakeSession(++opened));
  const a = await cache.get("learnbox", "a");
  const b = await cache.get("managebac", "b");
  await cache.closeAll();
  assert.equal(a.closeCalls, 1);
  assert.equal(b.closeCalls, 1);
});
