import type { ScrapedRecord } from "./types";
import type { WatcherSyncMode } from "./syncMode";

/** Enrichment updates do not trigger server-side automatic job creation. */
export function passiveUploadPlan(records: ScrapedRecord[], mode: WatcherSyncMode): Array<{ records: ScrapedRecord[]; mode: WatcherSyncMode }> {
  const isEnrichment = (record: ScrapedRecord) => record.kind === "assignment" && (record.changeKind === "enriched" || record.changeKind === "unchanged");
  const assignments = records.filter(isEnrichment);
  const otherRecords = records.filter((record) => !isEnrichment(record));
  return [
    ...(assignments.length ? [{ records: assignments, mode: "bootstrap" as const }] : []),
    ...(otherRecords.length ? [{ records: otherRecords, mode }] : []),
  ];
}
