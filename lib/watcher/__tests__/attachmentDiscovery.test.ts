import assert from "node:assert/strict";
import { test } from "node:test";
import {
  discoverAndExtractSchoolAttachments,
  resolveAttachmentSignals,
} from "../attachmentDiscovery";
import type { WatcherPage } from "../types";

const ORIGIN = "https://school.example";

type Signal = {
  name: string;
  attributes: Record<string, string>;
  interactionKey: string;
  safeToFetch: boolean;
  safeToInteract: boolean;
};

function basePage(evaluateResult: Signal[]): WatcherPage {
  return {
    async goto() {},
    url: () => `${ORIGIN}/detail/1`,
    async content() { return "<html><body>detail</body></html>"; },
    async title() { return "Detail"; },
    async evaluate<T>(_fn: unknown) {
      if (typeof _fn === "string" && _fn.includes("const revealWords")) return 0 as T;
      if (typeof _fn === "string" && _fn.includes("const selector =")) return evaluateResult as T;
      if (typeof _fn === "string" && _fn.includes("data-ibacalao-attachment-key")) return true as T;
      return undefined as T;
    },
  };
}

test("resolves href/data URL/onclick and platform-specific opaque attributes", () => {
  const signals: Signal[] = [
    {
      name: "rubric.pdf",
      attributes: { href: "/files/rubric.pdf" },
      interactionKey: "a",
      safeToFetch: true,
      safeToInteract: true,
    },
    {
      name: "instructions.docx",
      attributes: { "data-url": "/api/files/42" },
      interactionKey: "b",
      safeToFetch: true,
      safeToInteract: true,
    },
    {
      name: "slides.pptx",
      attributes: { attlink: "abc123.pptx" },
      interactionKey: "c",
      safeToFetch: true,
      safeToInteract: true,
    },
    {
      name: "notes.txt",
      attributes: { onclick: "downloadFile('/download/notes/7')" },
      interactionKey: "d",
      safeToFetch: true,
      safeToInteract: true,
    },
  ];

  const resolved = resolveAttachmentSignals(signals, ORIGIN, {
    attributeResolvers: [{
      attribute: "attlink",
      resolve: (value) => `/opaque/${encodeURIComponent(value)}`,
    }],
  });

  assert.deepEqual(resolved.map((item) => new URL(item.href).pathname), [
    "/files/rubric.pdf",
    "/api/files/42",
    "/opaque/abc123.pptx",
    "/download/notes/7",
  ]);
});

test("generic discovery refuses cross-origin URLs unless explicitly trusted", () => {
  const signal: Signal = {
    name: "rubric.pdf",
    attributes: { href: "https://cdn.example/rubric.pdf" },
    interactionKey: "a",
    safeToFetch: true,
    safeToInteract: true,
  };
  assert.equal(resolveAttachmentSignals([signal], ORIGIN).length, 0);
  assert.equal(resolveAttachmentSignals([signal], ORIGIN, { trustedDownloadOrigins: ["https://cdn.example"] }).length, 1);
});

test("mutation-like URLs are never fetched even if the scanner mislabeled the control as safe", () => {
  const signal: Signal = {
    name: "rubric.pdf",
    attributes: { href: "/modules/message/pDeleteMessage/42" },
    interactionKey: "danger",
    safeToFetch: true,
    safeToInteract: true,
  };
  assert.deepEqual(resolveAttachmentSignals([signal], ORIGIN), []);
});

test("data-url attachment is fetched with authenticated request and parsed", async () => {
  const signal: Signal = {
    name: "lab instructions.txt",
    attributes: { "data-url": "/api/attachment/42" },
    interactionKey: "direct",
    safeToFetch: true,
    safeToInteract: true,
  };
  const requested: string[] = [];
  const page: WatcherPage = {
    ...basePage([signal]),
    request: {
      async get(url: string) {
        requested.push(url);
        return {
          ok: () => true,
          status: () => 200,
          url: () => url,
          headers: () => ({
            "content-type": "text/plain",
            "content-disposition": 'attachment; filename="lab-instructions.txt"',
          }),
          body: async () => new TextEncoder().encode("Complete the observation table and write one conclusion."),
        };
      },
    },
  };

  const result = await discoverAndExtractSchoolAttachments(page, ORIGIN, {
    enableRevealInteractions: false,
    enableDownloadInteractions: false,
  });
  assert.equal(result.extracted, 1);
  assert.deepEqual(requested, [`${ORIGIN}/api/attachment/42`]);
  assert.match(result.text, /Attachment: lab-instructions\.txt/);
  assert.match(result.text, /observation table/);
  assert.ok(result.methods.includes("dom:data-url"));
});

