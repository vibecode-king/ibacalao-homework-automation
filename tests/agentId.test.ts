import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { resolveAgentId } from "../src/agentId";

test("agent id is random, stable per install and never contains the hostname", () => {
  const dir = mkdtempSync(join(tmpdir(), "ib-agent-id-"));
  const first = resolveAgentId("worker", {}, dir);
  const second = resolveAgentId("mcp", {}, dir);
  assert.match(first, /^worker-[a-f0-9]{16}-\d+$/);
  assert.equal(first.split("-")[1], second.split("-")[1]);
  assert.equal(readFileSync(join(dir, "agent-id"), "utf8").trim(), first.split("-")[1]);
  assert.ok(!first.toLowerCase().includes(hostname().toLowerCase().split(".")[0]) || hostname().length < 3);
});

test("explicit IBACALAO_AGENT_ID wins", () => {
  assert.equal(resolveAgentId("worker", { IBACALAO_AGENT_ID: "mine" }, "/nonexistent"), "mine");
});
