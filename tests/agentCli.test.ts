import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { runConfiguredAssignmentAgent } from "../src/agentRunner";

test("Codex receives the selected model and no worker credential", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "homework-cli-"));
  const original = { ...process.env };
  t.after(() => { process.env = original; rmSync(dir, { recursive: true, force: true }); });
  const executable = join(dir, "codex");
  writeFileSync(executable, `#!/bin/sh\nif [ -n "\${IBACALAO_AGENT_TOKEN:-}" ]; then exit 31; fi\nprintf '%s\\n' "$@" > "$FAKE_CLI_ARGS"\nout=''\nwhile [ "$#" -gt 0 ]; do if [ "$1" = '-o' ]; then shift; out="$1"; fi; shift; done\n/bin/cat >/dev/null\nprintf '%s' '{"artifactText":"Synthetic draft"}' > "$out"\n`);
  chmodSync(executable, 0o700);
  process.env.PATH = `${dir}:/usr/bin:/bin`;
  process.env.IBACALAO_AGENT_CLI = "codex";
  process.env.IBACALAO_AGENT_TOKEN = "agt_synthetic_test";
  process.env.FAKE_CLI_ARGS = join(dir, "args");
  const result = await runConfiguredAssignmentAgent("Synthetic assignment", "chosen-model");
  const args = readFileSync(join(dir, "args"), "utf8").split("\n");
  assert.equal(result.artifactText, "Synthetic draft");
  assert.equal(args[args.indexOf("-m") + 1], "chosen-model");
});

test("Claude receives the selected model and no worker credential", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "homework-claude-"));
  const original = { ...process.env };
  t.after(() => { process.env = original; rmSync(dir, { recursive: true, force: true }); });
  const executable = join(dir, "claude");
  writeFileSync(executable, `#!/bin/sh\nif [ -n "\${IBACALAO_AGENT_TOKEN:-}" ]; then exit 31; fi\nprintf '%s\\n' "$@" > "$FAKE_CLI_ARGS"\n/bin/cat >/dev/null\nprintf '%s' '{"artifactText":"Synthetic Claude draft"}'\n`);
  chmodSync(executable, 0o700);
  process.env.PATH = `${dir}:/usr/bin:/bin`;
  process.env.IBACALAO_AGENT_CLI = "claude";
  process.env.IBACALAO_AGENT_TOKEN = "agt_synthetic_test";
  process.env.FAKE_CLI_ARGS = join(dir, "args");
  const result = await runConfiguredAssignmentAgent("Synthetic assignment", "chosen-claude-model");
  const args = readFileSync(join(dir, "args"), "utf8").split("\n");
  assert.equal(result.artifactText, "Synthetic Claude draft");
  assert.equal(args[args.indexOf("--model") + 1], "chosen-claude-model");
});
