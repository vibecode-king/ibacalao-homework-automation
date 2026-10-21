const LOOPBACK_HOSTS = new Set(["localhost", "127.0.0.1", "::1"]);

/** Validate configured endpoints before sending bearer tokens or student content. */
export function normalizeAgentServiceBaseUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value.trim());
  } catch {
    throw new Error("The configured agent service URL must be an absolute HTTP(S) URL.");
  }
  const hostname = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  const isLoopbackHttp = url.protocol === "http:" && LOOPBACK_HOSTS.has(hostname);
  if (url.protocol !== "https:" && !isLoopbackHttp) {
    throw new Error("The configured agent service URL must use HTTPS (HTTP is allowed only for loopback).");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error("The configured agent service URL cannot contain credentials, a query, or a fragment.");
  }
  return url.toString().replace(/\/+$/, "");
}
