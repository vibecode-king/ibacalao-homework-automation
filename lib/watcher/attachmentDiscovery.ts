import { extractSchoolAttachmentBytes } from "../school/attachments";
import { mergeContentIntegrity, type ContentIntegritySummary } from "../security/contentIntegrity";
import type { WatcherPage } from "./types";

const DEFAULT_MAX_FILE_BYTES = 25 * 1024 * 1024;
const DEFAULT_MAX_TEXT_CHARS = 12_000;
const DEFAULT_MAX_TOTAL_TEXT_CHARS = 24_000;
const DEFAULT_MAX_CANDIDATES = 12;
const DEFAULT_MAX_REVEALS = 2;
const DEFAULT_MAX_DOWNLOAD_INTERACTIONS = 3;

const FILE_EXTENSION = /\.(?:pdf|docx?|pptx?|xlsx?|txt|md|csv|rtf|zip|rar|png|jpe?g)(?:[?#].*)?$/i;
const DOWNLOAD_WORDS = /\b(download|descargar|attachment|adjunto|archivo|file|documento|resource|recurso)\b/i;
const MUTATION_URL_WORDS = /delete|remove|destroy|submit|save|upload|send|reply|edit|turnin|handin|borrar|eliminar|guardar|enviar|entregar/i;

const DIRECT_URL_ATTRIBUTES = [
  "href",
  "data-href",
  "data-url",
  "data-download-url",
  "data-file-url",
  "data-path",
  "data-src",
  "src",
  "formaction",
] as const;

const CUSTOM_VALUE_ATTRIBUTES = [
  "attlink",
  "data-file",
  "data-filename",
  "data-attachment",
  "data-download",
] as const;

export type SchoolAttachmentLink = {
  href: string;
  name: string;
  method?: string;
};

export type SchoolAttachmentAttributeResolver = {
  attribute: string;
  resolve(value: string, context: { name: string; origin: string }): string | null;
};

export type SchoolAttachmentDiscoveryOptions = {
  rootSelector?: string;
  seedLinks?: SchoolAttachmentLink[];
  attributeResolvers?: SchoolAttachmentAttributeResolver[];
  trustedDownloadOrigins?: string[];
  enableRevealInteractions?: boolean;
  enableDownloadInteractions?: boolean;
  maxCandidates?: number;
  maxRevealInteractions?: number;
  maxDownloadInteractions?: number;
  maxFileBytes?: number;
  maxTextCharsPerFile?: number;
  maxTotalTextChars?: number;
  interactionTimeoutMs?: number;
  /** Receives every fetched file's original bytes (e.g. to keep the teacher's
   *  doc on disk). Errors are swallowed: keeping a copy must never break a crawl. */
  onFile?: (name: string, bytes: Uint8Array) => void;
};

export type SchoolAttachmentDiscoveryResult = {
  text: string;
  extracted: number;
  discovered: number;
  interacted: number;
  names: string[];
  methods: string[];
  contentIntegrity?: ContentIntegritySummary;
};

type RawAttachmentSignal = {
  name: string;
  attributes: Record<string, string>;
  interactionKey: string;
  safeToFetch: boolean;
  safeToInteract: boolean;
};

type ResponseLike = {
  ok(): boolean;
  status(): number;
  url(): string;
  headers(): Record<string, string>;
  body(): Promise<Uint8Array>;
};

type DownloadLike = {
  suggestedFilename(): string;
  createReadStream(): Promise<AsyncIterable<Uint8Array | Buffer | string> | null>;
  delete?(): Promise<void>;
  cancel?(): Promise<void>;
};

type PopupLike = {
  url(): string;
  waitForLoadState?(state?: "load" | "domcontentloaded", options?: { timeout?: number }): Promise<unknown>;
  close?(): Promise<void>;
};

type InteractiveWatcherPage = WatcherPage & {
  waitForEvent?: (
    event: "download" | "popup",
    options?: { timeout?: number },
  ) => Promise<DownloadLike | PopupLike>;
  waitForResponse?: (
    predicate: (response: ResponseLike) => boolean,
    options?: { timeout?: number },
  ) => Promise<ResponseLike>;
};

function normalizeName(value: string): string {
  return value.replace(/[\u0000-\u001f\u007f]/g, "").replace(/\s+/g, " ").trim().slice(0, 240) || "attachment";
}

function contentDispositionFileName(value: string | undefined): string | null {
  if (!value) return null;
  const encoded = value.match(/filename\*\s*=\s*UTF-8''([^;]+)/i)?.[1];
  if (encoded) {
    try {
      return normalizeName(decodeURIComponent(encoded.replace(/^"|"$/g, "")));
    } catch {
      // Fall through to ordinary filename= parsing.
    }
  }
  const plain = value.match(/filename\s*=\s*"([^"]+)"/i)?.[1]
    ?? value.match(/filename\s*=\s*([^;]+)/i)?.[1];
  return plain ? normalizeName(plain.replace(/^"|"$/g, "")) : null;
}

function pathLeaf(value: string): string {
  try {
    return normalizeName(decodeURIComponent(value.replace(/\\/g, "/").split("/").filter(Boolean).at(-1) ?? value));
  } catch {
    return normalizeName(value.replace(/\\/g, "/").split("/").filter(Boolean).at(-1) ?? value);
  }
}

function inferredFileName(link: SchoolAttachmentLink, finalUrl: URL, headers: Record<string, string>): string {
  const disposition = contentDispositionFileName(headers["content-disposition"] ?? headers["Content-Disposition"]);
  if (disposition) return disposition;
  if (FILE_EXTENSION.test(link.name)) return normalizeName(link.name);
  const fromPath = pathLeaf(finalUrl.pathname);
  if (FILE_EXTENSION.test(fromPath)) return fromPath;
  const contentType = (headers["content-type"] ?? headers["Content-Type"] ?? "").toLowerCase();
  const extension = contentType.includes("application/pdf") ? ".pdf"
    : contentType.includes("wordprocessingml") ? ".docx"
      : contentType.includes("presentationml") ? ".pptx"
        : contentType.startsWith("text/plain") ? ".txt"
          : contentType.includes("text/csv") ? ".csv"
            : "";
  return `${normalizeName(link.name || fromPath || "attachment")}${extension}`.slice(0, 240);
}

function allowedOrigins(origin: string, trusted: string[] = []): Set<string> {
  const values = new Set<string>([new URL(origin).origin]);
  for (const value of trusted) {
    try {
      const parsed = new URL(value);
      if (parsed.protocol === "https:" || parsed.protocol === "http:") values.add(parsed.origin);
    } catch {
      // Ignore malformed configuration instead of broadening trust accidentally.
    }
  }
  return values;
}

function allowedAttachmentUrl(raw: string, origin: string, trusted: string[] = []): URL | null {
  if (!raw || raw === "#" || /^(?:javascript:|mailto:|data:|blob:)/i.test(raw)) return null;
  try {
    const url = new URL(raw, origin);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    if (!allowedOrigins(origin, trusted).has(url.origin)) return null;
    // Defense in depth: the browser scan already rejects controls whose label
    // looks mutating, but a platform can hide an icon-only destructive action
    // behind a URL such as /pDeleteMessage/42. Never turn that into a GET just
    // because nearby text happened to contain a filename.
    if (MUTATION_URL_WORDS.test(`${url.pathname}${url.search}`)) return null;
    return url;
  } catch {
    return null;
  }
}

function likelyAttachmentResponse(response: ResponseLike): boolean {
  try {
    const headers = response.headers();
    const disposition = (headers["content-disposition"] ?? headers["Content-Disposition"] ?? "").toLowerCase();
    const contentType = (headers["content-type"] ?? headers["Content-Type"] ?? "").toLowerCase();
    if (/attachment|filename\s*=|filename\*/i.test(disposition)) return true;
    if (/application\/(?:pdf|msword|vnd\.|octet-stream)|text\/(?:plain|csv)/i.test(contentType)) return true;
    return FILE_EXTENSION.test(new URL(response.url()).pathname);
  } catch {
    return false;
  }
}

function urlsFromOnclick(value: string): string[] {
  if (!value || !DOWNLOAD_WORDS.test(value)) return [];
  const found: string[] = [];
  const quoted = /["']([^"']{1,500})["']/g;
  for (let match = quoted.exec(value); match; match = quoted.exec(value)) {
    const candidate = match[1]?.trim();
    if (!candidate) continue;
    if (/^(?:https?:\/\/|\/|\.\.\/|\.\/)/i.test(candidate)) found.push(candidate);
  }
  return found;
}

export function resolveAttachmentSignals(
  signals: RawAttachmentSignal[],
  origin: string,
  options: Pick<SchoolAttachmentDiscoveryOptions, "attributeResolvers" | "trustedDownloadOrigins" | "maxCandidates"> = {},
): SchoolAttachmentLink[] {
  const maxCandidates = options.maxCandidates ?? DEFAULT_MAX_CANDIDATES;
  const resolvers = new Map((options.attributeResolvers ?? []).map((item) => [item.attribute.toLowerCase(), item]));
  const seen = new Set<string>();
  const links: SchoolAttachmentLink[] = [];
  const add = (rawHref: string, name: string, method: string) => {
    const url = allowedAttachmentUrl(rawHref, origin, options.trustedDownloadOrigins);
    if (!url || seen.has(url.toString())) return;
    seen.add(url.toString());
    links.push({ href: url.toString(), name: normalizeName(name || pathLeaf(url.pathname)), method });
  };

  for (const signal of signals) {
    if (!signal.safeToFetch) continue;
    for (const attribute of DIRECT_URL_ATTRIBUTES) {
      const value = signal.attributes[attribute];
      if (!value) continue;
      add(value, signal.name, `dom:${attribute}`);
    }

    for (const value of urlsFromOnclick(signal.attributes.onclick)) add(value, signal.name, "dom:onclick");

    for (const [attribute, value] of Object.entries(signal.attributes)) {
      const resolver = resolvers.get(attribute.toLowerCase());
      if (!resolver || !value) continue;
      try {
        const resolved = resolver.resolve(value, { name: signal.name, origin });
        if (resolved) add(resolved, signal.name, `resolver:${attribute}`);
      } catch {
        // A platform hint is best-effort and must never fail the crawl.
      }
    }
    if (links.length >= maxCandidates) break;
  }
  return links.slice(0, maxCandidates);
}

function browserScanExpression(rootSelector: string | undefined): string {
  return `(() => {
    const rootSelector = ${JSON.stringify(rootSelector ?? null)};
    const roots = rootSelector
      ? Array.from(document.querySelectorAll(rootSelector)).filter((node) => {
          const style = globalThis.getComputedStyle ? getComputedStyle(node) : null;
          return node.getAttribute('aria-hidden') !== 'true' && style?.display !== 'none' && style?.visibility !== 'hidden';
        })
      : [document];
    const selector = "a,button,[role='button'],[onclick],[download],[attlink],[data-href],[data-url],[data-download-url],[data-file-url],[data-path],[data-file],[data-filename],[data-attachment],[data-download],object[data],iframe[src],embed[src]";
    const directAttrs = ${JSON.stringify([...DIRECT_URL_ATTRIBUTES])};
    const customAttrs = ${JSON.stringify([...CUSTOM_VALUE_ATTRIBUTES])};
    const normalize = (value) => (value ?? '').replace(/\\s+/g, ' ').trim();
    const fileExt = /\\.(?:pdf|docx?|pptx?|xlsx?|txt|md|csv|rtf|zip|rar|png|jpe?g)(?:[?#].*)?$/i;
    const fileInText = /([A-Za-z0-9À-ÿ][A-Za-z0-9À-ÿ _().,'+\\-]{0,150}\\.(?:pdf|docx?|pptx?|xlsx?|txt|md|csv|rtf|zip|rar|png|jpe?g))/i;
    const downloadWords = /\\b(download|descargar|attachment|adjunto|archivo|file|documento|resource|recurso)\\b/i;
    const mutationWords = /\\b(upload|submit|send|save|delete|remove|destroy|turn\\s*in|hand\\s*in|edit|reply|subir|enviar|guardar|borrar|eliminar|entregar|responder|editar)\\b/i;
    const mutationRoute = /delete|remove|destroy|submit|save|upload|send|reply|edit|turnin|handin|borrar|eliminar|guardar|enviar|entregar/i;
    const signals = [];
    const seen = new Set();
    for (const root of roots) {
      for (const node of Array.from(root.querySelectorAll(selector))) {
        if (seen.has(node)) continue;
        seen.add(node);
        const ownText = normalize(node.textContent);
        const aria = normalize(node.getAttribute('aria-label'));
        const title = normalize(node.getAttribute('title'));
        const parentText = normalize(node.parentElement?.textContent).slice(0, 400);
        const context = [ownText, aria, title, parentText].filter(Boolean).join(' ');
        const attrs = {};
        for (const attr of [...directAttrs, ...customAttrs, 'download', 'onclick']) {
          const value = node.getAttribute(attr);
          if (value) attrs[attr] = normalize(value).slice(0, 500);
        }
        if (node.tagName === 'OBJECT') {
          const value = node.getAttribute('data');
          if (value) attrs['data-url'] = normalize(value).slice(0, 500);
        }
        const attrValues = Object.values(attrs).join(' ');
        const fileName = context.match(fileInText)?.[1]
          || Object.values(attrs).find((value) => fileExt.test(value))
          || normalize(node.getAttribute('download'));
        const hasCustomFileValue = customAttrs.some((attr) => Boolean(attrs[attr]));
        const hasEvidence = Boolean(fileName)
          || fileExt.test(attrValues)
          || hasCustomFileValue
          || downloadWords.test(context)
          || downloadWords.test(attrValues);
        if (!hasEvidence) continue;
        const dangerous = mutationWords.test([ownText, aria, title].join(' ')) || mutationRoute.test(attrValues);
        const safeToFetch = !dangerous && (
          Boolean(fileName)
          || hasCustomFileValue
          || downloadWords.test([ownText, aria, title, attrValues].join(' '))
          || fileExt.test(attrValues)
        );
        const interactive = node.matches("a,button,[role='button'],[onclick],[download],[attlink],[data-download],[data-file],[data-attachment]");
        const safeToInteract = interactive && !dangerous && (
          Boolean(fileName)
          || hasCustomFileValue
          || Boolean(node.getAttribute('download'))
          || (downloadWords.test(context) && /\\.(?:pdf|docx?|pptx?|xlsx?|txt|md|csv|rtf|zip|rar|png|jpe?g)/i.test(context))
        );
        const interactionKey = 'ibacalao-att-' + signals.length;
        if (node instanceof Element) node.setAttribute('data-ibacalao-attachment-key', interactionKey);
        signals.push({
          name: normalize(fileName || ownText || aria || title || 'attachment').slice(0, 240),
          attributes: attrs,
          interactionKey,
          safeToFetch,
          safeToInteract,
        });
        if (signals.length >= 80) return signals;
      }
    }
    return signals;
  })()`;
}

async function scanAttachmentSignals(page: WatcherPage, rootSelector?: string): Promise<RawAttachmentSignal[]> {
  if (!page.evaluate) return [];
  try {
    const evaluate = page.evaluate.bind(page) as unknown as (expression: string) => Promise<unknown>;
    const result = await evaluate(browserScanExpression(rootSelector));
    if (!Array.isArray(result)) return [];
    return result.filter((item): item is RawAttachmentSignal => Boolean(
      item && typeof item === "object" && !Array.isArray(item)
      && typeof (item as RawAttachmentSignal).name === "string"
      && typeof (item as RawAttachmentSignal).interactionKey === "string"
      && typeof (item as RawAttachmentSignal).safeToFetch === "boolean"
      && typeof (item as RawAttachmentSignal).safeToInteract === "boolean"
      && (item as RawAttachmentSignal).attributes
      && typeof (item as RawAttachmentSignal).attributes === "object",
    ));
  } catch {
    return [];
  }
}

async function revealAttachmentSections(page: WatcherPage, rootSelector: string | undefined, maxClicks: number): Promise<number> {
  if (!page.evaluate || maxClicks <= 0) return 0;
  const expression = `(() => {
    const rootSelector = ${JSON.stringify(rootSelector ?? null)};
    const maxClicks = ${Math.max(0, Math.min(maxClicks, 5))};
    const roots = rootSelector ? Array.from(document.querySelectorAll(rootSelector)) : [document];
    const normalize = (value) => (value ?? '').replace(/\\s+/g, ' ').trim();
    const revealWords = /\\b(show|view|see|open|expand|more|ver|mostrar|abrir|desplegar)\\b/i;
    const nouns = /\\b(attachments?|files?|documents?|resources?|materials?|adjuntos?|archivos?|documentos?|recursos?|materiales?)\\b/i;
    const mutations = /\\b(upload|submit|send|save|delete|remove|turn\\s*in|hand\\s*in|edit|reply|subir|enviar|guardar|borrar|eliminar|entregar|responder|editar)\\b/i;
    let clicked = 0;
    for (const root of roots) {
      for (const node of Array.from(root.querySelectorAll("button,[role='button'],summary,a[href^='#']"))) {
        if (clicked >= maxClicks) return clicked;
        const label = normalize([node.textContent, node.getAttribute('aria-label'), node.getAttribute('title')].filter(Boolean).join(' '));
        if (!nouns.test(label) || mutations.test(label)) continue;
        const explicitReveal = revealWords.test(label);
        const expandable = node.getAttribute('aria-expanded') === 'false' || Boolean(node.getAttribute('aria-controls')) || node.tagName === 'SUMMARY';
        if (!explicitReveal && !expandable) continue;
        if (!(node instanceof HTMLElement)) continue;
        node.click();
        clicked += 1;
      }
    }
    return clicked;
  })()`;
  try {
    const evaluate = page.evaluate.bind(page) as unknown as (expression: string) => Promise<unknown>;
    const clicked = await evaluate(expression);
    return typeof clicked === "number" && Number.isFinite(clicked) ? Math.max(0, Math.trunc(clicked)) : 0;
  } catch {
    return 0;
  }
}

async function readDownloadBytes(download: DownloadLike, maxBytes: number): Promise<Uint8Array | null> {
  const stream = await download.createReadStream().catch(() => null);
  if (!stream) return null;
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    for await (const chunk of stream) {
      const buffer = Buffer.from(chunk);
      total += buffer.byteLength;
      if (total > maxBytes) {
        await download.cancel?.().catch(() => undefined);
        return null;
      }
      chunks.push(buffer);
    }
    return new Uint8Array(Buffer.concat(chunks));
  } finally {
    await download.delete?.().catch(() => undefined);
  }
}

