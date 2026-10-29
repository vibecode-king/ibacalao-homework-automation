import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const ID_PATTERN = /^[a-f0-9]{16,64}$/;

/**
 * Stable random id for this install. The hostname often contains the student's
 * name, so it is never sent to the server.
 */
export function resolveAgentId(kind: "worker" | "mcp", env: NodeJS.ProcessEnv = process.env, dir = join(homedir(), ".ibacalao-homework")): string {
  const configured = env.IBACALAO_AGENT_ID?.trim();
  if (configured) return configured.slice(0, 120);
  const file = join(dir, "agent-id");
  let installId = "";
  try {
    if (existsSync(file)) installId = readFileSync(file, "utf8").trim();
    if (!ID_PATTERN.test(installId)) {
      installId = randomBytes(8).toString("hex");
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      writeFileSync(file, `${installId}\n`, { mode: 0o600 });
      chmodSync(file, 0o600);
    }
  } catch {
    // A read-only home still gets a working, per-process random id.
    if (!ID_PATTERN.test(installId)) installId = randomBytes(8).toString("hex");
  }
  return `${kind}-${installId}-${process.pid}`;
}
