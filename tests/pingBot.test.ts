import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { join } from "node:path";

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk: string) => { body += chunk; });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function send(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

test("Homework agent claims a job, calls the configured model endpoint, and sends the artifact for review", async () => {
  const completions: Record<string, unknown>[] = [];
  let modelPrompt = "";
  let claimCount = 0;
  let completionCount = 0;
  let failCount = 0;
  const server = createServer(async (req, res) => {
    const bodyText = await readBody(req);
    const body = bodyText ? JSON.parse(bodyText) as Record<string, unknown> : {};
    if (req.method === "POST" && req.url === "/v1/chat/completions") {
      const request = body as { messages?: Array<{ content?: string }> };
      modelPrompt = request.messages?.[1]?.content ?? "";
      send(res, 200, {
        model: "local-test-model",
        choices: [{ message: { content: JSON.stringify({
          artifactHtml: "<h1>Review draft</h1><p>Local endpoint draft</p>",
          engine: "test-endpoint",
          model: "local-test-model",
          qaResult: { status: "self_checked", checks: [] },
        }) } }],
      });
      return;
    }
    if (req.headers.authorization !== "Bearer agt_test_token") {
      send(res, 401, { error: "Unauthorized" });
      return;
    }
    if (req.method === "POST" && req.url === "/api/agent/jobs/claim") {
      claimCount += 1;
      send(res, 200, { job: {
        id: "job-e2e-1",
        title: "History source comparison",
        claimToken: "claim-token-for-test-only-0001",
        prompt: "Create a short, reviewable source comparison.",
      } });
      return;
    }
    if (req.method === "POST" && req.url === "/api/agent/jobs/job-e2e-1/complete") {
      completions.push(body);
      completionCount += 1;
      if (completionCount === 1) {
        send(res, 503, { error: "temporary persistence failure" });
        return;
      }
      send(res, 200, { job: { id: "job-e2e-1", state: "ready_for_review" }, message: "Saved for review." });
      return;
    }
    if (req.method === "POST" && req.url === "/api/agent/jobs/job-e2e-1/fail") {
      failCount += 1;
      send(res, 200, { job: { id: "job-e2e-1", state: "snapshotted" } });
      return;
    }
    send(res, 404, { error: "Not found" });
  });

  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address !== "string");

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    IBACALAO_BASE_URL: `http://127.0.0.1:${address.port}`,
    IBACALAO_AGENT_TOKEN: "agt_test_token",
    IBACALAO_AGENT_ID: "homework-agent-e2e",
  };
  env.IBACALAO_LLM_BASE_URL = "http://127.0.0.1:" + address.port + "/v1";
  env.IBACALAO_LLM_MODEL = "local-test-model";
  env.IBACALAO_LLM_API_KEY = "local-only-test-key";
  const script = join(process.cwd(), "src/ping.ts");

  try {
    const child = spawn(process.execPath, ["--import", "tsx", script, "--once"], { cwd: process.cwd(), env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
    const [code] = await once(child, "close") as [number | null];
    assert.equal(code, 0, `Homework agent exited unsuccessfully. stdout=${stdout} stderr=${stderr}`);
    assert.equal(claimCount, 1);
    assert.match(modelPrompt, /short, reviewable source comparison/);
    assert.equal(completionCount, 2, "the exact completion payload should be retried after a transient server error");
    assert.deepEqual(completions[1], completions[0]);
    assert.equal(failCount, 0, "a completion error must not send /fail with an already-consumed claim token");
    const completion = completions[0];
    assert.ok(completion);
    assert.equal(completion.claimToken, "claim-token-for-test-only-0001");
    assert.match(String(completion.artifactHtml), /<h1>Review draft<\/h1>/);
    assert.equal(completion.engine, "test-endpoint");
    assert.equal(completion.model, "local-test-model");
    assert.deepEqual(completion.qaResult, { status: "self_checked", checks: [] });
    assert.match(stdout, /Saved job job-e2e-1 as ready_for_review/);
  } finally {
    server.close();
  }
});

test("Homework agent rejects local CLI mode before claiming an assignment", async () => {
  const env = {
    ...process.env,
    IBACALAO_BASE_URL: "http://127.0.0.1:1",
    IBACALAO_AGENT_TOKEN: "agt_test_token",
    IBACALAO_AGENT_COMMAND: process.execPath,
    IBACALAO_AGENT_ARGS_JSON: '["-e","process.stdout.write(\\"should-not-run\\")"]',
  };
  const script = join(process.cwd(), "src/ping.ts");
  const child = spawn(process.execPath, ["--import", "tsx", script, "--once"], {
    cwd: process.cwd(),
    env,
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
  const [code] = await once(child, "close") as [number | null];
  assert.equal(code, 1);
  assert.match(stderr, /IBACALAO_AGENT_COMMAND is disabled/);
  assert.doesNotMatch(stdout, /Claimed/);
});

test("Homework agent rejects an oversized agent API response before parsing or contacting the model", async () => {
  let modelCalled = false;
  const server = createServer(async (req, res) => {
    if (req.method === "POST" && req.url === "/api/agent/jobs/claim") {
      const oversized = " ".repeat(2 * 1024 * 1024 + 1);
      res.writeHead(200, { "content-type": "application/json", "content-length": String(Buffer.byteLength(oversized)) });
      res.end(oversized);
      return;
    }
    if (req.method === "POST" && req.url === "/v1/chat/completions") modelCalled = true;
    send(res, 404, { error: "Unexpected synthetic request" });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address !== "string");

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    IBACALAO_BASE_URL: `http://127.0.0.1:${address.port}`,
    IBACALAO_AGENT_TOKEN: "agt_synthetic-test-token",
    IBACALAO_AGENT_ID: "homework-agent-size-test",
    IBACALAO_LLM_BASE_URL: `http://127.0.0.1:${address.port}/v1`,
    IBACALAO_LLM_API_KEY: "synthetic-local-key",
  };
  const script = join(process.cwd(), "src/ping.ts");
  try {
    const child = spawn(process.execPath, ["--import", "tsx", script, "--once"], { cwd: process.cwd(), env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
    const [code] = await once(child, "close") as [number | null];
    assert.equal(code, 1, `Homework agent should fail closed. stdout=${stdout} stderr=${stderr}`);
    assert.match(stderr, /upstream response exceeded the size limit/i);
    assert.equal(modelCalled, false);
  } finally {
    server.close();
  }
});
