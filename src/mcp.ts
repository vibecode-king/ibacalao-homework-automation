import { z } from "zod";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { hostname } from "node:os";
import { createAgentApiClient } from "./client";
import { buildDocxFromText } from "./docx";
import { normalizeAgentServiceBaseUrl } from "./network";
import { wrapUntrustedAssignment } from "./prompt";

// MCP mode: the user's own AI client (a Claude or ChatGPT subscription, a local
// model host, etc.) does the writing. This process only moves jobs between the
// iBacalao server and that client, so no model API key is needed here.

const baseUrl = normalizeAgentServiceBaseUrl(process.env.IBACALAO_BASE_URL || "https://app.ibacalao.com");
const token = process.env.IBACALAO_AGENT_TOKEN?.trim();
const agentId = (process.env.IBACALAO_AGENT_ID || `${hostname()}-mcp-${process.pid}`).slice(0, 120);
const { request, submitCompletion } = createAgentApiClient(baseUrl, token);

type ClaimedJob = { id: string; title: string; claimToken: string; prompt: string; leaseMinutes?: number; modelName?: string };
let activeJobId: string | null = null;
const reportHealth = (status: "polling" | "idle" | "working" | "error", jobId?: string) => request("/api/agent/health", {
  agentId,
  status,
  pollIntervalMs: 30_000,
  ...(jobId ? { activeJobId: jobId } : {}),
}).catch(() => undefined);

const text = (value: string) => ({ content: [{ type: "text" as const, text: value }] });
const failure = (error: unknown) => ({
  isError: true,
  content: [{ type: "text" as const, text: error instanceof Error ? error.message : "Request failed." }],
});

const server = new McpServer({ name: "ibacalao-homework-automation", version: "0.1.0" });

server.registerTool(
  "claim_homework_job",
  {
    description: "Claim the next queued homework job. If the server reports that processing is paused, no assignment is claimed or sent to an AI provider.",
    inputSchema: {},
  },
  async () => {
    try {
      const result = await request<{ job: ClaimedJob | null; paused?: boolean; reason?: string }>("/api/agent/jobs/claim", { agentId, pollIntervalMs: 30_000 });
      if (result.paused) {
        activeJobId = null;
        await reportHealth("idle");
        const reason = typeof result.reason === "string" ? ` (${result.reason})` : "";
        return text(`Homework drafting is paused on this server${reason}. No assignment was claimed or sent to an AI provider.`);
      }
      const { job } = result;
      if (!job) {
        activeJobId = null;
        await reportHealth("idle");
        return text("No homework jobs are waiting.");
      }
      activeJobId = job.id;
      await reportHealth("working", activeJobId);
      return text([
        `jobId: ${job.id}`,
        `title: ${job.title}`,
        `claimToken: ${job.claimToken}`,
        `leaseMinutes: ${job.leaseMinutes ?? 15}`,
        ...(job.modelName ? [`modelName: ${job.modelName}`] : []),
        "",
        wrapUntrustedAssignment(job.prompt),
        "",
        "When done, call submit_homework_draft with artifactText containing the complete draft as plain text or Markdown (never HTML). If you cannot finish, call fail_homework_job.",
      ].join("\n"));
    } catch (error) {
      activeJobId = null;
      await reportHealth("error");
      return failure(error);
    }
  },
);

server.registerTool(
  "submit_homework_draft",
  {
    description: "Submit a finished draft as a DOCX for student review. Supply the complete draft as plain text or Markdown; HTML is rejected. Nothing is submitted to the school.",
    inputSchema: {
      jobId: z.string().min(1).max(200),
      claimToken: z.string().min(20).max(500),
      artifactText: z.string().min(1).max(500_000),
      model: z.string().max(160).optional(),
    },
  },
  async ({ jobId, claimToken, artifactText, model }) => {
    try {
      const document = buildDocxFromText(artifactText);
      const saved = await submitCompletion<{ job: { id: string; state: string }; message: string }>(
        `/api/agent/jobs/${encodeURIComponent(jobId)}/complete`,
        document,
        { claimToken, engine: "mcp-client", model: model ?? "mcp-client" },
      );
      activeJobId = null;
      await reportHealth("idle");
      return text(`Saved ${saved.job.id} as ${saved.job.state}. The school platform was not changed.`);
    } catch (error) {
      activeJobId = null;
      await reportHealth("error");
      return failure(error);
    }
  },
);

server.registerTool(
  "fail_homework_job",
  {
    description: "Release a claimed job you could not finish, with a short reason.",
    inputSchema: {
      jobId: z.string().min(1).max(200),
      claimToken: z.string().min(20).max(500),
      reason: z.string().max(400),
    },
  },
  async ({ jobId, claimToken, reason }) => {
    try {
      await request(`/api/agent/jobs/${encodeURIComponent(jobId)}/fail`, { claimToken, error: reason });
      activeJobId = null;
      await reportHealth("idle");
      return text("Job released.");
    } catch (error) {
      activeJobId = null;
      await reportHealth("error");
      return failure(error);
    }
  },
);

async function main(): Promise<void> {
  if (!token) throw new Error("Set IBACALAO_AGENT_TOKEN before starting the MCP server.");
  await server.connect(new StdioServerTransport());
  void reportHealth("polling");
  const heartbeat = setInterval(() => { void reportHealth(activeJobId ? "working" : "polling", activeJobId ?? undefined); }, 30_000);
  const stopHeartbeat = () => clearInterval(heartbeat);
  process.once("SIGINT", stopHeartbeat);
  process.once("SIGTERM", stopHeartbeat);
  process.stdin.once("end", stopHeartbeat);
}

main().catch((error) => {
  console.error(`[homework-mcp] stopped: ${error instanceof Error ? error.message : "Unknown error."}`);
  process.exitCode = 1;
});
