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
