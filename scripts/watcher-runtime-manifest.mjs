#!/usr/bin/env node
// Writes the runtime-manifest.json shipped inside the signed Mac app. It pins
// the official public downloads the app assembles after install (Node from
// nodejs.org, Playwright from npm, Chrome for Testing from Google with
// Playwright's CDN as a mirror) by SHA-256 and size.
//
// Usage: node scripts/watcher-runtime-manifest.mjs <output.json> <cache-dir>
// Fails the release if any mirror isn't publicly downloadable at the pinned size.
import { createHash } from "node:crypto";
import { createReadStream, existsSync, mkdirSync, readFileSync, statSync, writeFileSync, renameSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [output, cacheDir] = process.argv.slice(2);
if (!output || !cacheDir) {
  console.error("usage: watcher-runtime-manifest.mjs <output.json> <cache-dir>");
  process.exit(2);
}
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const nodeVersion = process.env.IBACALAO_NODE_VERSION ?? "v26.3.0";
const playwrightVersion = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).dependencies.playwright.replace(/^\^/, "");
mkdirSync(cacheDir, { recursive: true });

async function fetchTo(url, file) {
  if (existsSync(file)) return;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url} → HTTP ${res.status}`);
  writeFileSync(`${file}.tmp`, Buffer.from(await res.arrayBuffer()));
  renameSync(`${file}.tmp`, file);
}

function sha256(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash("sha256");
    createReadStream(file).on("data", (d) => hash.update(d)).on("end", () => resolve(hash.digest("hex"))).on("error", reject);
  });
}

async function publicSize(url) {
  // Anonymous request, same as a student's Mac. Redirects are followed.
  const head = await fetch(url, { method: "HEAD", redirect: "follow" });
  if (!head.ok) return -head.status;
  const length = Number(head.headers.get("content-length"));
  if (length > 0) return length;
  // Some registries (npm) omit Content-Length on HEAD: ask for one byte and
  // read the total from Content-Range, else download it (these are small).
  const ranged = await fetch(url, { headers: { Range: "bytes=0-0" }, redirect: "follow" });
  const total = /\/(\d+)$/.exec(ranged.headers.get("content-range") ?? "")?.[1];
  if (ranged.status === 206 && total) return Number(total);
  const full = await fetch(url, { redirect: "follow" });
  return full.ok ? (await full.arrayBuffer()).byteLength : -full.status;
}

async function pin(name, urls, cacheName, format, from, to, markers) {
  const file = join(cacheDir, cacheName);
  await fetchTo(urls[0], file);
  const size = statSync(file).size;
  for (const url of urls) {
    const remote = await publicSize(url);
    if (remote !== size) throw new Error(`${name}: ${url} is not publicly downloadable at ${size} bytes (got ${remote})`);
  }
  return { name, urls, sha256: await sha256(file), size, format, from, to, ...(markers ? { markers } : {}) };
}

// Chromium revision/version come from the exact playwright-core we pin.
const coreTgz = join(cacheDir, `playwright-core-${playwrightVersion}.tgz`);
await fetchTo(`https://registry.npmjs.org/playwright-core/-/playwright-core-${playwrightVersion}.tgz`, coreTgz);
const browsers = JSON.parse(execFileSync("/usr/bin/tar", ["-xzOf", coreTgz, "package/browsers.json"], { encoding: "utf8" })).browsers;
const chromium = browsers.find((b) => b.name === "chromium");
if (!chromium?.browserVersion || !chromium?.revision) throw new Error("playwright-core browsers.json has no chromium entry");
const chromeDir = `browsers/chromium-${chromium.revision}`;

const parts = [
  await pin("node", [`https://nodejs.org/dist/${nodeVersion}/node-${nodeVersion}-darwin-arm64.tar.gz`],
    `node-${nodeVersion}-darwin-arm64.tar.gz`, "tgz", `node-${nodeVersion}-darwin-arm64/bin/node`, "node/bin/node"),
  await pin("playwright", [`https://registry.npmjs.org/playwright/-/playwright-${playwrightVersion}.tgz`],
    `playwright-${playwrightVersion}.tgz`, "tgz", "package", "node_modules/playwright"),
  await pin("playwright-core", [`https://registry.npmjs.org/playwright-core/-/playwright-core-${playwrightVersion}.tgz`],
    `playwright-core-${playwrightVersion}.tgz`, "tgz", "package", "node_modules/playwright-core"),
  await pin("chromium", [
    `https://storage.googleapis.com/chrome-for-testing-public/${chromium.browserVersion}/mac-arm64/chrome-mac-arm64.zip`,
    `https://cdn.playwright.dev/builds/cft/${chromium.browserVersion}/mac-arm64/chrome-mac-arm64.zip`,
  ], `chrome-mac-arm64-${chromium.browserVersion}.zip`, "zip", ".", chromeDir,
    [`${chromeDir}/INSTALLATION_COMPLETE`, `${chromeDir}/DEPENDENCIES_VALIDATED`]),
];

// Same inputs → same key → students keep their runtime across app updates.
const digest = createHash("sha256").update(parts.map((p) => p.sha256).join("")).digest("hex").slice(0, 12);
const key = `node-${nodeVersion.replace(/^v/, "")}_pw-${playwrightVersion}_${digest}_arm64`;
mkdirSync(dirname(output), { recursive: true });
writeFileSync(output, `${JSON.stringify({ key, parts }, null, 2)}\n`);
const mb = (parts.reduce((n, p) => n + p.size, 0) / 1048576).toFixed(0);
console.log(`Watcher runtime manifest: ${key} (${parts.length} official downloads, ${mb} MB, all publicly reachable)`);
