import { test } from "node:test";
import assert from "node:assert/strict";
import { isSchoolSourceKey, parseSchoolSourceKey, sourceKeyFromEnvelope } from "../source";

test("accepts universal vendor and portal source keys", () => {
  assert.equal(isSchoolSourceKey("vendor:managebac"), true);
  assert.equal(isSchoolSourceKey("vendor:learnbox"), true);
  assert.equal(isSchoolSourceKey("portal:98f7a93e"), true);
});

test("normalizes case and preserves legacy watcher platform names", () => {
  assert.equal(parseSchoolSourceKey(" Vendor:Canvas "), "vendor:canvas");
  assert.equal(sourceKeyFromEnvelope({ platform: "managebac" }), "managebac");
});

test("sourceKey wins over the legacy platform field", () => {
  assert.equal(
    sourceKeyFromEnvelope({ sourceKey: "portal:abc123", platform: "managebac" }),
    "portal:abc123",
  );
});

test("rejects malformed or overlong source keys", () => {
  assert.equal(parseSchoolSourceKey("https://school.example"), null);
  assert.equal(parseSchoolSourceKey("portal:bad value"), null);
  assert.equal(parseSchoolSourceKey("a".repeat(81)), null);
});
