import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import { extname } from "node:path";
import { strFromU8, unzipSync } from "fflate";
import {
  analyzePotentialPromptInjection,
  mergeContentIntegrity,
  shouldQuarantinePresentedText,
  type ContentIntegrityReason,
  type ContentIntegritySummary,
} from "../security/contentIntegrity";

const DEFAULT_MAX_FILE_BYTES = 25 * 1024 * 1024;
const DEFAULT_MAX_TEXT_CHARS = 16_000;
const MAX_UNZIPPED_XML_BYTES = 40 * 1024 * 1024;

export type SchoolAttachmentKind = "pdf" | "docx" | "pptx" | "text" | "unsupported";

export type SchoolAttachmentExtraction =
  | {
      ok: true;
      kind: Exclude<SchoolAttachmentKind, "unsupported">;
      text: string;
      sha256: string;
      bytes: number;
      contentIntegrity?: ContentIntegritySummary;
    }
  | {
      ok: false;
      kind: SchoolAttachmentKind;
      reason: "missing" | "too_large" | "unsupported" | "parse_error" | "empty";
      /** Preserved even when every extracted chunk was quarantined. */
      contentIntegrity?: ContentIntegritySummary;
    };

export type SchoolAttachmentExtractionOptions = {
  maxFileBytes?: number;
  maxTextChars?: number;
};

function normalizedText(value: string, maxChars: number): string {
  return value
    .replace(/\u0000/g, "")
    .replace(/[\t\f\v]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/[ ]{2,}/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
    .slice(0, maxChars);
}

function decodeXmlEntities(value: string): string {
  return value
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(Number.parseInt(n, 16)));
}

function textFromXml(xml: string): string {
  const chunks: string[] = [];
  const regex = /<(?:w:t|a:t)(?:\s[^>]*)?>([\s\S]*?)<\/(?:w:t|a:t)>/gi;
  for (let match = regex.exec(xml); match; match = regex.exec(xml)) {
    if (match[1]) chunks.push(decodeXmlEntities(match[1]));
  }
  return chunks.join("\n");
}

function xmlAttribute(xml: string, name: string): string | undefined {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return xml.match(new RegExp(`${escaped}\\s*=\\s*["']([^"']+)["']`, "i"))?.[1];
}

