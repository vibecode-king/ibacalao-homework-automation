import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { AgentApiError, createAgentApiClient } from "../src/client";

async function withApiResponse<T>(status: number, payload: unknown, run: (baseUrl: string) => Promise<T>): Promise<T> {
  const server = createServer((_req, res) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(payload));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  try {
    return await run(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  }
}

test("401 explains how to safely reconnect the worker without echoing its token", async () => {
  await withApiResponse(401, { error: "Unauthorized" }, async (baseUrl) => {
    const token = "agt_secret-token-must-not-appear";
    const client = createAgentApiClient(baseUrl, token);
    await assert.rejects(client.request("/api/agent/jobs/claim"), (error: unknown) => {
      assert.ok(error instanceof AgentApiError);
      assert.equal(error.status, 401);
      assert.match(error.message, /create a one-time pairing code/);
      assert.match(error.message, /npm run pair/);
      assert.match(error.message, /restart the worker/);
      assert.doesNotMatch(error.message, /agt_secret-token-must-not-appear/);
      return true;
    });
  });
});

test("AI consent rejection explains how to unblock claiming", async () => {
  await withApiResponse(403, { error: "ai_consent_required" }, async (baseUrl) => {
    const client = createAgentApiClient(baseUrl, "agt_test-token");
    await assert.rejects(client.request("/api/agent/jobs/claim"), (error: unknown) => {
      assert.ok(error instanceof AgentApiError);
      assert.equal(error.status, 403);
      assert.match(error.message, /AI-processing consent is required/);
      assert.match(error.message, /Enable consent in the signed-in Homework app/);
      return true;
    });
  });
});
