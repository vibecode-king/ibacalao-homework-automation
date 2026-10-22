import { hostname } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";
import { runConfiguredAssignmentAgent } from "./agentRunner";
import { createAgentApiClient } from "./client";
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
const agentId = (process.env.IBACALAO_AGENT_ID || `${hostname()}-${process.pid}`).slice(0, 120);

const { request, submitCompletion } = createAgentApiClient(baseUrl, token);
let waitingMessageShown = false;

async function processOne(): Promise<boolean> {
  const result = await request<{ job: ClaimedJob | null }>("/api/agent/jobs/claim", { agentId, pollIntervalMs: pollMs });
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
  console.log(`[homework-agent] Claimed job ${job.id}; generating draft.`);
  const heartbeatInterval = setInterval(() => {
    void request("/api/agent/health", {
      agentId,
      status: "working",
      pollIntervalMs: pollMs,
      activeJobId: job.id,
    }).catch(() => undefined);
  }, 30_000);
  try {
    let output: Awaited<ReturnType<typeof runConfiguredAssignmentAgent>>;
    try {
      output = await runConfiguredAssignmentAgent(job.prompt, job.modelName);
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
    const completionBody = {
      claimToken: job.claimToken,
      artifactHtml: output.artifactHtml,
      engine: output.engine,
      model: output.model,
      qaResult: output.qaResult,
    };
    // A completion request can persist the artifact before returning an error.
    // Retrying the identical payload is safe; calling /fail here could consume a
    // claim token that the completion already cleared.
    const saved = await submitCompletion<{ job: { id: string; state: string }; message: string }>(completionPath, completionBody);
    console.log(`[homework-agent] Draft saved for review. Saved job ${saved.job.id} as ${saved.job.state}. The school platform was not changed.`);
    await request("/api/agent/health", { agentId, status: "idle", pollIntervalMs: pollMs }).catch(() => undefined);
    return true;
  } catch (error) {
    await request("/api/agent/health", { agentId, status: "error", pollIntervalMs: pollMs }).catch(() => undefined);
    throw error;
  } finally {
    clearInterval(heartbeatInterval);
  }
}

async function main(): Promise<void> {
  if (!token) throw new Error("Set IBACALAO_AGENT_TOKEN before starting the homework agent.");
  if (process.env.IBACALAO_AGENT_COMMAND?.trim()) {
    throw new Error("IBACALAO_AGENT_COMMAND is disabled because local CLI execution is not sandboxed. Unset it and configure IBACALAO_LLM_BASE_URL instead.");
  }
  if (!process.env.IBACALAO_LLM_BASE_URL?.trim() && !process.env.IBACALAO_LLM_API_KEY?.trim()) {
    throw new Error("Configure IBACALAO_LLM_BASE_URL for a BYOK or self-hosted model endpoint, and optionally set IBACALAO_LLM_API_KEY.");
  }
  console.log(`[homework-agent] Starting API mode (${once ? "one job" : `continuous polling every ${Math.ceil(pollMs / 1_000)} seconds`}).`);
  do {
    try {
      const found = await processOne();
      if (once) return;
      if (!found) await sleep(pollMs);
    } catch (error) {
      if (once) throw error;
      console.error(`[homework-agent] ${error instanceof Error ? error.message : "Agent cycle failed."}`);
      await sleep(pollMs);
    }
  } while (!once);
}

main().catch((error) => {
  console.error(`[homework-agent] stopped: ${error instanceof Error ? error.message : "Unknown error."}`);
  process.exitCode = 1;
});
