import { normalizeAgentServiceBaseUrl } from "./network";

export type AssignmentAgentResult = {
  artifactHtml: string;
  engine: string;
  model: string;
  qaResult?: unknown;
};

const DEFAULT_TIMEOUT_MS = 12 * 60 * 1000;
const MAX_MODEL_RESPONSE_BYTES = 1_500_000;

function parseJsonOutput(raw: string): unknown {
  const trimmed = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
  try { return JSON.parse(trimmed); } catch { /* some CLIs print a short status line before the result */ }
  const first = trimmed.indexOf("{");
  const last = trimmed.lastIndexOf("}");
  if (first >= 0 && last > first) return JSON.parse(trimmed.slice(first, last + 1));
  throw new Error("The configured agent did not return a JSON result.");
}

export function parseAssignmentAgentResult(raw: string, defaults: { engine: string; model: string }): AssignmentAgentResult {
  const parsed = parseJsonOutput(raw);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("The configured agent result must be a JSON object.");
  const value = parsed as Record<string, unknown>;
  if (typeof value.artifactHtml !== "string" || !value.artifactHtml.trim()) {
    throw new Error("The configured agent result must include non-empty artifactHtml.");
  }
  if (value.artifactHtml.length > 500_000) throw new Error("The generated document exceeds the 500 KB limit.");
  return {
    artifactHtml: value.artifactHtml,
    engine: typeof value.engine === "string" ? value.engine.slice(0, 120) : defaults.engine,
    model: typeof value.model === "string" ? value.model.slice(0, 160) : defaults.model,
    ...(value.qaResult && typeof value.qaResult === "object" ? { qaResult: value.qaResult } : {}),
  };
}

async function runOpenAiCompatible(prompt: string): Promise<AssignmentAgentResult> {
  const configuredBaseUrl = (process.env.IBACALAO_LLM_BASE_URL || (process.env.IBACALAO_LLM_API_KEY ? "https://api.openai.com/v1" : "")).trim();
  if (!configuredBaseUrl) {
    throw new Error("Configure IBACALAO_LLM_BASE_URL for a BYOK or self-hosted model endpoint, and optionally set IBACALAO_LLM_API_KEY.");
  }
  const baseUrl = normalizeAgentServiceBaseUrl(configuredBaseUrl);
  const model = (process.env.IBACALAO_LLM_MODEL || "gpt-4o-mini").trim();
  const endpoint = `${baseUrl.replace(/\/+$/, "")}/chat/completions`;
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (process.env.IBACALAO_LLM_API_KEY) headers.authorization = `Bearer ${process.env.IBACALAO_LLM_API_KEY}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS);
  try {
    const requestBody = {
      model,
      temperature: 0.2,
      // Caps spend per job on the student's own key; override with IBACALAO_LLM_MAX_TOKENS (1-32000).
      max_tokens: Math.min(32_000, Math.max(1, Math.round(Number(process.env.IBACALAO_LLM_MAX_TOKENS) || 8_000))),
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: "Return exactly one JSON object with artifactHtml, engine, model, and optional qaResult. Do not wrap it in Markdown." },
        { role: "user", content: prompt },
      ],
    };
    let response = await fetch(endpoint, {
      method: "POST",
      headers,
      signal: controller.signal,
      redirect: "error",
      body: JSON.stringify(requestBody),
    });
    let responseText = await readBoundedModelResponse(response);
    if (!response.ok && response.status === 400 && /response_format|json_object|unsupported parameter/i.test(responseText)) {
      const { response_format: _responseFormat, ...compatibleBody } = requestBody;
      response = await fetch(endpoint, {
        method: "POST",
        headers,
        signal: controller.signal,
        redirect: "error",
        body: JSON.stringify(compatibleBody),
      });
      responseText = await readBoundedModelResponse(response);
    }
    if (!response.ok) throw new Error(`The configured model endpoint returned HTTP ${response.status}.`);
    let payload: { choices?: Array<{ message?: { content?: unknown } }>; model?: string };
    try { payload = JSON.parse(responseText) as typeof payload; }
    catch { throw new Error("The configured model endpoint returned invalid JSON."); }
    const content = payload.choices?.[0]?.message?.content;
    if (typeof content !== "string") throw new Error("The configured model endpoint returned no text result.");
    return parseAssignmentAgentResult(content, { engine: "openai-compatible", model: payload.model ?? model });
  } catch (error) {
    if (controller.signal.aborted) throw new Error("The configured model request timed out.");
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export async function readBoundedModelResponse(response: Response, maxBytes = MAX_MODEL_RESPONSE_BYTES): Promise<string> {
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    await response.body?.cancel().catch(() => undefined);
    throw new Error("The upstream response exceeded the size limit.");
  }
  if (!response.body) return "";
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let bytes = 0;
  let text = "";
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > maxBytes) {
        await reader.cancel().catch(() => undefined);
        throw new Error("The upstream response exceeded the size limit.");
      }
      text += decoder.decode(value, { stream: true });
    }
    return text + decoder.decode();
  } finally {
    reader.releaseLock();
  }
}

/** Send the prompt only to the explicitly configured OpenAI-compatible endpoint. */
export async function runConfiguredAssignmentAgent(prompt: string): Promise<AssignmentAgentResult> {
  if (process.env.IBACALAO_AGENT_COMMAND?.trim()) {
    throw new Error("IBACALAO_AGENT_COMMAND is disabled because local CLI execution is not sandboxed. Unset it and configure IBACALAO_LLM_BASE_URL instead.");
  }
  return runOpenAiCompatible(prompt);
}
