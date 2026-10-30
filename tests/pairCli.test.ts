import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createRequire } from "node:module";
import { test } from "node:test";

test("pairing reports HTTP failure without exposing token-shaped server text", async (t) => {
  const dir = mkdtempSync(join(tmpdir(), "homework-pair-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const server = createServer((_req, res) => {
    res.writeHead(401, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "failure agt_synthetic_secret" }));
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => server.close());
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  const loader = createRequire(import.meta.url).resolve("tsx");
  const child = spawn(process.execPath, ["--import", loader, resolve("src/pair.ts")], {
    cwd: dir,
    env: { ...process.env, IBACALAO_PAIR_URL: `http://127.0.0.1:${address.port}`, IBACALAO_PAIR_CODE: "HWA-0123456789ABCDEF01234567", IBACALAO_AGENT_TOKEN: "" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk; });
  child.stderr.on("data", (chunk) => { output += chunk; });
  const [status] = await once(child, "close");
  assert.equal(status, 1);
  assert.match(output, /HTTP 401/);
  assert.doesNotMatch(output, /agt_synthetic_secret/);
});
