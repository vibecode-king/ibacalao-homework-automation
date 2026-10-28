// Universal school-source identity.
//
// Product code must not have to enumerate every LMS vendor. A source key is a
// bounded, server-safe namespace chosen by the local school engine:
//   vendor:canvas
//   vendor:managebac
//   portal:98f7a93e...
//
// Legacy watcher clients may still send bare names such as "managebac" while
// they migrate. Those are valid source keys too; new universal integrations
// should prefer the explicit vendor:/portal: prefixes.

export type SchoolSourceKey = string;

const SCHOOL_SOURCE_KEY = /^[a-z0-9][a-z0-9:_-]{0,79}$/;

export function isSchoolSourceKey(value: unknown): value is SchoolSourceKey {
  return typeof value === "string" && SCHOOL_SOURCE_KEY.test(value);
}

export function parseSchoolSourceKey(value: unknown): SchoolSourceKey | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  return isSchoolSourceKey(normalized) ? normalized : null;
}

/** Prefer the universal field, but accept the old watcher payload during rollout. */
export function sourceKeyFromEnvelope(input: {
  sourceKey?: unknown;
  platform?: unknown;
}): SchoolSourceKey | null {
  if (input.sourceKey !== undefined) return parseSchoolSourceKey(input.sourceKey);
  return parseSchoolSourceKey(input.platform);
}
