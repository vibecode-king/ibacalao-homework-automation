import type { WatcherHealth } from "./types";

export type WatcherProcessErrorKind = "uncaughtException" | "unhandledRejection";

export function markUnexpectedSyncFailure(
  health: WatcherHealth,
  message: string,
  failedAt: string,
  failureCountAtStart: number,
): WatcherHealth {
  return {
    ...health,
    lastAttemptAt: failedAt,
    consecutiveFailures: Math.max(health.consecutiveFailures, failureCountAtStart + 1),
    lastError: message,
  };
}

export function installWatcherProcessErrorHandlers(
  eventSource: Pick<NodeJS.Process, "on" | "off">,
  reportFailure: (kind: WatcherProcessErrorKind, error: unknown) => void,
  log: (kind: WatcherProcessErrorKind, error: unknown) => void = (kind, error) => {
    console.error("[school-watcher] " + kind + ":", error);
  },
) {
  const dispatch = (kind: WatcherProcessErrorKind, error: unknown) => {
    try {
      log(kind, error);
    } catch {
      // A broken logger must not turn a handled process error into another one.
    }
    try {
      reportFailure(kind, error);
    } catch (reportError) {
      try {
        log(kind, reportError);
      } catch {
        // Keep the event handler non-throwing even when reporting also fails.
      }
    }
  };

  const handlers = {
    uncaughtException: (error: Error, _origin: NodeJS.UncaughtExceptionOrigin) => {
      dispatch("uncaughtException", error);
    },
    unhandledRejection: (reason: unknown, _promise: Promise<unknown>) => {
      dispatch("unhandledRejection", reason);
    },
  };
  eventSource.on("uncaughtException", handlers.uncaughtException);
  eventSource.on("unhandledRejection", handlers.unhandledRejection);
  return () => {
    eventSource.off("uncaughtException", handlers.uncaughtException);
    eventSource.off("unhandledRejection", handlers.unhandledRejection);
  };
}
