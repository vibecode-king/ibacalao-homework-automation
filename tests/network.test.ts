import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizeAgentServiceBaseUrl } from "../src/network";
import { readBoundedModelResponse, runConfiguredAssignmentAgent } from "../src/agentRunner";

test("agent service URLs require HTTPS except for explicit loopback hosts", () => {
  assert.equal(normalizeAgentServiceBaseUrl("https://models.invalid/v1/"), "https://models.invalid/v1");
  assert.equal(normalizeAgentServiceBaseUrl("http://127.0.0.1:8080/v1"), "http://127.0.0.1:8080/v1");
  assert.throws(() => normalizeAgentServiceBaseUrl("http://models.invalid/v1"), /must use HTTPS/);
  assert.throws(() => normalizeAgentServiceBaseUrl("https://user:pass@models.invalid/v1"), /cannot contain credentials/);
  assert.throws(() => normalizeAgentServiceBaseUrl("https://models.invalid/v1?key=synthetic"), /cannot contain credentials/);
});

test("model responses are rejected above the configured byte limit", async () => {
  await assert.rejects(
    readBoundedModelResponse(new Response("synthetic response body"), 8),
    /exceeded the size limit/,
  );
  assert.equal(await readBoundedModelResponse(new Response("small"), 8), "small");
});

test("BYOK model requests refuse redirects", async () => {
  const saved = {
    command: process.env.IBACALAO_AGENT_COMMAND,
    baseUrl: process.env.IBACALAO_LLM_BASE_URL,
    apiKey: process.env.IBACALAO_LLM_API_KEY,
    model: process.env.IBACALAO_LLM_MODEL,
  };
  const originalFetch = globalThis.fetch;
  let redirectMode: RequestRedirect | undefined;
  delete process.env.IBACALAO_AGENT_COMMAND;
  process.env.IBACALAO_LLM_BASE_URL = "https://models.invalid/v1";
  delete process.env.IBACALAO_LLM_API_KEY;
  process.env.IBACALAO_LLM_MODEL = "synthetic-model";
  globalThis.fetch = async (_input, init) => {
    redirectMode = init?.redirect;
    return new Response(JSON.stringify({
      choices: [{ message: { content: JSON.stringify({ artifactText: "Synthetic result" }) } }],
    }), { status: 200, headers: { "content-type": "application/json" } });
  };
  try {
    const result = await runConfiguredAssignmentAgent("Synthetic prompt only.");
    assert.equal(result.artifactText, "Synthetic result");
    assert.equal(redirectMode, "error");
  } finally {
    globalThis.fetch = originalFetch;
    for (const [key, value] of Object.entries({
      IBACALAO_AGENT_COMMAND: saved.command,
      IBACALAO_LLM_BASE_URL: saved.baseUrl,
      IBACALAO_LLM_API_KEY: saved.apiKey,
      IBACALAO_LLM_MODEL: saved.model,
    })) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});