function presentationReasonsForOfficeRun(runXml: string, kind: "docx" | "pptx"): ContentIntegrityReason[] {
  const reasons: ContentIntegrityReason[] = [];
  if (kind === "docx") {
    const properties = runXml.match(/<w:rPr(?:\s[^>]*)?>([\s\S]*?)<\/w:rPr>/i)?.[0] ?? "";
    if (/<w:(?:vanish|webHidden)(?:\s[^>]*)?\/?\s*>/i.test(properties)) reasons.push("office_hidden_text");
    const sizeMatch = properties.match(/<w:sz(?:Cs)?\b[^>]*w:val\s*=\s*["'](\d+)["']/i)?.[1];
    const size = Number(sizeMatch ?? Number.NaN);
    if (Number.isFinite(size) && size >= 0 && size <= 12) reasons.push("tiny_text"); // Word stores half-points.
    const color = properties.match(/<w:color\b[^>]*w:val\s*=\s*["']([0-9a-f]{6})["']/i)?.[1]?.toLowerCase();
    if (color === "ffffff" || color === "fefefe") reasons.push("low_contrast_text");
  } else {
    const properties = runXml.match(/<a:rPr(?:\s[^>]*)?[^>]*>/i)?.[0] ?? "";
    const hundredths = Number(xmlAttribute(properties, "sz") ?? Number.NaN);
    if (Number.isFinite(hundredths) && hundredths >= 0 && hundredths <= 600) reasons.push("tiny_text");
    const color = runXml.match(/<a:srgbClr\b[^>]*val\s*=\s*["']([0-9a-f]{6})["']/i)?.[1]?.toLowerCase();
    if (color === "ffffff" || color === "fefefe") reasons.push("low_contrast_text");
  }
  return Array.from(new Set(reasons));
}

function officeXmlText(xml: string, kind: "docx" | "pptx"): { text: string; integrity?: ContentIntegritySummary } {
  const runPattern = kind === "docx"
    ? /<w:r(?:\s[^>]*)?>([\s\S]*?)<\/w:r>/gi
    : /<a:r(?:\s[^>]*)?>([\s\S]*?)<\/a:r>/gi;
  const chunks: string[] = [];
  let integrity: ContentIntegritySummary | undefined;
  let matchedRun = false;
  for (let match = runPattern.exec(xml); match; match = runPattern.exec(xml)) {
    matchedRun = true;
    const runXml = match[0];
    const text = textFromXml(runXml).replace(/\s+/g, " ").trim();
    if (!text) continue;
    const presentationReasons = presentationReasonsForOfficeRun(runXml, kind);
    const report = analyzePotentialPromptInjection(text, presentationReasons);
    integrity = mergeContentIntegrity(integrity, report);
    if (shouldQuarantinePresentedText(report, presentationReasons)) continue;
    chunks.push(text);
  }
  if (!matchedRun) {
    const text = textFromXml(xml);
    return { text, ...(analyzePotentialPromptInjection(text) ? { integrity: analyzePotentialPromptInjection(text) } : {}) };
  }
  return { text: chunks.join("\n"), ...(integrity ? { integrity } : {}) };
}

function unzipOfficeText(
  bytes: Uint8Array,
  kind: "docx" | "pptx",
  maxChars: number,
): { text: string; integrity?: ContentIntegritySummary } {
  const archive = unzipSync(bytes);
  const names = Object.keys(archive)
    .filter((name) => {
      if (kind === "docx") {
        return /^word\/(?:document|header\d+|footer\d+|footnotes|endnotes|comments)\.xml$/i.test(name);
      }
      return /^ppt\/(?:slides\/slide\d+|notesSlides\/notesSlide\d+)\.xml$/i.test(name);
    })
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

  let unzippedBytes = 0;
  const chunks: string[] = [];
  let integrity: ContentIntegritySummary | undefined;
  for (const name of names) {
    const entry = archive[name];
    if (!entry) continue;
    unzippedBytes += entry.byteLength;
    if (unzippedBytes > MAX_UNZIPPED_XML_BYTES) throw new Error("office archive too large");
    const extracted = officeXmlText(strFromU8(entry), kind);
    chunks.push(extracted.text);
    integrity = mergeContentIntegrity(integrity, extracted.integrity);
    if (chunks.join("\n").length >= maxChars) break;
  }
  return { text: normalizedText(chunks.join("\n\n"), maxChars), ...(integrity ? { integrity } : {}) };
}

function ensurePdfTextOnlyGlobals(): void {
  const globals = globalThis as unknown as Record<string, unknown>;
  if (!globals.DOMMatrix) {
    class TextOnlyDOMMatrix {
      a = 1;
      b = 0;
      c = 0;
      d = 1;
      e = 0;
      f = 0;

      constructor(initial?: ArrayLike<number>) {
        if (initial && initial.length >= 6) {
          this.a = Number(initial[0]);
          this.b = Number(initial[1]);
          this.c = Number(initial[2]);
          this.d = Number(initial[3]);
          this.e = Number(initial[4]);
          this.f = Number(initial[5]);
        }
      }

      multiplySelf(): this { return this; }
      preMultiplySelf(): this { return this; }
      invertSelf(): this { return this; }
      translate(): TextOnlyDOMMatrix { return new TextOnlyDOMMatrix([this.a, this.b, this.c, this.d, this.e, this.f]); }
      scale(): TextOnlyDOMMatrix { return new TextOnlyDOMMatrix([this.a, this.b, this.c, this.d, this.e, this.f]); }
    }
    globals.DOMMatrix = TextOnlyDOMMatrix;
  }
  if (!globals.ImageData) {
    globals.ImageData = class TextOnlyImageData {
      data: Uint8ClampedArray;
      width: number;
      height: number;

      constructor(dataOrWidth: Uint8ClampedArray | number, widthOrHeight: number, height = 0) {
        if (typeof dataOrWidth === "number") {
          this.width = dataOrWidth;
          this.height = widthOrHeight;
          this.data = new Uint8ClampedArray(this.width * this.height * 4);
        } else {
          this.data = dataOrWidth;
          this.width = widthOrHeight;
          this.height = height;
        }
      }
    };
  }
  if (!globals.Path2D) {
    globals.Path2D = class TextOnlyPath2D {
      addPath(): void {}
    };
  }
}

async function pdfText(
  bytes: Uint8Array,
  maxChars: number,
): Promise<{ text: string; integrity?: ContentIntegritySummary }> {
  // pdfjs' Node build tries to import a native canvas package solely to install
  // rendering globals such as DOMMatrix. School attachment enrichment never
  // renders pages; it only reads the text layer. Minimal text-only globals keep
  // parsing portable when the optional native canvas binding is unavailable.
  ensurePdfTextOnlyGlobals();
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  // Buffer is a Uint8Array subclass, but pdfjs intentionally rejects Buffer.
  // Normalize all callers to a plain Uint8Array at this boundary.
  const loadingTask = pdfjs.getDocument({
    data: new Uint8Array(bytes),
    useSystemFonts: true,
  });
  try {
    const document = await loadingTask.promise;
    const chunks: string[] = [];
    let integrity: ContentIntegritySummary | undefined;
    for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber += 1) {
      const page = await document.getPage(pageNumber);
      const content = await page.getTextContent();
      const pageText = content.items
        .flatMap((item) => {
          if (!("str" in item) || typeof item.str !== "string") return [];
          const text = item.str.replace(/\s+/g, " ").trim();
          if (!text) return [];
          const transform = "transform" in item && Array.isArray(item.transform) ? item.transform : [];
          const fontSize = transform.length >= 2 ? Math.hypot(Number(transform[0]) || 0, Number(transform[1]) || 0) : Number.NaN;
          const presentationReasons: ContentIntegrityReason[] = Number.isFinite(fontSize) && fontSize >= 0 && fontSize <= 6
            ? ["tiny_text"]
            : [];
          const report = analyzePotentialPromptInjection(text, presentationReasons);
          integrity = mergeContentIntegrity(integrity, report);
          return shouldQuarantinePresentedText(report, presentationReasons) ? [] : [text];
        })
        .join(" ");
      chunks.push(pageText);
      if (chunks.join("\n").length >= maxChars) break;
    }
    const text = normalizedText(chunks.join("\n\n"), maxChars);
    integrity = mergeContentIntegrity(integrity, analyzePotentialPromptInjection(text));
    return { text, ...(integrity ? { integrity } : {}) };
  } finally {
    await loadingTask.destroy();
  }
}

function detectKind(fileName: string, bytes: Uint8Array): SchoolAttachmentKind {
  const extension = extname(fileName).toLowerCase();
  if (bytes.length >= 5 && Buffer.from(bytes.subarray(0, 5)).toString("ascii") === "%PDF-") return "pdf";
  const isZip = bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b && [0x03, 0x05, 0x07].includes(bytes[2]);
  if (isZip && extension === ".docx") return "docx";
  if (isZip && extension === ".pptx") return "pptx";
  if ([".txt", ".md", ".csv", ".rtf"].includes(extension)) return "text";
  return "unsupported";
}

/**
 * Parse an attachment that is already in memory. The active Playwright school
 * watcher uses this path after fetching an attachment with the authenticated
 * browser context, so it never has to persist a temporary copy to disk.
 */
export async function extractSchoolAttachmentBytes(
  fileName: string,
  bytes: Uint8Array,
  options: SchoolAttachmentExtractionOptions = {},
): Promise<SchoolAttachmentExtraction> {
  const maxFileBytes = options.maxFileBytes ?? DEFAULT_MAX_FILE_BYTES;
  const maxTextChars = options.maxTextChars ?? DEFAULT_MAX_TEXT_CHARS;
  if (bytes.byteLength <= 0) return { ok: false, kind: "unsupported", reason: "empty" };
  if (bytes.byteLength > maxFileBytes) return { ok: false, kind: "unsupported", reason: "too_large" };

  const kind = detectKind(fileName, bytes);
  if (kind === "unsupported") return { ok: false, kind, reason: "unsupported" };

  try {
    let text: string;
    let contentIntegrity: ContentIntegritySummary | undefined;
    if (kind === "pdf") {
      const extracted = await pdfText(bytes, maxTextChars);
      text = extracted.text;
      contentIntegrity = extracted.integrity;
    } else if (kind === "docx" || kind === "pptx") {
      const extracted = unzipOfficeText(bytes, kind, maxTextChars);
      text = extracted.text;
      contentIntegrity = extracted.integrity;
    } else {
      text = normalizedText(Buffer.from(bytes).toString("utf8"), maxTextChars);
      contentIntegrity = analyzePotentialPromptInjection(text);
    }
    if (!text) {
      return { ok: false, kind, reason: "empty", ...(contentIntegrity ? { contentIntegrity } : {}) };
    }
    return {
      ok: true,
      kind,
      text,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      bytes: bytes.byteLength,
      ...(contentIntegrity ? { contentIntegrity } : {}),
    };
  } catch {
    return { ok: false, kind, reason: "parse_error" };
  }
}

export async function extractSchoolAttachment(
  filePath: string,
  options: SchoolAttachmentExtractionOptions = {},
): Promise<SchoolAttachmentExtraction> {
  const maxFileBytes = options.maxFileBytes ?? DEFAULT_MAX_FILE_BYTES;
  let size: number;
  try {
    size = statSync(filePath).size;
  } catch {
    return { ok: false, kind: "unsupported", reason: "missing" };
  }
  if (size <= 0) return { ok: false, kind: "unsupported", reason: "empty" };
  if (size > maxFileBytes) return { ok: false, kind: "unsupported", reason: "too_large" };

  let bytes: Uint8Array;
  try {
    bytes = new Uint8Array(readFileSync(filePath));
  } catch {
    return { ok: false, kind: "unsupported", reason: "missing" };
  }
  return extractSchoolAttachmentBytes(filePath, bytes, options);
}