async function clickAttachmentControl(page: WatcherPage, interactionKey: string): Promise<boolean> {
  if (!page.evaluate) return false;
  try {
    const evaluate = page.evaluate.bind(page) as unknown as (expression: string) => Promise<unknown>;
    const clicked = await evaluate(`(() => {
      const node = document.querySelector(${JSON.stringify(`[data-ibacalao-attachment-key="${interactionKey}"]`)});
      if (!(node instanceof HTMLElement)) return false;
      node.click();
      return true;
    })()`);
    return clicked === true;
  } catch {
    return false;
  }
}

type CapturedInteractiveAttachment = {
  name: string;
  bytes: Uint8Array;
  method: "interaction:download" | "interaction:response" | "interaction:popup" | "interaction:navigation";
};

async function captureInteractiveAttachment(
  page: WatcherPage,
  signal: RawAttachmentSignal,
  origin: string,
  options: SchoolAttachmentDiscoveryOptions,
): Promise<CapturedInteractiveAttachment | null> {
  if (!signal.safeToInteract) return null;
  const interactive = page as InteractiveWatcherPage;
  if (!interactive.waitForEvent && !interactive.waitForResponse) return null;
  const timeout = Math.max(500, Math.min(options.interactionTimeoutMs ?? 4_000, 10_000));
  const maxFileBytes = options.maxFileBytes ?? DEFAULT_MAX_FILE_BYTES;
  const beforeUrl = page.url();

  const downloadPromise = interactive.waitForEvent
    ? interactive.waitForEvent("download", { timeout })
      .then((value) => ({ kind: "download" as const, value: value as DownloadLike }))
      .catch(() => null)
    : Promise.resolve(null);
  const popupPromise = interactive.waitForEvent
    ? interactive.waitForEvent("popup", { timeout })
      .then((value) => ({ kind: "popup" as const, value: value as PopupLike }))
      .catch(() => null)
    : Promise.resolve(null);
  const responsePromise = interactive.waitForResponse
    ? interactive.waitForResponse((response) => likelyAttachmentResponse(response), { timeout })
      .then((value) => ({ kind: "response" as const, value }))
      .catch(() => null)
    : Promise.resolve(null);

  if (!(await clickAttachmentControl(page, signal.interactionKey))) return null;
  const eventPromises: Array<Promise<
    | { kind: "download"; value: DownloadLike }
    | { kind: "popup"; value: PopupLike }
    | { kind: "response"; value: ResponseLike }
    | null
  >> = [];
  if (interactive.waitForEvent) {
    eventPromises.push(downloadPromise, popupPromise);
  }
  if (interactive.waitForResponse) {
    eventPromises.push(responsePromise);
  }
  eventPromises.push(new Promise<null>((resolve) => setTimeout(() => resolve(null), timeout)));
  const event = await Promise.race(eventPromises);

  if (event?.kind === "download") {
    const bytes = await readDownloadBytes(event.value, maxFileBytes);
    if (!bytes) return null;
    return { name: normalizeName(event.value.suggestedFilename() || signal.name), bytes, method: "interaction:download" };
  }

  if (event?.kind === "response") {
    const url = allowedAttachmentUrl(event.value.url(), origin, options.trustedDownloadOrigins);
    if (!url || !event.value.ok()) return null;
    const headers = event.value.headers();
    const contentLength = Number(headers["content-length"] ?? headers["Content-Length"] ?? "0");
    if (Number.isFinite(contentLength) && contentLength > maxFileBytes) return null;
    const bytes = await event.value.body();
    if (bytes.byteLength > maxFileBytes) return null;
    return {
      name: inferredFileName({ href: url.toString(), name: signal.name }, url, headers),
      bytes,
      method: "interaction:response",
    };
  }

  if (event?.kind === "popup") {
    try {
      await event.value.waitForLoadState?.("domcontentloaded", { timeout: Math.min(timeout, 3_000) }).catch(() => undefined);
      const popupUrl = allowedAttachmentUrl(event.value.url(), origin, options.trustedDownloadOrigins);
      if (popupUrl && page.request) {
        const response = await page.request.get(popupUrl.toString(), { timeout, failOnStatusCode: false, maxRedirects: 5 });
        if (response.ok()) {
          const finalUrl = allowedAttachmentUrl(response.url(), origin, options.trustedDownloadOrigins);
          if (finalUrl) {
            const headers = response.headers();
            const bytes = await response.body();
            if (bytes.byteLength <= maxFileBytes) {
              return {
                name: inferredFileName({ href: finalUrl.toString(), name: signal.name }, finalUrl, headers),
                bytes,
                method: "interaction:popup",
              };
            }
          }
        }
      }
    } finally {
      await event.value.close?.().catch(() => undefined);
    }
  }

  const afterUrl = page.url();
  if (afterUrl !== beforeUrl && page.request) {
    try {
      const navigated = allowedAttachmentUrl(afterUrl, origin, options.trustedDownloadOrigins);
      if (navigated && (FILE_EXTENSION.test(navigated.pathname) || DOWNLOAD_WORDS.test(navigated.pathname))) {
        const response = await page.request.get(navigated.toString(), { timeout, failOnStatusCode: false, maxRedirects: 5 });
        if (response.ok()) {
          const finalUrl = allowedAttachmentUrl(response.url(), origin, options.trustedDownloadOrigins);
          if (finalUrl) {
            const headers = response.headers();
            const bytes = await response.body();
            if (bytes.byteLength <= maxFileBytes) {
              return {
                name: inferredFileName({ href: finalUrl.toString(), name: signal.name }, finalUrl, headers),
                bytes,
                method: "interaction:navigation",
              };
            }
          }
        }
      }
    } finally {
      await page.goto(beforeUrl, { timeout: 30_000 }).catch(() => undefined);
    }
  }

  return null;
}

