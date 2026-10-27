import { setTimeout as sleep } from "node:timers/promises";
import { readBoundedModelResponse } from "./agentRunner";

const MAX_AGENT_API_RESPONSE_BYTES = 2 * 1024 * 1024;
const DOCX_MIME_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

export function createAgentApiClient(baseUrl: string, token: string | undefined) {
  async function request<T>(path: string, body?: unknown): Promise<T> {
    if (!token) throw new Error("Set IBACALAO_AGENT_TOKEN in this terminal before starting the homework agent.");
    let response: Response;
    try {
      response = await fetch(`${baseUrl}${path}`, {
        method: body === undefined ? "GET" : "POST",
        headers: {
          authorization: `Bearer ${token}`,
          ...(body === undefined ? {} : { "content-type": "application/json" }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(30_000),
        redirect: "error",
      });
    } catch {
      throw new Error(`Could not reach ${baseUrl}. Check the server URL and network connection.`);
    }
    const responseText = await readBoundedModelResponse(response, MAX_AGENT_API_RESPONSE_BYTES);
    const payload = (() => {
      try { return JSON.parse(responseText) as Record<string, unknown>; }
      catch { return null; }
    })();
    if (!response.ok) {
      const message = typeof payload?.error === "string" ? payload.error : `HTTP ${response.status}`;
      throw new Error(`iBacalao agent API returned ${response.status}: ${message}`);
    }
    return payload as T;
  }

  function isRetryableCompletionError(error: unknown): boolean {
    const message = error instanceof Error ? error.message : String(error);
    return /iBacalao agent API returned 5\d\d:/.test(message) || /Could not reach /.test(message);
  }

  async function submitCompletion<T>(path: string, document: Uint8Array, metadata: Record<string, unknown>): Promise<T> {
    for (let attempt = 0; ; attempt += 1) {
      try {
        const form = new FormData();
        form.set("document", new Blob([new Uint8Array(document)], { type: DOCX_MIME_TYPE }), "draft.docx");
        form.set("metadata", JSON.stringify(metadata));
        let response: Response;
        try {
          response = await fetch(baseUrl + path, {
            method: "POST",
            headers: { authorization: "Bearer " + token },
            body: form,
            signal: AbortSignal.timeout(30_000),
            redirect: "error",
          });
        } catch {
          throw new Error("Could not reach " + baseUrl + ". Check the server URL and network connection.");
        }
        const responseText = await readBoundedModelResponse(response, MAX_AGENT_API_RESPONSE_BYTES);
        const payload = (() => {
          try { return JSON.parse(responseText) as Record<string, unknown>; } catch { return null; }
        })();
        if (!response.ok) {
          const message = typeof payload?.error === "string" ? payload.error : "HTTP " + response.status;
          throw new Error("iBacalao agent API returned " + response.status + ": " + message);
        }
        return payload as T;
      } catch (error) {
        if (!isRetryableCompletionError(error) || attempt >= 2) throw error;
        await sleep(attempt === 0 ? 250 : 750);
      }
    }
  }

  return { request, submitCompletion };
}