test("safe unresolved download control falls back to a real Playwright download event", async () => {
  const signal: Signal = {
    name: "teacher-notes.txt",
    attributes: { "data-file": "opaque-token" },
    interactionKey: "fallback",
    safeToFetch: true,
    safeToInteract: true,
  };
  let clicked = 0;
  const base = basePage([signal]);
  const page = {
    ...base,
    async evaluate<T>(_fn: unknown) {
      if (typeof _fn === "string" && _fn.includes("const revealWords")) return 0 as T;
      if (typeof _fn === "string" && _fn.includes("const selector =")) return [signal] as T;
      if (typeof _fn === "string" && _fn.includes("data-ibacalao-attachment-key")) {
        clicked += 1;
        return true as T;
      }
      return undefined as T;
    },
    async waitForEvent(event: "download" | "popup") {
      if (event === "popup") return await new Promise<never>(() => {});
      return {
        suggestedFilename: () => "teacher-notes.txt",
        async createReadStream() {
          return (async function* () {
            yield Buffer.from("Bring the printed worksheet and complete questions 1 through 5.");
          })();
        },
        async delete() {},
      };
    },
  } as WatcherPage & {
    waitForEvent(event: "download" | "popup", options?: { timeout?: number }): Promise<unknown>;
  };

  const result = await discoverAndExtractSchoolAttachments(page, ORIGIN, {
    enableRevealInteractions: false,
    enableDownloadInteractions: true,
    interactionTimeoutMs: 500,
  });
  assert.equal(clicked, 1);
  assert.equal(result.extracted, 1);
  assert.match(result.text, /questions 1 through 5/);
  assert.ok(result.methods.includes("interaction:download"));
});

test("safe unresolved control can fall back to an attachment network response", async () => {
  const signal: Signal = {
    name: "assignment-rubric.pdf",
    attributes: { "data-file": "opaque-rubric-token" },
    interactionKey: "response-fallback",
    safeToFetch: true,
    safeToInteract: true,
  };
  const base = basePage([signal]);
  const response = {
    ok: () => true,
    status: () => 200,
    url: () => `${ORIGIN}/api/files/rubric.txt`,
    headers: () => ({
      "content-type": "text/plain",
      "content-disposition": 'attachment; filename="rubric.txt"',
    }),
    body: async () => new TextEncoder().encode("Criterion A: include two pieces of evidence."),
  };
  const page = {
    ...base,
    async waitForResponse(predicate: (candidate: typeof response) => boolean) {
      assert.equal(predicate(response), true);
      return response;
    },
  } as WatcherPage & { waitForResponse(predicate: (candidate: typeof response) => boolean): Promise<typeof response> };

  const result = await discoverAndExtractSchoolAttachments(page, ORIGIN, {
    enableRevealInteractions: false,
    enableDownloadInteractions: true,
    interactionTimeoutMs: 500,
  });
  assert.equal(result.extracted, 1);
  assert.match(result.text, /Criterion A/);
  assert.ok(result.methods.includes("interaction:response"));
});

test("safe unresolved control can fall back to a same-origin popup file", async () => {
  const signal: Signal = {
    name: "teacher-notes.txt",
    attributes: { "data-file": "opaque-popup-token" },
    interactionKey: "popup-fallback",
    safeToFetch: true,
    safeToInteract: true,
  };
  const base = basePage([signal]);
  const fileUrl = `${ORIGIN}/files/teacher-notes.txt`;
  const page = {
    ...base,
    async waitForEvent(event: "download" | "popup") {
      if (event === "download") return await new Promise<never>(() => {});
      return {
        url: () => fileUrl,
        async waitForLoadState() {},
        async close() {},
      };
    },
    request: {
      async get(url: string) {
        assert.equal(url, fileUrl);
        return {
          ok: () => true,
          status: () => 200,
          url: () => fileUrl,
          headers: () => ({ "content-type": "text/plain" }),
          body: async () => new TextEncoder().encode("Bring your calculator and graph paper tomorrow."),
        };
      },
    },
  } as WatcherPage & { waitForEvent(event: "download" | "popup", options?: { timeout?: number }): Promise<unknown> };

  const result = await discoverAndExtractSchoolAttachments(page, ORIGIN, {
    enableRevealInteractions: false,
    enableDownloadInteractions: true,
    interactionTimeoutMs: 500,
  });
  assert.equal(result.extracted, 1);
  assert.match(result.text, /graph paper tomorrow/);
  assert.ok(result.methods.includes("interaction:popup"));
});

test("unsafe unresolved controls never receive an interaction", async () => {
  const signal: Signal = {
    name: "rubric.pdf",
    attributes: { "data-file": "rubric-token" },
    interactionKey: "delete",
    safeToFetch: false,
    safeToInteract: false,
  };
  let clicked = 0;
  const base = basePage([signal]);
  const page = {
    ...base,
    async evaluate<T>(_fn: unknown) {
      if (typeof _fn === "string" && _fn.includes("const revealWords")) return 0 as T;
      if (typeof _fn === "string" && _fn.includes("const selector =")) return [signal] as T;
      if (typeof _fn === "string" && _fn.includes("data-ibacalao-attachment-key")) {
        clicked += 1;
        return true as T;
      }
      return undefined as T;
    },
    async waitForEvent() {
      throw new Error("must not wait for an event on an unsafe control");
    },
  } as WatcherPage & { waitForEvent(): Promise<unknown> };

  const result = await discoverAndExtractSchoolAttachments(page, ORIGIN, {
    enableRevealInteractions: false,
    enableDownloadInteractions: true,
    interactionTimeoutMs: 500,
  });
  assert.equal(clicked, 0);
  assert.equal(result.extracted, 0);
  assert.equal(result.interacted, 0);
});
