import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";
import type { AdaptiveDomRepairInput, AdaptiveDomRepairResult } from "./repair";

const DEFAULT_TIMEOUT_MS = 12_000;
const MAX_TIMEOUT_MS = 15_000;
const MAX_INPUT_BYTES = 2 * 1024 * 1024;
const MAX_OUTPUT_BYTES = 1024 * 1024;

export type ScraplingSidecarOptions = {
  helper?: string;
  python?: string;
  script?: string;
  timeoutMs?: number;
};

export type ScraplingSignatureResult =
  | { ok: true; signature: Record<string, unknown> }
  | { ok: false; reason: "insufficient_evidence" | "parser_error" | "timeout" };

async function runSidecar<T extends { ok: boolean }>(
  payload: string,
  options: ScraplingSidecarOptions,
  invalid: T,
  timeout: T,
): Promise<T> {
  if (Buffer.byteLength(payload, "utf8") > MAX_INPUT_BYTES) return invalid;
  const helper = options.helper ?? process.env.IBACALAO_SCRAPLING_HELPER;
  const python = options.python ?? process.env.IBACALAO_SCRAPLING_PYTHON ?? "python3";
  const script = options.script
    ?? process.env.IBACALAO_SCRAPLING_SCRIPT
    ?? join(process.cwd(), "tools", "scrapling-repair", "scrapling_repair.py");
  const command = helper && existsSync(helper) ? helper : python;
  const args = helper && existsSync(helper) ? [] : [script];
  if (args.length > 0 && !existsSync(script)) return invalid;
  const timeoutMs = Math.max(1, Math.min(options.timeoutMs ?? DEFAULT_TIMEOUT_MS, MAX_TIMEOUT_MS));

  return await new Promise<T>((resolve) => {
    const child = spawn(command, args, { env: { ...process.env, PYTHONUNBUFFERED: "1" } });
    let stdout = Buffer.alloc(0);
    let settled = false;
    const finish = (result: T) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(result);
    };
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(timeout);
    }, timeoutMs);
    child.stdout.on("data", (chunk: Buffer) => {
      stdout = Buffer.concat([stdout, chunk]);
      if (stdout.byteLength > MAX_OUTPUT_BYTES) {
        child.kill("SIGKILL");
        finish(invalid);
      }
    });
    child.stderr.resume();
    child.on("error", () => finish(invalid));
    child.on("close", (code) => {
      if (settled) return;
      if (code !== 0 || stdout.byteLength === 0) return finish(invalid);
      try {
        const parsed = JSON.parse(stdout.toString("utf8")) as T;
        finish(parsed && typeof parsed === "object" && typeof parsed.ok === "boolean" ? parsed : invalid);
      } catch {
        finish(invalid);
      }
    });
    child.stdin.end(payload + "\n");
  });
}

export async function runScraplingRepair(
  input: AdaptiveDomRepairInput,
  options: ScraplingSidecarOptions = {},
): Promise<AdaptiveDomRepairResult> {
  if (!input.oldElementSignature) {
    return { ok: false, reason: "insufficient_evidence" };
  }

  const payload = JSON.stringify({
    operation: "repair",
    oldRecipe: input.oldRecipe,
    oldSignature: input.oldElementSignature,
    currentHtml: input.currentHtml,
    currentUrl: input.currentUrl,
    expectedEntity: input.expectedEntity,
  });
  return runSidecar<AdaptiveDomRepairResult>(
    payload,
    options,
    { ok: false, reason: "parser_error" },
    { ok: false, reason: "timeout" },
  );
}

export async function runScraplingSignature(
  input: { currentHtml: string; currentUrl: string; captureId: string },
  options: ScraplingSidecarOptions = {},
): Promise<ScraplingSignatureResult> {
  if (!input.currentHtml || !input.captureId) return { ok: false, reason: "insufficient_evidence" };
  return runSidecar<ScraplingSignatureResult>(
    JSON.stringify({ operation: "signature", ...input }),
    options,
    { ok: false, reason: "parser_error" },
    { ok: false, reason: "timeout" },
  );
}
