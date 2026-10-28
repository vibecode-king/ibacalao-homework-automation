#!/usr/bin/env node
// Verifies that the native bundles and release metadata agree with release-version.json.
// The website package version lives in the ibacalao website repo and is checked there.
// latest.json may intentionally lag while a new signed/notarized build is
// waiting for promotion, but it must never claim a version newer than source.

const fs = require("fs");
const crypto = require("crypto");
const path = require("path");

const root = path.join(__dirname, "..");
const source = JSON.parse(fs.readFileSync(path.join(root, "release-version.json"), "utf8"));
const versionPattern = /^\d+\.\d+\.\d+$/;
const buildPattern = /^\d+$/;

if (!versionPattern.test(source.version) || !buildPattern.test(source.build)) {
  throw new Error("release-version.json must contain a numeric semver version and build number");
}

const files = [
  "native/marginalia/Info.plist",
  "native/LiveExaminerOverlay/Info.plist",
  "native/LiveExaminerOverlay/LiveExaminerOverlay.xcodeproj/project.pbxproj",
];

const mismatches = [];
for (const relative of files) {
  const content = fs.readFileSync(path.join(root, relative), "utf8");
  const versionMatches = relative.endsWith("project.pbxproj")
    ? content.match(/MARKETING_VERSION\s*=\s*([^;]+);/g)?.every((line) => line.includes(source.version))
    : content.includes(source.version);
  const buildMatches = relative.endsWith("project.pbxproj")
    ? content.match(/CURRENT_PROJECT_VERSION\s*=\s*([^;]+);/g)?.every((line) => line.includes(source.build))
    : content.includes(relative.includes("package") ? source.version : source.build);
  if (!versionMatches || !buildMatches) mismatches.push(relative);
}

if (mismatches.length) {
  throw new Error(`Release version mismatch in: ${mismatches.join(", ")}`);
}

const latestPath = path.join(root, "public/downloads/digital/latest.json");
if (fs.existsSync(latestPath)) {
  const latest = JSON.parse(fs.readFileSync(latestPath, "utf8"));
  const newer = (a, b) => {
    const [x, y] = [a, b].map((v) => v.split(".").map(Number));
    const i = x.findIndex((n, k) => n !== y[k]);
    return i !== -1 && x[i] > y[i];
  };
  for (const [platform, artifact] of Object.entries(latest.platforms || {})) {
    const current = artifact?.version;
    if (current && newer(current, source.version)) {
      throw new Error(`public latest.json ${platform} (${current}) is newer than release source (${source.version})`);
    }
    if (current !== source.version) {
      console.log(`Release source ${source.version} (${source.build}) is ahead of public ${platform} artifact ${current || "none"}; promotion remains pending.`);
    }

    if (typeof artifact?.url === "string" && artifact.url.startsWith("/downloads/digital/")) {
      const artifactPath = path.join(root, "public", artifact.url);
      if (!fs.existsSync(artifactPath)) {
        throw new Error(`Missing public ${platform} artifact: ${artifact.url}`);
      }
      const bytes = fs.readFileSync(artifactPath);
      const actualSize = bytes.length;
      const actualSha = crypto.createHash("sha256").update(bytes).digest("hex");
      if (artifact.sizeBytes !== actualSize) {
        throw new Error(`${platform} size mismatch: manifest=${artifact.sizeBytes} file=${actualSize}`);
      }
      if (artifact.sha256 !== actualSha) {
        throw new Error(`${platform} sha256 mismatch: manifest=${artifact.sha256} file=${actualSha}`);
      }
    }
  }
}

console.log(`Release version OK: iBacalao ${source.version} (${source.build})`);
