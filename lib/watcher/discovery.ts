// Pure school-platform discovery helpers. No Playwright, filesystem, or browser
// imports live here so these heuristics can be unit-tested and reused safely.

export const SCHOOL_DISCOVERY_PROFILE_KEY = "school-platform";

export type SchoolPlatformGuess = {
  platformId: string;
  platformLabel: string;
  schoolLabel?: string;
  origin: string;
  siteKey: string;
  recognized: boolean;
};

export type SchoolPlatformConnection = SchoolPlatformGuess & {
  profileKey: string;
  connectedAt: string;
};

const COMMON_SECOND_LEVEL_TLDS = new Set(["ac", "co", "com", "edu", "gov", "net", "org"]);
const MEANINGLESS_SUBDOMAINS = new Set([
  "www", "app", "apps", "auth", "login", "signin", "sign-in", "sso", "portal",
  "student", "students", "school", "schools", "lms", "learn", "learning",
]);
const MEANINGLESS_PATHS = new Set([
  "app", "auth", "dashboard", "home", "index", "learn", "learning", "login",
  "portal", "signin", "sign-in", "sso", "student", "students",
]);

const KNOWN_PLATFORMS: Array<{ suffix: string; id: string; label: string }> = [
  { suffix: "managebac.com", id: "managebac", label: "ManageBac" },
  { suffix: "instructure.com", id: "canvas", label: "Canvas" },
  { suffix: "toddleapp.com", id: "toddle", label: "Toddle" },
  { suffix: "schoology.com", id: "schoology", label: "Schoology" },
  { suffix: "fireflycloud.net", id: "firefly", label: "Firefly" },
  { suffix: "classroom.google.com", id: "classroom", label: "Google Classroom" },
  { suffix: "veracross.com", id: "veracross", label: "Veracross" },
  // Longer country-code suffix first so ukschool.learnbox.com.ec is not
  // treated as an unknown stem of learnbox.com.
  { suffix: "learnbox.com.ec", id: "learnbox", label: "Learnbox" },
  { suffix: "learnbox.com", id: "learnbox", label: "Learnbox" },
];

const IGNORED_DISCOVERY_HOSTS = new Set([
  "google.com", "www.google.com", "accounts.google.com",
  "bing.com", "www.bing.com", "duckduckgo.com", "www.duckduckgo.com",
  "search.yahoo.com", "yahoo.com", "www.yahoo.com",
  "login.microsoftonline.com", "account.live.com", "appleid.apple.com",
]);

export function normalizedPlatformId(raw: string): string {
  return raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 80);
}

export function siteKeyForHost(rawHost: string): string {
  const host = rawHost.toLowerCase().replace(/^\.+|\.+$/g, "");
  const parts = host.split(".").filter(Boolean);
  if (parts.length <= 2) return host;
  const tld = parts.at(-1) ?? "";
  const second = parts.at(-2) ?? "";
  if (tld.length === 2 && COMMON_SECOND_LEVEL_TLDS.has(second) && parts.length >= 3) {
    return parts.slice(-3).join(".");
  }
  return parts.slice(-2).join(".");
}

function humanize(raw: string): string {
  const text = decodeURIComponent(raw)
    .replace(/\.(html?|aspx?|php)$/i, "")
    .replace(/[_-]+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!text) return "";
  return text.replace(/\b\w/g, (char) => char.toUpperCase());
}

function knownPlatform(host: string): { suffix: string; id: string; label: string } | undefined {
  return KNOWN_PLATFORMS.find(({ suffix }) => host === suffix || host.endsWith(`.${suffix}`));
}

function meaningfulSubdomain(host: string, siteKey: string, knownSuffix?: string): string | undefined {
  const suffix = knownSuffix ?? siteKey;
  if (host === suffix || !host.endsWith(`.${suffix}`)) return undefined;
  const prefix = host.slice(0, -(suffix.length + 1));
  const pieces = prefix.split(".").filter(Boolean);
  const candidate = pieces.find((piece) => !MEANINGLESS_SUBDOMAINS.has(piece.toLowerCase()));
  return candidate ? humanize(candidate) : undefined;
}

function meaningfulPath(pathname: string): string | undefined {
  const segments = pathname.split("/").map((part) => part.trim()).filter(Boolean);
  for (const segment of segments) {
    const decoded = decodeURIComponent(segment);
    const normalized = decoded.toLowerCase();
    if (MEANINGLESS_PATHS.has(normalized)) continue;
    if (/^\d+$/.test(normalized) || normalized.length < 3) continue;
    const human = humanize(decoded);
    if (human) return human;
  }
  return undefined;
}

function schoolFromTitle(title: string | undefined, platformLabel: string): string | undefined {
  if (!title) return undefined;
  const pieces = title
    .split(/[|–—·:]/)
    .map((part) => part.trim())
    .filter(Boolean)
    .filter((part) => !/^(login|log in|sign in|dashboard|home)$/i.test(part))
    .filter((part) => part.toLowerCase() !== platformLabel.toLowerCase());
  const candidate = pieces.find((part) => part.length >= 3 && part.length <= 80);
  return candidate ? humanize(candidate) : undefined;
}

export function isIgnoredDiscoveryURL(rawUrl: string): boolean {
  try {
    const parsed = new URL(rawUrl);
    const host = parsed.hostname.toLowerCase();
    return IGNORED_DISCOVERY_HOSTS.has(host)
      || host.endsWith(".googleusercontent.com")
      || host.endsWith(".gstatic.com");
  } catch {
    return true;
  }
}

export function inferSchoolPlatform(rawUrl: string, pageTitle?: string): SchoolPlatformGuess | null {
  let parsed: URL;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return null;
  }
  if (!/^https?:$/.test(parsed.protocol)) return null;
  const host = parsed.hostname.toLowerCase();
  if (!host || isIgnoredDiscoveryURL(rawUrl)) return null;

  const known = knownPlatform(host);
  const siteKey = known?.suffix ?? siteKeyForHost(host);
  const domainStem = siteKey.split(".")[0] ?? siteKey;
  const platformLabel = known?.label ?? humanize(domainStem);
  const platformId = known?.id ?? normalizedPlatformId(domainStem);
  if (!platformId || !platformLabel) return null;

  const schoolLabel = meaningfulSubdomain(host, siteKey, known?.suffix)
    ?? meaningfulPath(parsed.pathname)
    ?? schoolFromTitle(pageTitle, platformLabel);

  return {
    platformId,
    platformLabel,
    ...(schoolLabel ? { schoolLabel } : {}),
    origin: parsed.origin,
    siteKey,
    recognized: Boolean(known),
  };
}

export function samePlatformSite(rawUrl: string, guess: SchoolPlatformGuess): boolean {
  try {
    return siteKeyForHost(new URL(rawUrl).hostname) === siteKeyForHost(guess.siteKey);
  } catch {
    return false;
  }
}
