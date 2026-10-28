import { readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

const STALE_TEMP_MS = 10 * 60 * 1000;

/**
 * Write-then-rename so a reader never sees a half-written file. A process
 * killed between the two steps leaves `<file>.<pid>.tmp` behind; those are
 * swept on the next write so ~/.ibacalao does not fill with orphans.
 */
export function writeFileAtomic(file: string, data: string, now = Date.now()): void {
  const temporary = `${file}.${process.pid}.tmp`;
  try {
    writeFileSync(temporary, data, { mode: 0o600 });
    renameSync(temporary, file);
  } catch (error) {
    rmSync(temporary, { force: true });
    throw error;
  }
  sweepStaleTemps(file, now);
}

function sweepStaleTemps(file: string, now: number): void {
  const prefix = `${basename(file)}.`;
  try {
    for (const name of readdirSync(dirname(file))) {
      if (!name.startsWith(prefix) || !/^\d+\.tmp$/.test(name.slice(prefix.length))) continue;
      const path = join(dirname(file), name);
      if (now - statSync(path).mtimeMs > STALE_TEMP_MS) rmSync(path, { force: true });
    }
  } catch {
    // Housekeeping only; the real write already succeeded.
  }
}
