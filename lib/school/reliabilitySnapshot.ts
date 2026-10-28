// lib/school/reliabilitySnapshot.ts
// A local, five-minute diagnosis of the school connector — no live LMS.

import type { DatabaseSync } from "node:sqlite";
import { existsSync, readFileSync } from "node:fs";
import { explainChainState, readChainTelemetry, type ChainState, type ChainTelemetry } from "./chainTelemetry";
import {
  DEFAULT_SCHOOL_JOURNAL_FILE,
  openSchoolJournal,
  unacknowledgedCaptureCount,
  unacknowledgedSyncAttempts,
  type SyncAttempt,
} from "./journal";
import { DEFAULT_SCHOOL_ENTITY_FILE } from "./entityStore";

export type SchoolReliabilitySnapshot = {
  capturedAt: string;
  sourceKey: string;
  chain: ChainState;
  telemetry: ChainTelemetry;
  unacknowledgedCaptures: number;
  pendingAttempts: Array<Pick<SyncAttempt, "syncAttemptId" | "state" | "lastError" | "attemptCount">>;
  recipeCount: number;
  entityCount: number;
  journalReadable: boolean;
};

function countRecipes(recipeFile: string | undefined, sourceKey: string): number {
  if (!recipeFile || !existsSync(recipeFile)) return 0;
  try {
    const parsed = JSON.parse(readFileSync(recipeFile, "utf8")) as {
      sources?: Record<string, { recipes?: unknown[] }>;
    };
    return parsed.sources?.[sourceKey]?.recipes?.length ?? 0;
  } catch {
    return 0;
  }
}

function countEntities(entityFile: string | undefined, sourceKey: string): number {
  const file = entityFile ?? DEFAULT_SCHOOL_ENTITY_FILE;
  if (!existsSync(file)) return 0;
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8")) as {
      sources?: Record<string, { entities?: unknown[] }>;
    };
    return parsed.sources?.[sourceKey]?.entities?.length ?? 0;
  } catch {
    return 0;
  }
}

export function readReliabilitySnapshot(options: {
  sourceKey: string;
  journalFile?: string;
  recipeFile?: string;
  entityFile?: string;
  nowMs?: number;
}): SchoolReliabilitySnapshot {
  const capturedAt = new Date(options.nowMs ?? Date.now()).toISOString();
  let db: DatabaseSync | undefined;
  const emptyTelemetry: ChainTelemetry = {
    lastBrowserObservationAt: null,
    lastNativePersistAt: null,
    lastDaemonConsumeAt: null,
    lastExtractSuccessAt: null,
    lastReconcileSuccessAt: null,
    lastUploadAttemptAt: null,
    lastServerAckAt: null,
    unacknowledgedCaptures: 0,
  };
  try {
    db = openSchoolJournal(options.journalFile ?? DEFAULT_SCHOOL_JOURNAL_FILE);
    const telemetry = readChainTelemetry(db, options.sourceKey);
    return {
      capturedAt,
      sourceKey: options.sourceKey,
      chain: explainChainState(telemetry, options.nowMs),
      telemetry,
      unacknowledgedCaptures: unacknowledgedCaptureCount(db, options.sourceKey),
      pendingAttempts: unacknowledgedSyncAttempts(db, options.sourceKey).map((attempt) => ({
        syncAttemptId: attempt.syncAttemptId,
        state: attempt.state,
        lastError: attempt.lastError,
        attemptCount: attempt.attemptCount,
      })),
      recipeCount: countRecipes(options.recipeFile, options.sourceKey),
      entityCount: countEntities(options.entityFile, options.sourceKey),
      journalReadable: true,
    };
  } catch {
    return {
      capturedAt,
      sourceKey: options.sourceKey,
      chain: "bridge_disconnected",
      telemetry: emptyTelemetry,
      unacknowledgedCaptures: 0,
      pendingAttempts: [],
      recipeCount: countRecipes(options.recipeFile, options.sourceKey),
      entityCount: countEntities(options.entityFile, options.sourceKey),
      journalReadable: false,
    };
  } finally {
    db?.close();
  }
}
