import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { spawnSync } from "node:child_process";
import { setupWorker } from "../src/workerSetup";

test("pairs privately and registers the selected CLI without putting credentials in launchd", (t) => {
  const home = mkdtempSync(join(tmpdir(), "homework-setup-"));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const bundleDir = join(home, "app & bundle");
  const bin = join(home, "bin");
  mkdirSync(bundleDir); mkdirSync(bin);
  const nodePath = join(bin, "node");
  for (const path of [nodePath, join(bin, "codex")]) { writeFileSync(path, ""); chmodSync(path, 0o700); }
  for (const name of ["homework-pair.cjs", "homework-worker.cjs"]) writeFileSync(join(bundleDir, name), "");
  const code = "HWA-0123456789ABCDEF01234567";
  const calls: string[] = [];
  let newWorkerLoaded = false;
  let legacyWorkerLoaded = false;
  const result = setupWorker({
    home, bundleDir, nodePath, baseUrl: "https://example.test", code, preferredCli: "codex", path: bin, uid: 501,
    run: (command, args, options) => {
      calls.push(command);
      if (command === nodePath) {
        assert.equal(options.env?.IBACALAO_PAIR_CODE, code);
        assert.equal(options.env?.IBACALAO_AGENT_TOKEN, undefined);
        writeFileSync(join(options.cwd!, ".env"), "IBACALAO_AGENT_TOKEN=agt_synthetic\n", { mode: 0o600 });
      } else if (args[0] === "print") {
        return { status: args[1].endsWith("homework-agent") ? (newWorkerLoaded ? 0 : 1) : (legacyWorkerLoaded ? 0 : 1) };
      } else if (args[0] === "bootstrap") {
        assert.deepEqual(args.slice(0, 2), ["bootstrap", "gui/501"]);
        newWorkerLoaded = true;
      } else if (args[0] === "bootout") {
        legacyWorkerLoaded = false;
      } else if (args[0] === "kickstart") {
        newWorkerLoaded = true;
      }
      return { status: 0 };
    },
  });
  assert.equal(result.cli, "codex");
  assert.deepEqual(calls, [nodePath, "/bin/launchctl", "/bin/launchctl"]);
  const plist = readFileSync(join(home, "Library/LaunchAgents/com.ibacalao.homework-agent.plist"), "utf8");
  if (process.platform === "darwin") {
    const checked = spawnSync("/usr/bin/plutil", ["-lint", join(home, "Library/LaunchAgents/com.ibacalao.homework-agent.plist")]);
    assert.equal(checked.status, 0, checked.stderr.toString());
  }
  assert.ok(plist.includes("app &amp; bundle"));
  assert.ok(!plist.includes(code));
  assert.ok(!plist.includes("agt_synthetic"));
  assert.equal(statSync(join(home, ".ibacalao/homework-agent/.env")).mode & 0o777, 0o600);
  const runtimeRoot = join(home, "runtimes");
  const runtimeBin = join(runtimeRoot, "replacement", "node", "bin");
  mkdirSync(runtimeBin, { recursive: true });
  const replacementNode = join(runtimeBin, "node");
  writeFileSync(replacementNode, '#!/bin/sh\n[ -z "${IBACALAO_AGENT_TOKEN:-}" ] || exit 31\n[ -z "${IBACALAO_BASE_URL:-}" ] || exit 32\nprintf "%s" "$1" > "$FAKE_LAUNCH_RESULT"\n');
  chmodSync(replacementNode, 0o700);
  const launchResult = join(home, "launched");
  const launched = spawnSync("/bin/sh", [join(home, ".ibacalao/homework-agent/start-worker.sh")], { env: {
    IBACALAO_BUNDLED_NODE: join(home, "missing-one"),
    IBACALAO_NODE_FALLBACK: join(home, "missing-two"),
    IBACALAO_RUNTIME_ROOT: runtimeRoot,
    IBACALAO_WORKER_SCRIPT: join(bundleDir, "homework-worker.cjs"),
    IBACALAO_AGENT_TOKEN: "agt_synthetic",
    IBACALAO_BASE_URL: "https://wrong.example",
    FAKE_LAUNCH_RESULT: launchResult,
  } });
  assert.equal(launched.status, 0);
  assert.equal(readFileSync(launchResult, "utf8"), join(bundleDir, "homework-worker.cjs"));
  const legacyPlist = join(home, "Library/LaunchAgents/com.ibacalao.homework-worker.plist");
  writeFileSync(legacyPlist, "legacy configuration remains on disk");
  legacyWorkerLoaded = true;
  calls.length = 0;
  const renewedCode = "HWA-111111111111111111111111";
  const renewed = setupWorker({
    home, bundleDir, nodePath, baseUrl: "https://example.test", code: renewedCode, preferredCli: "codex", path: bin, uid: 501,
    run: (command, args, options) => {
      calls.push(command);
      if (command === nodePath) {
        assert.equal(options.env?.IBACALAO_PAIR_CODE, renewedCode);
        writeFileSync(join(options.cwd!, ".env"), "IBACALAO_AGENT_TOKEN=agt_refreshed\n", { mode: 0o600 });
      } else if (args[0] === "print") {
        return { status: args[1].endsWith("homework-agent") ? (newWorkerLoaded ? 0 : 1) : (legacyWorkerLoaded ? 0 : 1) };
      } else if (args[0] === "bootout") {
        legacyWorkerLoaded = false;
      } else if (args[0] === "kickstart") {
        newWorkerLoaded = true;
      }
      return { status: 0 };
    },
  });
  assert.equal(renewed.cli, "codex");
  assert.deepEqual(calls, [nodePath, "/bin/launchctl", "/bin/launchctl", "/bin/launchctl", "/bin/launchctl"]);
  assert.equal(legacyWorkerLoaded, false);
  assert.equal(newWorkerLoaded, true);
  assert.ok(readFileSync(legacyPlist, "utf8").includes("legacy configuration"));
});

test("a rejected pairing does not register a background worker or expose server text", (t) => {
  const home = mkdtempSync(join(tmpdir(), "homework-setup-fail-"));
  t.after(() => rmSync(home, { recursive: true, force: true }));
  const bundleDir = join(home, "bundle");
  const bin = join(home, "bin");
  mkdirSync(bundleDir); mkdirSync(bin);
  const nodePath = join(bin, "node");
  for (const file of [nodePath, join(bin, "codex")]) { writeFileSync(file, ""); chmodSync(file, 0o700); }
  for (const name of ["homework-pair.cjs", "homework-worker.cjs"]) writeFileSync(join(bundleDir, name), "");
  let calls = 0;
  assert.throws(() => setupWorker({
    home, bundleDir, nodePath, baseUrl: "https://example.test", code: "HWA-0123456789ABCDEF01234567", path: bin, uid: 501,
    run: () => { calls += 1; return { status: 1, stderr: "HTTP 401 agt_synthetic_secret" }; },
  }), (error: Error) => /HTTP 401/.test(error.message) && !error.message.includes("agt_synthetic_secret"));
  assert.equal(calls, 1);
  assert.throws(() => readFileSync(join(home, "Library/LaunchAgents/com.ibacalao.homework-agent.plist")));
});
