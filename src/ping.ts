import "./loadEnv";
import { setTimeout as sleep } from "node:timers/promises";
import { cliRunnerFromEnv, runConfiguredAssignmentAgent } from "./agentRunner";
import { AgentApiError, createAgentApiClient } from "./client";
import { buildDocxFromText } from "./docx";
import { resolveAgentId } from "./agentId";
import { Backoff, DailyBudget, limitsFromEnv } from "./budget";
import { normalizeAgentServiceBaseUrl } from "./network";

type ClaimedJob = {
  id: string;
  title: string;
  claimToken: string;
  prompt: string;
  modelName?: string;
};

const baseUrl = normalizeAgentServiceBaseUrl(process.env.IBACALAO_BASE_URL || "https://app.ibacalao.com");
const token = process.env.IBACALAO_AGENT_TOKEN?.trim();
const once = process.argv.includes("--once");
const pollMs = Math.max(5_000, Math.min(300_000, Number(process.env.IBACALAO_AGENT_POLL_MS) || 15_000));
const agentId = resolveAgentId("worker");

const { request, submitCompletion } = createAgentApiClient(baseUrl, token);
const budget = new DailyBudget(limitsFromEnv());
const backoff = new Backoff(pollMs);
let capMessageShown = false;
let waitingMessageShown = false;
let pausedMessageShown = false;
let activeJobId: string | null = null;
let activeClaimToken: string | null = null;

async function processOne(): Promise<boolean> {
  // Check caps before claiming so a capped agent never holds a lease or calls a model.
  const blocked = budget.blockedReason();
  if (blocked) {
    if (!capMessageShown) {
      console.log(`[homework-agent] Paused until tomorrow: ${blocked}. No assignment was claimed.`);
      capMessageShown = true;
    }
    return false;
  }
  capMessageShown = false;
  const result = await request<{ job: ClaimedJob | null; paused?: boolean; reason?: string }>("/api/agent/jobs/claim", { agentId, pollIntervalMs: pollMs });
  if (result.paused) {
    if (!pausedMessageShown) {
      const reason = typeof result.reason === "string" ? ` (${result.reason})` : "";
      console.log(`[homework-agent] The server paused assignment processing${reason}. No prompt was sent to a model.`);
      pausedMessageShown = true;
    }
    return false;
  }
  pausedMessageShown = false;
  const job = result.job;
  if (!job) {
    if (!waitingMessageShown) {
      const waitingMessage = once
        ? "no assignments are waiting."
        : `no assignments are waiting. Checking again in ${Math.ceil(pollMs / 1_000)} seconds.`;
      console.log(`[homework-agent] Connected to ${baseUrl}; ${waitingMessage}`);
      waitingMessageShown = true;
    }
    return false;
  }

  waitingMessageShown = false;
  activeJobId = job.id;
  activeClaimToken = job.claimToken;
  console.log(`[homework-agent] Claimed job ${job.id}; generating draft.`);
  try {
    if (!budget.beginAttempt(job.id)) {
      // The same job keeps coming back; stop spending on it and hand it back.
      await request(`/api/agent/jobs/${encodeURIComponent(job.id)}/fail`, {
        claimToken: job.claimToken,
        error: "Agent attempt limit reached for this assignment on this machine.",
      }).catch(() => undefined);
      throw new Error(`Skipped job ${job.id}: local attempt limit reached.`);
    }
    let output: Awaited<ReturnType<typeof runConfiguredAssignmentAgent>>;
    try {
      output = await runConfiguredAssignmentAgent(job.prompt, job.modelName);
      budget.recordTokens(output.tokensUsed ?? 0);
    } catch (error) {
      const message = error instanceof Error ? error.message.slice(0, 400) : "Agent failed.";
      let releaseConfirmed = false;
      try {
        await request(`/api/agent/jobs/${encodeURIComponent(job.id)}/fail`, { claimToken: job.claimToken, error: message });
        releaseConfirmed = true;
      } catch {
        // Report uncertainty rather than claiming that the job was released.
      }
      throw new Error(`Draft generation failed for job ${job.id}; ${releaseConfirmed ? "job released" : "job release could not be confirmed"}. ${message}`);
    }

    const completionPath = `/api/agent/jobs/${encodeURIComponent(job.id)}/complete`;
    let document: Buffer;
    try {
      document = buildDocxFromText(output.artifactText);
    } catch (error) {
      const message = error instanceof Error ? error.message.slice(0, 400) : "Generated document was invalid.";
      let releaseConfirmed = false;
      try {
        await request(`/api/agent/jobs/${encodeURIComponent(job.id)}/fail`, { claimToken: job.claimToken, error: message });
        releaseConfirmed = true;
      } catch {
        // Report uncertainty rather than claiming that the job was released.
      }
      throw new Error(`DOCX generation failed for job ${job.id}; ${releaseConfirmed ? "job released" : "job release could not be confirmed"}. ${message}`);
    }
    const completionMetadata = {
      claimToken: job.claimToken,
      engine: output.engine,
      model: output.model,
      qaResult: output.qaResult,
    };
    let saved: { job: { id: string; state: string }; message: string };
    try {
      // A completion request can persist the artifact before returning an error.
      // Retrying the identical payload is safe; calling /fail for an ambiguous
      // response could consume a claim token that the completion already cleared.
      saved = await submitCompletion<{ job: { id: string; state: string }; message: string }>(completionPath, document, completionMetadata);
    } catch (error) {
      // The server contract rejects invalid/oversized documents before saving.
      // These final 4xx responses cannot succeed by retrying; release the lease
      // so it does not sit idle until expiry and trigger another model call.
      if (error instanceof AgentApiError && (error.status === 400 || error.status === 413)) {
        const reason = ("Draft upload rejected: " + error.message).slice(0, 500);
        let releaseConfirmed = false;
        try {
          await request("/api/agent/jobs/" + encodeURIComponent(job.id) + "/fail", {
            claimToken: job.claimToken,
            error: reason,
          });
          releaseConfirmed = true;
        } catch {
          // Report uncertainty rather than claiming the lease was released.
        }
        throw new Error(
          "Draft upload rejected for job " + job.id + "; "
          + (releaseConfirmed ? "job released. " : "job release could not be confirmed. ")
          + error.message,
        );
      }
      throw error;
    }
    console.log(`[homework-agent] Draft saved for review. Saved job ${saved.job.id} as ${saved.job.state}. The school platform was not changed.`);
    activeJobId = null;
    activeClaimToken = null;
    await request("/api/agent/health", { agentId, status: "idle", pollIntervalMs: pollMs }).catch(() => undefined);
    return true;
  } catch (error) {
    activeJobId = null;
    activeClaimToken = null;
    await request("/api/agent/health", { agentId, status: "error", pollIntervalMs: pollMs }).catch(() => undefined);
    throw error;
  }
}

