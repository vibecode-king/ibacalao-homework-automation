import assert from "node:assert/strict";
import test from "node:test";
import { inferSchoolPlatform, isIgnoredDiscoveryURL, siteKeyForHost } from "../discovery";

test("recognizes known LMS vendors and school subdomains", () => {
  assert.deepEqual(inferSchoolPlatform("https://san-ignacio.instructure.com/login"), {
    platformId: "canvas",
    platformLabel: "Canvas",
    schoolLabel: "San Ignacio",
    origin: "https://san-ignacio.instructure.com",
    siteKey: "instructure.com",
    recognized: true,
  });
});

test("infers an unknown platform and school from hostname", () => {
  assert.deepEqual(inferSchoolPlatform("https://east.fakeschool.example/home"), {
    platformId: "fakeschool",
    platformLabel: "Fakeschool",
    schoolLabel: "East",
    origin: "https://east.fakeschool.example",
    siteKey: "fakeschool.example",
    recognized: false,
  });
});

test("recognizes Learnbox including country-code tenants", () => {
  assert.deepEqual(inferSchoolPlatform("https://sanignacio.learnbox.com/dashboard"), {
    platformId: "learnbox",
    platformLabel: "Learnbox",
    schoolLabel: "Sanignacio",
    origin: "https://sanignacio.learnbox.com",
    siteKey: "learnbox.com",
    recognized: true,
  });
  assert.deepEqual(inferSchoolPlatform("https://ukschool.learnbox.com.ec/index/3"), {
    platformId: "learnbox",
    platformLabel: "Learnbox",
    schoolLabel: "Ukschool",
    origin: "https://ukschool.learnbox.com.ec",
    siteKey: "learnbox.com.ec",
    recognized: true,
  });
});

test("falls back to a meaningful URL slug for the school", () => {
  const guess = inferSchoolPlatform("https://learnbox.com/colegio-san-ignacio/student/home");
  assert.equal(guess?.platformLabel, "Learnbox");
  assert.equal(guess?.schoolLabel, "Colegio San Ignacio");
});

test("falls back to page title when host and path have no school slug", () => {
  const guess = inferSchoolPlatform("https://learnbox.com/login", "Unidad Educativa San Ignacio | Learnbox");
  assert.equal(guess?.schoolLabel, "Unidad Educativa San Ignacio");
});

test("search and SSO hosts are ignored during discovery", () => {
  assert.equal(isIgnoredDiscoveryURL("https://www.google.com/search?q=school"), true);
  assert.equal(isIgnoredDiscoveryURL("https://login.microsoftonline.com/tenant/oauth2"), true);
  assert.equal(isIgnoredDiscoveryURL("https://school.managebac.com/login"), false);
});

test("site key handles common country-code domains", () => {
  assert.equal(siteKeyForHost("portal.school.co.uk"), "school.co.uk");
});
