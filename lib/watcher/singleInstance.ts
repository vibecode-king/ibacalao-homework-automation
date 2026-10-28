// lib/watcher/singleInstance.ts
// Exactly one polling watcher per Mac.
//
// The Mac app starts the daemon as a child process and only stops it on a
// clean quit. A crash, Force Quit or reinstall kills the app without that
// step, the orphaned daemon keeps running, and the next launch starts a
// second one. Both then fight over the same Chromium profile and one of them
// fails every poll. Two guards close that:
//   1. an orphaned daemon notices its parent is gone and exits cleanly;
//   2. a starting daemon takes over the pid lock, asking a live previous
//      watcher to shut down (SIGTERM closes its browser and flushes cookies)
//      before it opens the profile itself, but only when that watcher is
//      orphaned. A watcher whose app is still running (a second installed
//      copy of iBacalao) is left alone: killing it makes that app restart it,
//      which kills ours, and the two loop closing each other's browser.

import { execFileSync } from "node:child_process";
import { readFileSync, rmSync, writeFileSync } from "node:fs";

export type DaemonLockDeps = {
  readPid: () => number | null;
  writePid: (pid: number) => void;
  isAlive: (pid: number) => boolean;
  /** Guards against pid reuse: only a process that is really a watcher gets signalled. */
  isWatcher: (pid: number) => boolean;
  /** True when the process's app is gone (re-parented to launchd). */
  isOrphan: (pid: number) => boolean;
  terminate: (pid: number) => void;
  sleep: (ms: number) => Promise<void>;
};

/** Returns false if another app's watcher holds the lock, or a previous watcher is still alive after `waitMs`; the caller must not open the profile then. */
export async function takeOverDaemonLock(
  selfPid: number,
  deps: DaemonLockDeps,
  { waitMs = 30_000, stepMs = 500 }: { waitMs?: number; stepMs?: number } = {},
): Promise<boolean> {
  const holder = deps.readPid();
  if (holder !== null && holder !== selfPid && deps.isAlive(holder) && deps.isWatcher(holder)) {
    if (!deps.isOrphan(holder)) return false;
    deps.terminate(holder);
    let waited = 0;
    while (deps.isAlive(holder)) {
      if (waited >= waitMs) return false;
      await deps.sleep(stepMs);
      waited += stepMs;
    }
  }
  deps.writePid(selfPid);
  return true;
}

/** A child whose parent died is re-parented (to launchd, pid 1), so its ppid changes. */
export function parentIsGone(startPpid: number, currentPpid: number): boolean {
  return currentPpid !== startPpid;
}

export function fileDaemonLockDeps(lockFile: string): DaemonLockDeps & { release: (selfPid: number) => void } {
  const readPid = () => {
    try {
      const pid = Number.parseInt(readFileSync(lockFile, "utf8").trim(), 10);
      return Number.isInteger(pid) && pid > 0 ? pid : null;
    } catch {
      return null;
    }
  };
  return {
    readPid,
    writePid: (pid) => writeFileSync(lockFile, `${pid}\n`, { mode: 0o600 }),
    isAlive: (pid) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch (error) {
        // EPERM: it exists but belongs to someone else — still alive.
        return (error as NodeJS.ErrnoException).code === "EPERM";
      }
    },
    isWatcher: (pid) => {
      try {
        return execFileSync("ps", ["-p", String(pid), "-o", "command="], { encoding: "utf8" }).includes("watcher-daemon");
      } catch {
        return false;
      }
    },
    isOrphan: (pid) => {
      try {
        return execFileSync("ps", ["-p", String(pid), "-o", "ppid="], { encoding: "utf8" }).trim() === "1";
      } catch {
        return false;
      }
    },
    terminate: (pid) => {
      try {
        process.kill(pid, "SIGTERM");
      } catch {
        // Already gone.
      }
    },
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
    // Only remove our own claim: a newer watcher may already have taken over.
    release: (selfPid) => {
      if (readPid() === selfPid) rmSync(lockFile, { force: true });
    },
  };
}