async function fetchAttachment(
  page: WatcherPage,
  origin: string,
  link: SchoolAttachmentLink,
  options: SchoolAttachmentDiscoveryOptions,
): Promise<{ name: string; bytes: Uint8Array; method: string } | null> {
  if (!page.request) return null;
  const url = allowedAttachmentUrl(link.href, origin, options.trustedDownloadOrigins);
  if (!url) return null;
  const maxFileBytes = options.maxFileBytes ?? DEFAULT_MAX_FILE_BYTES;
  try {
    const response = await page.request.get(url.toString(), { timeout: 30_000, failOnStatusCode: false, maxRedirects: 5 });
    if (!response.ok()) return null;
    const finalUrl = allowedAttachmentUrl(response.url(), origin, options.trustedDownloadOrigins);
    if (!finalUrl) return null;
    const headers = response.headers();
    const contentType = (headers["content-type"] ?? headers["Content-Type"] ?? "").toLowerCase();
    if (contentType.includes("text/html")) return null;
    const contentLength = Number(headers["content-length"] ?? headers["Content-Length"] ?? "0");
    if (Number.isFinite(contentLength) && contentLength > maxFileBytes) return null;
    const bytes = await response.body();
    if (bytes.byteLength > maxFileBytes) return null;
    return { name: inferredFileName(link, finalUrl, headers), bytes, method: link.method ?? "request" };
  } catch {
    return null;
  }
}

