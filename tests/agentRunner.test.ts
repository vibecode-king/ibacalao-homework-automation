import { test } from "node:test";
import assert from "node:assert/strict";
import { parseAssignmentAgentResult } from "../src/agentRunner";

test("accepts bounded plain text and Markdown model results", () => {
  const result = parseAssignmentAgentResult('{"artifactText":"# Draft\\n\\nResponse"}', { engine: "test", model: "test-model" });
  assert.equal(result.artifactText, "# Draft\n\nResponse");
  assert.equal(result.engine, "test");
});

test("rejects HTML output and UTF-8 output over the cap", () => {
  assert.throws(() => parseAssignmentAgentResult('{"artifactText":"<p>Draft</p>"}', { engine: "test", model: "test-model" }), /not HTML/);
  const oversized = JSON.stringify({ artifactText: "🧪".repeat(130_000) });
  assert.throws(() => parseAssignmentAgentResult(oversized, { engine: "test", model: "test-model" }), /500 KB/);
});

test("engine and model come from config, not model output; qaResult is marked self-reported", () => {
  const result = parseAssignmentAgentResult(
    '{"artifactText":"Draft","engine":"fake-engine","model":"fake-model","qaResult":{"passed":true}}',
    { engine: "openai-compatible", model: "real-model" },
  );
  assert.equal(result.engine, "openai-compatible");
  assert.equal(result.model, "real-model");
  assert.deepEqual(result.qaResult, { selfReported: true, result: { passed: true } });
});

test("accepts a draft that quotes HTML tags", () => {
  const result = parseAssignmentAgentResult('{"artifactText":"Use <table> for data."}', { engine: "test", model: "m" });
  assert.match(result.artifactText, /<table>/);
});
