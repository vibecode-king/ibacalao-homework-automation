// lib/watcher/schoolDocs.ts
// The teacher's original assignment files, kept on the student's Mac so the
// app can open them as an editable draft. The watcher already downloads these
// to read their text; this just keeps the bytes instead of dropping them.
//
// Layout (shared with the Swift SchoolDocHandler, keep in sync):
//   ~/.ibacalao/school-docs/originals/<key>/<file name>
//   ~/.ibacalao/school-docs/drafts/<key>.docx + <key>.json
// <key> is the assignment's sourceRecordId made filesystem-safe.
//
// Nothing here leaves the Mac. Anything untouched for 30 days is deleted.

import { mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

export const SCHOOL_DOCS_DIR = join(homedir(), ".ibacalao", "school-docs");
const MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000;

/** Same rule as SchoolDocHandler.safeKey in Swift. */
export function schoolDocKey(sourceRecordId: string): string {
  return sourceRecordId.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 120);
}

export function saveSchoolOriginal(
  sourceRecordId: string,
  fileName: string,
  bytes: Uint8Array,
  root: string = SCHOOL_DOCS_DIR,
): string {
  const dir = join(root, "originals", schoolDocKey(sourceRecordId));
  mkdirSync(dir, { recursive: true });
  const safeName = basename(fileName).replace(/[\\/:\0]/g, "_").slice(0, 160) || "attachment";
  const path = join(dir, safeName);
  writeFileSync(path, bytes);
  return path;
}

/** Deletes originals folders and draft files older than 30 days. Never throws:
 *  cleanup must not be able to take the watcher down. */
export function pruneSchoolDocs(root: string = SCHOOL_DOCS_DIR, now: number = Date.now()): number {
  let removed = 0;
  for (const sub of ["originals", "drafts"]) {
    const dir = join(root, sub);
    let entries: string[];
    try { entries = readdirSync(dir); } catch { continue; }
    for (const name of entries) {
      const path = join(dir, name);
      try {
        if (now - statSync(path).mtimeMs > MAX_AGE_MS) {
          rmSync(path, { recursive: true, force: true });
          removed += 1;
        }
      } catch { /* ignore one bad entry */ }
    }
  }
  return removed;
}
