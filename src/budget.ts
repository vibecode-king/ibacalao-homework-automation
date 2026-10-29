import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type BudgetLimits = { maxJobsPerDay: number; maxTokensPerDay: number; maxAttemptsPerJob: number };
type Usage = { day: string; jobs: number; tokens: number; attempts: Record<string, number> };

const DEFAULTS: BudgetLimits = { maxJobsPerDay: 20, maxTokensPerDay: 400_000, maxAttemptsPerJob: 2 };

function positiveInt(value: string | undefined, fallback: number, max: number): number {
  const parsed = Math.round(Number(value));
  return Number.isFinite(parsed) && parsed > 0 ? Math.min(parsed, max) : fallback;
}

export function limitsFromEnv(env: NodeJS.ProcessEnv = process.env): BudgetLimits {
  return {
    maxJobsPerDay: positiveInt(env.IBACALAO_MAX_JOBS_PER_DAY, DEFAULTS.maxJobsPerDay, 500),
    maxTokensPerDay: positiveInt(env.IBACALAO_MAX_TOKENS_PER_DAY, DEFAULTS.maxTokensPerDay, 20_000_000),
    maxAttemptsPerJob: positiveInt(env.IBACALAO_MAX_ATTEMPTS_PER_JOB, DEFAULTS.maxAttemptsPerJob, 10),
  };
}

const dayKey = (now: Date) => `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;

/**
 * Local spend guard for the student's own model key. Persisted so a restart
 * cannot reset the day's counters; resets on the local calendar day.
 */
export class DailyBudget {
  private usage: Usage;
  constructor(
    private readonly limits: BudgetLimits,
    private readonly file = join(process.env.IBACALAO_STATE_DIR?.trim() || join(homedir(), ".ibacalao-homework"), "usage.json"),
    private readonly clock: () => Date = () => new Date(),
  ) {
    this.usage = this.load();
  }

  private load(): Usage {
    const today = dayKey(this.clock());
    try {
      if (existsSync(this.file)) {
        const parsed = JSON.parse(readFileSync(this.file, "utf8")) as Partial<Usage>;
        if (parsed.day === today && Number.isFinite(parsed.jobs) && Number.isFinite(parsed.tokens)) {
          return { day: today, jobs: Number(parsed.jobs), tokens: Number(parsed.tokens), attempts: parsed.attempts && typeof parsed.attempts === "object" ? parsed.attempts : {} };
        }
      }
    } catch { /* corrupt file: start the day fresh */ }
    return { day: today, jobs: 0, tokens: 0, attempts: {} };
  }

  private save(): void {
    try {
      mkdirSync(join(this.file, ".."), { recursive: true, mode: 0o700 });
      const tmp = `${this.file}.tmp`;
      writeFileSync(tmp, JSON.stringify(this.usage), { mode: 0o600 });
      chmodSync(tmp, 0o600);
      renameSync(tmp, this.file);
    } catch { /* read-only home: counters still hold for this process */ }
  }

  private rollover(): void {
    if (this.usage.day !== dayKey(this.clock())) this.usage = { day: dayKey(this.clock()), jobs: 0, tokens: 0, attempts: {} };
  }

  /** Reason string when no further job may be started today, otherwise null. */
  blockedReason(): string | null {
    this.rollover();
    if (this.usage.jobs >= this.limits.maxJobsPerDay) return `daily job cap of ${this.limits.maxJobsPerDay} reached`;
    if (this.usage.tokens >= this.limits.maxTokensPerDay) return `daily token cap of ${this.limits.maxTokensPerDay} reached`;
    return null;
  }

  /** Counts a model attempt for this job. False when it already used its attempts. */
  beginAttempt(jobId: string): boolean {
    this.rollover();
    const used = this.usage.attempts[jobId] ?? 0;
    if (used >= this.limits.maxAttemptsPerJob) return false;
    this.usage.attempts[jobId] = used + 1;
    this.usage.jobs += 1;
    this.save();
    return true;
  }

  recordTokens(tokens: number): void {
    this.rollover();
    if (Number.isFinite(tokens) && tokens > 0) this.usage.tokens += Math.round(tokens);
    this.save();
  }

  snapshot(): Readonly<Usage> { this.rollover(); return this.usage; }
}

/** Exponential backoff with a ceiling; reset on success. */
export class Backoff {
  private failures = 0;
  constructor(private readonly baseMs: number, private readonly maxMs = 10 * 60_000) {}
  success(): void { this.failures = 0; }
  failure(): number {
    this.failures += 1;
    return Math.min(this.maxMs, this.baseMs * 2 ** Math.min(this.failures - 1, 10));
  }
}
