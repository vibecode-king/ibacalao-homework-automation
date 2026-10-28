import { test } from "node:test";
import assert from "node:assert/strict";
import { parentIsGone, takeOverDaemonLock, type DaemonLockDeps } from "../singleInstance";

function fakeDeps(over: Partial<DaemonLockDeps> & { alive?: Set<number>; lock?: number | null } = {}) {
  const alive = over.alive ?? new Set<number>();
  const state = { lock: over.lock ?? null, terminated: [] as number[] };
  const deps: DaemonLockDeps = {
    readPid: () => state.lock,
    writePid: (pid) => { state.lock = pid; },
    isAlive: (pid) => alive.has(pid),
    isWatcher: () => true,
    isOrphan: () => true,
    terminate: (pid) => { state.terminated.push(pid); },
    sleep: async () => undefined,
    ...over,
  };
  return { deps, state, alive };
}

test("no previous watcher: takes the lock without signalling anyone", async () => {
  const { deps, state } = fakeDeps();
  assert.equal(await takeOverDaemonLock(200, deps), true);
  assert.equal(state.lock, 200);
  assert.deepEqual(state.terminated, []);
});

test("stale lock from a dead watcher: just replaced", async () => {
  const { deps, state } = fakeDeps({ lock: 100 });
  assert.equal(await takeOverDaemonLock(200, deps), true);
  assert.equal(state.lock, 200);
  assert.deepEqual(state.terminated, []);
});

test("live previous watcher (orphan left by a crashed app): asked to stop, lock taken once it exits", async () => {
  const alive = new Set([100]);
  let sleeps = 0;
  const { deps, state } = fakeDeps({
    lock: 100,
    alive,
    sleep: async () => {
      sleeps += 1;
      if (sleeps === 3) alive.delete(100); // closes its browser, then exits
    },
  });
  assert.equal(await takeOverDaemonLock(200, deps, { waitMs: 10_000, stepMs: 500 }), true);
  assert.deepEqual(state.terminated, [100]);
  assert.equal(state.lock, 200);
});

test("previous watcher never exits: refuses to take the profile rather than fight over it", async () => {
  const { deps, state } = fakeDeps({ lock: 100, alive: new Set([100]) });
  assert.equal(await takeOverDaemonLock(200, deps, { waitMs: 1_000, stepMs: 500 }), false);
  assert.equal(state.lock, 100);
});

test("watcher owned by another running iBacalao app: left alone, we refuse instead of looping kills", async () => {
  const { deps, state } = fakeDeps({ lock: 100, alive: new Set([100]), isOrphan: () => false });
  assert.equal(await takeOverDaemonLock(200, deps), false);
  assert.deepEqual(state.terminated, []);
  assert.equal(state.lock, 100);
});

test("pid reused by an unrelated process: never signalled", async () => {
  const { deps, state } = fakeDeps({ lock: 100, alive: new Set([100]), isWatcher: () => false });
  assert.equal(await takeOverDaemonLock(200, deps), true);
  assert.deepEqual(state.terminated, []);
  assert.equal(state.lock, 200);
});

test("parent gone is a ppid change (re-parented to launchd)", () => {
  assert.equal(parentIsGone(51753, 51753), false);
  assert.equal(parentIsGone(51753, 1), true);
});