export async function discoverAndExtractSchoolAttachments(
  page: WatcherPage,
  origin: string,
  options: SchoolAttachmentDiscoveryOptions = {},
): Promise<SchoolAttachmentDiscoveryResult> {
  const maxCandidates = options.maxCandidates ?? DEFAULT_MAX_CANDIDATES;
  const maxTextCharsPerFile = options.maxTextCharsPerFile ?? DEFAULT_MAX_TEXT_CHARS;
  const maxTotalTextChars = options.maxTotalTextChars ?? DEFAULT_MAX_TOTAL_TEXT_CHARS;
  const methods: string[] = [];
  const names: string[] = [];
  const sections: string[] = [];
  const seenHashes = new Set<string>();
  let contentIntegrity: ContentIntegritySummary | undefined;
  let totalChars = 0;
  let extracted = 0;
  let interacted = 0;

  const append = async (name: string, bytes: Uint8Array, method: string) => {
    try { options.onFile?.(normalizeName(name), bytes); } catch { /* best effort */ }
    const parsed = await extractSchoolAttachmentBytes(name, bytes, {
      maxFileBytes: options.maxFileBytes ?? DEFAULT_MAX_FILE_BYTES,
      maxTextChars: maxTextCharsPerFile,
    });
    contentIntegrity = mergeContentIntegrity(contentIntegrity, parsed.contentIntegrity);
    if (!parsed.ok || seenHashes.has(parsed.sha256)) return;
    const remaining = maxTotalTextChars - totalChars;
    if (remaining <= 0) return;
    const text = parsed.text.slice(0, remaining);
    if (!text) return;
    seenHashes.add(parsed.sha256);
    const safeName = normalizeName(name);
    sections.push(`Attachment: ${safeName}\n${text}`);
    names.push(safeName);
    methods.push(method);
    totalChars += text.length;
    extracted += 1;
  };

  if (options.enableRevealInteractions !== false) {
    const revealed = await revealAttachmentSections(page, options.rootSelector, options.maxRevealInteractions ?? DEFAULT_MAX_REVEALS);
    interacted += revealed;
    if (revealed > 0) await new Promise((resolve) => setTimeout(resolve, 250));
  }

  const signals = await scanAttachmentSignals(page, options.rootSelector);
  const genericLinks = resolveAttachmentSignals(signals, origin, options);
  const seedLinks = (options.seedLinks ?? []).flatMap((link) => {
    const url = allowedAttachmentUrl(link.href, origin, options.trustedDownloadOrigins);
    return url ? [{ ...link, href: url.toString(), method: link.method ?? "adapter:seed" }] : [];
  });
  const allLinks: SchoolAttachmentLink[] = [];
  const seenUrls = new Set<string>();
  for (const link of [...seedLinks, ...genericLinks]) {
    if (seenUrls.has(link.href)) continue;
    seenUrls.add(link.href);
    allLinks.push(link);
    if (allLinks.length >= maxCandidates) break;
  }

  for (const link of allLinks) {
    if (totalChars >= maxTotalTextChars) break;
    const fetched = await fetchAttachment(page, origin, link, options);
    if (!fetched) continue;
    await append(fetched.name, fetched.bytes, fetched.method);
  }

  if (options.enableDownloadInteractions !== false && totalChars < maxTotalTextChars) {
    let remainingInteractions = options.maxDownloadInteractions ?? DEFAULT_MAX_DOWNLOAD_INTERACTIONS;
    for (const signal of signals) {
      if (remainingInteractions <= 0 || totalChars >= maxTotalTextChars) break;
      if (!signal.safeToInteract) continue;
      const resolved = resolveAttachmentSignals([signal], origin, options);
      if (resolved.length > 0) continue;
      remainingInteractions -= 1;
      interacted += 1;
      const captured = await captureInteractiveAttachment(page, signal, origin, options);
      if (!captured) continue;
      await append(captured.name, captured.bytes, captured.method);
    }
  }

  return {
    text: sections.join("\n\n"),
    extracted,
    discovered: allLinks.length + signals.filter((signal) => signal.safeToInteract).length,
    interacted,
    names,
    methods,
    ...(contentIntegrity ? { contentIntegrity } : {}),
  };
}