async function main(): Promise<void> {
  if (!token) throw new Error("Set IBACALAO_AGENT_TOKEN before starting the homework agent.");
  if (process.env.IBACALAO_AGENT_COMMAND?.trim()) {
    throw new Error("IBACALAO_AGENT_COMMAND is disabled because local CLI execution is not sandboxed. Unset it and configure IBACALAO_LLM_BASE_URL instead.");
  }
  if (!cliRunnerFromEnv() && !process.env.IBACALAO_LLM_BASE_URL?.trim() && !process.env.IBACALAO_LLM_API_KEY?.trim()) {
    throw new Error("Configure IBACALAO_LLM_BASE_URL for a BYOK or self-hosted model endpoint, and optionally set IBACALAO_LLM_API_KEY.");
  }
  console.log(`[homework-agent] Starting API mode (${once ? "one job" : `continuous polling every ${Math.ceil(pollMs / 1_000)} seconds`}).`);
  const reportHealth = () => request("/api/agent/health", {
    agentId,
    status: activeJobId ? "working" : "polling",
    pollIntervalMs: pollMs,
    ...(activeJobId ? { activeJobId } : {}),
  }).catch(() => undefined);
  await reportHealth();
  const heartbeat = setInterval(() => { void reportHealth(); }, 30_000);
  let stopping = false;
  const releaseAndExit = (signal: string) => {
    if (stopping) return;
    stopping = true;
    clearInterval(heartbeat);
    void (async () => {
      // Hand an unfinished job back now instead of leaving it leased until expiry.
      if (activeJobId && activeClaimToken) {
        await request(`/api/agent/jobs/${encodeURIComponent(activeJobId)}/fail`, {
          claimToken: activeClaimToken,
          error: `Agent stopped (${signal}) before finishing.`,
        }).catch(() => undefined);
      }
      await request("/api/agent/health", { agentId, status: "idle", pollIntervalMs: pollMs }).catch(() => undefined);
      process.exit(0);
    })();
  };
  process.once("SIGINT", () => releaseAndExit("SIGINT"));
  process.once("SIGTERM", () => releaseAndExit("SIGTERM"));
  try {
    do {
      try {
        const found = await processOne();
        backoff.success();
        if (once) return;
        if (!found) await sleep(pollMs);
      } catch (error) {
        if (once) throw error;
        const waitMs = backoff.failure();
        console.error(`[homework-agent] ${error instanceof Error ? error.message : "Agent cycle failed."} Retrying in ${Math.ceil(waitMs / 1_000)} seconds.`);
        await sleep(waitMs);
      }
    } while (!once);
  } finally {
    clearInterval(heartbeat);
  }
}

main().catch((error) => {
  console.error(`[homework-agent] stopped: ${error instanceof Error ? error.message : "Unknown error."}`);
  process.exitCode = 1;
});
