const DANGEROUS_HTML =
  /(?:<\s*\/?\s*(?:script|iframe|object|embed|svg|math|style|link|meta|base)\b|\son[a-z0-9_-]+\s*=|(?:javascript|vbscript)\s*:|data\s*:\s*text\/html)/i;
const CONTROL_CHARS = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/;

/**
 * School capture HTML is machine evidence, never executable markup. Reject the
 * snapshot if it contains active-content primitives rather than trying to repair it.
 */
export function safeMachineHtml(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (
    !trimmed ||
    trimmed.length > maxLength ||
    CONTROL_CHARS.test(trimmed) ||
    DANGEROUS_HTML.test(trimmed)
  ) {
    return undefined;
  }
  return trimmed;
}

/** Accept only a plain relative path, never a protocol-relative/backslash URL. */
export function safeRelativePath(value: unknown, maxLength = 500): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (
    !trimmed ||
    trimmed.length > maxLength ||
    CONTROL_CHARS.test(trimmed) ||
    !trimmed.startsWith("/") ||
    trimmed.startsWith("//") ||
    trimmed.includes("\\")
  ) {
    return undefined;
  }
  try {
    const parsed = new URL(trimmed, "https://ibacalao.invalid");
    if (parsed.origin !== "https://ibacalao.invalid") return undefined;
    return trimmed;
  } catch {
    return undefined;
  }
}

/** Relative paths and HTTP(S) URLs are safe for stored href-like fields. */
export function safeNavigableUrl(value: unknown, maxLength = 1000): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  if (
    !trimmed ||
    trimmed.length > maxLength ||
    CONTROL_CHARS.test(trimmed) ||
    trimmed.includes("\\")
  ) {
    return undefined;
  }
  if (trimmed.startsWith("/")) return safeRelativePath(trimmed, maxLength);
  try {
    const parsed = new URL(trimmed);
    if (parsed.protocol !== "https:" && parsed.protocol !== "http:") return undefined;
    return parsed.toString();
  } catch {
    return undefined;
  }
}

/** Normalize an assignment link for change detection without volatile navigation data. */
export function normalizeNavigableUrl(value: string | undefined): string {
  if (!value) return "";
  const trimmed = value.trim();
  const isRelative = trimmed.startsWith("/");
  try {
    const parsed = new URL(trimmed, "https://ibacalao.invalid");
    parsed.hash = "";
    for (const key of Array.from(parsed.searchParams.keys())) {
      if (/^(?:session(?:id)?|sid|utm_.+|tracking)$/i.test(key)) parsed.searchParams.delete(key);
    }
    parsed.searchParams.sort();
    return isRelative ? `${parsed.pathname}${parsed.search}` : parsed.toString();
  } catch {
    return trimmed;
  }
}
