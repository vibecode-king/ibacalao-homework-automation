import { chmod, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { dirname, resolve } from "node:path";
import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";
import { readBoundedModelResponse } from "./agentRunner";
import { normalizeAgentServiceBaseUrl } from "./network";

const ENV_PATH = resolve(process.cwd(), ".env");
const DEFAULT_BASE_URL = "https://app.ibacalao.com";

function envValue(contents: string, name: string): string | null {
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`^\\s*${escapedName}\\s*=\\s*(.*)$`);
  const match = contents.split(/\r?\n/).map((line) => line.replace(/^\uFEFF/, "").match(pattern)).find(Boolean);
  if (!match) return null;
  const value = match[1].trim();
  if (value.length >= 2 && ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))) {
    return value.slice(1, -1);
  }
  return value;
}

async function readEnvFile(): Promise<string> {
  try {
    return await readFile(ENV_PATH, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return "";
    throw error;
  }
}

function withEnvValue(contents: string, name: string, value: string): string {
  const lines = contents.split(/(?<=\n)/);
  const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`^\\s*${escapedName}\\s*=`);
  let found = false;
  const updated = lines.map((line) => {
    if (!pattern.test(line)) return line;
    found = true;
    const newline = line.endsWith("\r\n") ? "\r\n" : line.endsWith("\n") ? "\n" : "";
    return `${name}=${value}${newline}`;
  }).join("");
  if (found) return updated;
  const separator = contents.length === 0 || contents.endsWith("\n") ? "" : "\n";
  return `${contents}${separator}${name}=${value}\n`;
}

async function savePairing(baseUrl: string, token: string): Promise<void> {
  const current = await readEnvFile();
  const updated = withEnvValue(
    withEnvValue(current, "IBACALAO_BASE_URL", baseUrl),
    "IBACALAO_AGENT_TOKEN",
    token,
  );
  const temporaryPath = resolve(dirname(ENV_PATH), `.env.${randomUUID()}.tmp`);
  try {
    await writeFile(temporaryPath, updated, { flag: "wx", mode: 0o600 });
    await chmod(temporaryPath, 0o600);
    await rename(temporaryPath, ENV_PATH);
    await chmod(ENV_PATH, 0o600);
  } catch (error) {
    await unlink(temporaryPath).catch(() => undefined);
    throw error;
  }
}

async function main(): Promise<void> {
  const existingEnv = await readEnvFile();
  const baseDefault = process.env.IBACALAO_BASE_URL?.trim()
    || envValue(existingEnv, "IBACALAO_BASE_URL")
    || DEFAULT_BASE_URL;
  // Non-interactive path for an AI assistant: the one-time code (10 minutes, single use)
  // may come from the environment. The long-lived token is never accepted or printed here.
  const envUrl = process.env.IBACALAO_PAIR_URL?.trim();
  const envCode = process.env.IBACALAO_PAIR_CODE?.trim();
  let baseUrl: string;
  let code: string;
  if (envCode) {
    baseUrl = normalizeAgentServiceBaseUrl(envUrl || baseDefault);
    code = envCode;
  } else {
    const terminal = createInterface({ input: stdin, output: stdout });
    try {
      const enteredBaseUrl = await terminal.question(`iBacalao server URL [${baseDefault}]: `);
      baseUrl = normalizeAgentServiceBaseUrl(enteredBaseUrl.trim() || baseDefault);
      code = (await terminal.question("One-time pairing code: ")).trim();
    } finally {
      terminal.close();
    }
  }

  if (!/^HWA-[A-F0-9]{24}$/i.test(code)) {
    throw new Error("The pairing code format is invalid. Create a new code in Homework Overview and try again.");
  }

  let response: Response;
  try {
    response = await fetch(`${baseUrl}/api/agent/token/exchange`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ code }),
      signal: AbortSignal.timeout(30_000),
      redirect: "error",
    });
  } catch {
    throw new Error(`Could not reach ${baseUrl}. Check the server URL and network connection.`);
  }

  const responseText = await readBoundedModelResponse(response, 64 * 1024);
  type PairingResponse = { token?: unknown; error?: unknown };
  let payload: PairingResponse | null = null;
  try { payload = JSON.parse(responseText) as PairingResponse; } catch { /* handled below */ }
  if (!response.ok) {
    const detail = typeof payload?.error === "string"
      ? payload.error.replace(/agt_[A-Za-z0-9_-]+/g, "[redacted]").slice(0, 180)
      : `HTTP ${response.status}`;
    throw new Error(`iBacalao pairing failed (HTTP ${response.status}): ${detail}`);
  }
  if (typeof payload?.token !== "string" || !/^agt_[A-Za-z0-9_-]{43}$/.test(payload.token)) {
    throw new Error("The server returned an invalid agent credential. Create a new pairing code and try again.");
  }

  try {
    await savePairing(baseUrl, payload.token);
  } catch {
    throw new Error("The token was issued but could not be saved to .env. Fix the file permissions, create a new pairing code, and retry.");
  }
  console.log("Agent paired. The token and server URL were saved to .env with owner-only permissions.");
  console.log("Reload .env in your shell before starting the worker. The token was not printed.");
}

main().catch((error) => {
  console.error(`[homework-agent] pairing stopped: ${error instanceof Error ? error.message : "Unknown error."}`);
  process.exitCode = 1;
});
