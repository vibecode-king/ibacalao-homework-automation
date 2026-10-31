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
const ASSIGNMENT_KEY = /^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$/;

/** Same rule as SchoolDocHandler.safeKey in Swift. */
export function isSchoolDocKey(key: string): boolean {
  return ASSIGNMENT_KEY.test(key) && !key.includes("..");
}

export function schoolDocKey(sourceRecordId: string): string {
  const mapped = sourceRecordId.replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 120);
  if (!isSchoolDocKey(mapped)) {
    throw new Error("invalid school doc key");
  }
  return mapped;
}

export function saveSchoolOriginal(
  sourceRecordId: string,
  fileName: string,
  bytes: Uint8Array,
  root: string = SCHOOL_DOCS_DIR,
): string {
  let key: string;
  try {
    key = schoolDocKey(sourceRecordId);
  } catch {
    return "";
  }
  const dir = join(root, "originals", key);
  mkdirSync(dir, { recursive: true });
  const safeName = basename(fileName).replace(/[\\/:\0]/g, "_").slice(0, 160) || "attachment";
  const path = join(dir, safeName);
  writeFileSync(path, bytes);
  return path;
}

function prunePath(path: string, now: number): number {
  try {
    if (now - statSync(path).mtimeMs > MAX_AGE_MS) {
      rmSync(path, { recursive: true, force: true });
      return 1;
    }
  } catch { /* ignore one bad entry */ }
  return 0;
}

/** Deletes original files and draft files older than 30 days. Never throws:
 *  cleanup must not be able to take the watcher down. */
export function pruneSchoolDocs(root: string = SCHOOL_DOCS_DIR, now: number = Date.now()): number {
  let removed = 0;
  const originals = join(root, "originals");
  let folders: string[] = [];
  try { folders = readdirSync(originals); } catch { folders = []; }
  for (const name of folders) {
    const folder = join(originals, name);
    try {
      if (!statSync(folder).isDirectory()) {
        removed += prunePath(folder, now);
        continue;
      }
      let files: string[] = [];
      try { files = readdirSync(folder); } catch { continue; }
      for (const fileName of files) {
        removed += prunePath(join(folder, fileName), now);
      }
      try {
        if (readdirSync(folder).length === 0) {
          rmSync(folder, { recursive: true, force: true });
        }
      } catch { /* ignore */ }
    } catch { /* ignore one bad folder */ }
  }
  const drafts = join(root, "drafts");
  let draftFiles: string[] = [];
  try { draftFiles = readdirSync(drafts); } catch { draftFiles = []; }
  for (const name of draftFiles) {
    removed += prunePath(join(drafts, name), now);
  }
  return removed;
}
