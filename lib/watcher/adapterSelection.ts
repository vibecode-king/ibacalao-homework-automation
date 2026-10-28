// lib/watcher/adapterSelection.ts
// Pure and I/O-free — the piece of scripts/watcher-daemon.ts's adapter
// selection worth testing in isolation. Extracted specifically because
// scripts/watcher-daemon.ts runs its CLI unconditionally at import time (no
// `if (require.main === module)` guard), so it cannot be safely imported
// from a test the way lib/ modules can.
import { createHash } from "node:crypto";
import { createLearnboxAdapter } from "./adapters/learnbox";
import { createManageBacAdapter } from "./adapters/managebac";
import { DEFAULT_SCHOOL_JOURNAL_FILE } from "../school/journal";
import type { PlatformAdapter } from "./types";

export type MinimalConnection = { platformId: string; origin: string; recognized?: boolean };

/**
 * Learnbox and ManageBac are multi-tenant (school-specific origins), so their
 * adapters are built per-connection from the discovered origin rather than
 * looked up directly in the static platform -> adapter map. Every other
 * bundled platform is a plain map lookup, which
 * returns undefined (→ the daemon's passive-capture fallback) for anything
 * not yet bundled.
 */
export function resolveConfiguredAdapter(
  connection: MinimalConnection | null,
  staticAdapters: Record<string, PlatformAdapter>,
): PlatformAdapter | undefined {
  if (!connection) return undefined;
  if (connection.platformId === "learnbox") return createLearnboxAdapter(connection.origin, { journalFile: DEFAULT_SCHOOL_JOURNAL_FILE });
  if (connection.platformId === "managebac") return createManageBacAdapter(connection.origin);
  return staticAdapters[connection.platformId];
}

/**
 * Ingest identity for a discovered connection.
 *
 * Only platforms in the daemon's *static* adapter map own `vendor:<id>`.
 * Learnbox is built per-origin, so it stays `portal:<origin hash>` — the same
 * key the Chrome extension journal and passive engine already use. Uploading
 * as the bare id `learnbox` would split those captures from the active crawl.
 */
export function sourceKeyForConnection(
  connection: MinimalConnection,
  staticAdapters: Record<string, unknown>,
): string {
  if (connection.recognized && Object.prototype.hasOwnProperty.call(staticAdapters, connection.platformId)) {
    return `vendor:${connection.platformId}`;
  }
  return `portal:${createHash("sha256").update(connection.origin).digest("hex").slice(0, 32)}`;
}
