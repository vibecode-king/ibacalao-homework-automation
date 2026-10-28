import type { ScrapedRecord } from "./types";

/**
 * Whether a local school mutation represents new academic reality rather than
 * iBacalao learning more about an already-known object.
 *
 * Old watcher clients do not send changeKind, so absence deliberately preserves
 * the historical behavior and records an event.
 */
export function shouldRecordSchoolHistory(record: ScrapedRecord): boolean {
  return record.changeKind !== "enriched" && record.changeKind !== "unchanged";
}
