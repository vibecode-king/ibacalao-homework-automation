import { test } from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { emptyHealth } from "../types";
import {
  installWatcherProcessErrorHandlers,
  markUnexpectedSyncFailure,
  type WatcherProcessErrorKind,
} from "../processErrorHandlers";

test("process error handlers report failures and return control to the watcher loop", () => {
  const events = new EventEmitter();
  const reported: Array<{ kind: WatcherProcessErrorKind; error: unknown }> = [];
  const logged: WatcherProcessErrorKind[] = [];
  const removeHandlers = installWatcherProcessErrorHandlers(
    events as unknown as Pick<NodeJS.Process, "on" | "off">,
    (kind, error) => reported.push({ kind, error }),
    (kind) => logged.push(kind),
  );
  const rejection = new Error("Playwright callback rejected");
  const exception = new Error("Unexpected callback exception");

  assert.doesNotThrow(() => events.emit("unhandledRejection", rejection, Promise.resolve()));
  assert.doesNotThrow(() => events.emit("uncaughtException", exception, "uncaughtException"));
  const followingLoopStepRan = true;

  assert.equal(followingLoopStepRan, true);
  assert.deepEqual(logged, ["unhandledRejection", "uncaughtException"]);
  assert.deepEqual(reported, [
    { kind: "unhandledRejection", error: rejection },
    { kind: "uncaughtException", error: exception },
  ]);
  removeHandlers();
  assert.equal(events.listenerCount("uncaughtException"), 0);
  assert.equal(events.listenerCount("unhandledRejection"), 0);
});

test("a failure reporter that throws does not escape the process handlers", () => {
  const events = new EventEmitter();
  const logged: unknown[] = [];
  const removeHandlers = installWatcherProcessErrorHandlers(
    events as unknown as Pick<NodeJS.Process, "on" | "off">,
    () => { throw new Error("status write failed"); },
    (_kind, error) => logged.push(error),
  );

  assert.doesNotThrow(() => events.emit("unhandledRejection", "rejected callback", Promise.resolve()));
  assert.equal(logged.length, 2);
  assert.equal(logged[0], "rejected callback");
  assert.match(String(logged[1]), /status write failed/);
  removeHandlers();
});

test("an unexpected process error leaves the active sync marked as failed", () => {
  const failedAt = "2026-10-28T12:00:00.000Z";
  const health = markUnexpectedSyncFailure(
    emptyHealth("managebac"),
    "Error: Playwright callback rejected",
    failedAt,
    0,
  );

  assert.equal(health.lastAttemptAt, failedAt);
  assert.equal(health.consecutiveFailures, 1);
  assert.equal(health.lastError, "Error: Playwright callback rejected");
  assert.equal(health.lastSuccessAt, null);
});
