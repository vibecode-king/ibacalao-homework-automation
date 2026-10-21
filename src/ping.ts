import { hostname } from "node:os";
import { setTimeout as sleep } from "node:timers/promises";
import { readBoundedModelResponse, runConfiguredAssignmentAgent } from "./agentRunner";
import { normalizeAgentServiceBaseUrl } from "./network";

type ClaimedJob = {
  id: string;
  title: string;
  claimToken: string;
  prompt: string;
};

const baseUrl = normalizeAgentServiceBaseUrl(process.env.IBACALAO_BASE_URL || "https://app.ibacalao.com");
const token = process.env.IBACALAO_AGENT_TOKEN?.trim();
const once = process.argv.includes("--once");
const pollMs = Math.max(5_000, Math.min(300_000, Number(process.env.IBACALAO_AGENT_POLL_MS) || 15_000));
const agentId = (process.env.IBACALAO_AGENT_ID || `${hostname()}-${process.pid}`).slice(0, 120);
const MAX_AGENT_API_RESPONSE_BYTES = 2 * 1024 * 1024;

async function request<T>(path: string, body?: unknown): Promise<T> {
  if (!token) throw new Error("Set IBACALAO_AGENT_TOKEN in this terminal before starting Ping Bot.");
  let response: Response;
  try {
    response = await fetch(`${baseUrl}${path}`, {
      method: body === undefined ? "GET" : "POST",
      headers: {
        authorization: `Bearer ${token}`,
        ...(body === undefined ? {} : { "content-type": "application/json" }),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      signal: AbortSignal.timeout(30_000),
      redirect: "error",
    });
  } catch {
    throw new Error(`Could not reach ${baseUrl}. Check the server URL and network connection.`);
  }
  const responseText = await readBoundedModelResponse(response, MAX_AGENT_API_RESPONSE_BYTES);
  const payload = (() => {
    try { return JSON.parse(responseText) as Record<string, unknown>; }
    catch { return null; }
  })();
  if (!response.ok) {
    const message = typeof payload?.error === "string" ? payload.error : `HTTP ${response.status}`;
    throw new Error(`iBacalao agent API returned ${response.status}: ${message}`);
  }
  return payload as T;
}

function isRetryableCompletionError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return /iBacalao agent API returned 5\d\d:/.test(message) || /Could not reach /.test(message);
}

async function submitCompletion<T>(path: string, body: unknown): Promise<T> {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await request<T>(path, body);
    } catch (error) {
      if (!isRetryableCompletionError(error) || attempt >= 2) throw error;
      await sleep(attempt === 0 ? 250 : 750);
    }
  }
}

async function processOne(): Promise<boolean> {
  const result = await request<{ job: ClaimedJob | null }>("/api/agent/jobs/claim", { agentId, pollIntervalMs: pollMs });
  const job = result.job;
  if (!job) return false;

  console.log(`[ping-bot] Claimed ${job.id}: ${job.title}`);
  let output: Awaited<ReturnType<typeof runConfiguredAssignmentAgent>>;
  try {
    output = await runConfiguredAssignmentAgent(job.prompt);
  } catch (error) {
    const message = error instanceof Error ? error.message.slice(0, 400) : "Agent failed.";
    await request(`/api/agent/jobs/${encodeURIComponent(job.id)}/fail`, { claimToken: job.claimToken, error: message }).catch(() => undefined);
    throw error;
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
  console.log(`[ping-bot] Saved ${saved.job.id} as ${saved.job.state}. The school platform was not changed.`);
  return true;
}

async function main(): Promise<void> {
  if (!token) throw new Error("Set IBACALAO_AGENT_TOKEN before starting Ping Bot.");
  if (process.env.IBACALAO_AGENT_COMMAND?.trim()) {
    throw new Error("IBACALAO_AGENT_COMMAND is disabled because local CLI execution is not sandboxed. Unset it and configure IBACALAO_LLM_BASE_URL instead.");
  }
  if (!process.env.IBACALAO_LLM_BASE_URL?.trim() && !process.env.IBACALAO_LLM_API_KEY?.trim()) {
    throw new Error("Configure IBACALAO_LLM_BASE_URL for a BYOK or self-hosted model endpoint, and optionally set IBACALAO_LLM_API_KEY.");
  }
  console.log(`[ping-bot] Connected to ${baseUrl}; agent id ${agentId}; mode ${once ? "one job" : "continuous"}.`);
  do {
    try {
      const found = await processOne();
      if (once) return;
      if (!found) await sleep(pollMs);
    } catch (error) {
      console.error(`[ping-bot] ${error instanceof Error ? error.message : "Agent cycle failed."}`);
      if (once) throw error;
      await sleep(pollMs);
    }
  } while (!once);
}

main().catch((error) => {
  console.error(`[ping-bot] stopped: ${error instanceof Error ? error.message : "Unknown error."}`);
  process.exitCode = 1;
});
