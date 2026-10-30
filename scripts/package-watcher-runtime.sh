#!/bin/bash
# Build a hermetic macOS-arm64 school watcher runtime for the native DMG.
# Runtime output contains its own Node binary, Playwright JS package, Chromium,
# bundled watcher-daemon.cjs, and a self-contained parser-only Scrapling helper.
# The installed Mac needs no Node/npm/Python/tools.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:?usage: package-watcher-runtime.sh <output-directory>}"
NODE_VERSION="${IBACALAO_NODE_VERSION:-v26.3.0}"
NODE_ARCHIVE="node-${NODE_VERSION}-darwin-arm64.tar.gz"
NODE_URL="https://nodejs.org/dist/${NODE_VERSION}/${NODE_ARCHIVE}"

mkdir -p "$OUTPUT_DIR"
rm -rf "$OUTPUT_DIR"/*
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Bundling watcher JavaScript"
npx --no-install esbuild "$ROOT_DIR/scripts/watcher-daemon.ts" \
  --bundle \
  --platform=node \
  --format=cjs \
  --target=node22 \
  --external:playwright \
  --outfile="$OUTPUT_DIR/watcher-daemon.cjs"
bash "$ROOT_DIR/scripts/bundle-homework-worker.sh" "$OUTPUT_DIR"

"$ROOT_DIR/scripts/build-scrapling-helper.sh" "$OUTPUT_DIR"

echo "==> Bundling official Node ${NODE_VERSION} arm64 runtime"
curl --fail --location --silent --show-error "$NODE_URL" -o "$TMP_DIR/$NODE_ARCHIVE"
tar -xzf "$TMP_DIR/$NODE_ARCHIVE" -C "$TMP_DIR"
mv "$TMP_DIR/node-${NODE_VERSION}-darwin-arm64" "$OUTPUT_DIR/node"

PLAYWRIGHT_VERSION="$(node -e 'process.stdout.write(require(process.argv[1]).dependencies.playwright.replace(/^\^/, ""))' "$ROOT_DIR/package.json")"
cat > "$OUTPUT_DIR/package.json" <<EOF
{"private":true,"dependencies":{"playwright":"${PLAYWRIGHT_VERSION}"}}
EOF

echo "==> Bundling Playwright ${PLAYWRIGHT_VERSION}"
"$OUTPUT_DIR/node/bin/node" "$OUTPUT_DIR/node/lib/node_modules/npm/bin/npm-cli.js" install \
  --prefix "$OUTPUT_DIR" \
  --omit=dev \
  --ignore-scripts \
  --no-audit \
  --no-fund \
  --package-lock=false \
  --silent

# Playwright declares fsevents as an optional dependency. The watcher daemon
# does not use it, and shipping its unused native universal binary adds another
# code-signing/notarization surface for no runtime benefit.
rm -rf "$OUTPUT_DIR/node_modules/fsevents"

echo "==> Bundling Chromium"
PLAYWRIGHT_BROWSERS_PATH="$OUTPUT_DIR/browsers" \
  "$OUTPUT_DIR/node/bin/node" "$OUTPUT_DIR/node_modules/playwright/cli.js" install chromium --no-shell

# npm is needed only while constructing the runtime. The installed app needs
# the Node executable itself, not npm, headers, docs, Corepack, or man pages.
find "$OUTPUT_DIR/node/bin" -mindepth 1 -maxdepth 1 ! -name node -exec rm -rf {} +
rm -rf "$OUTPUT_DIR/node/include" "$OUTPUT_DIR/node/lib" "$OUTPUT_DIR/node/share"

rm -f "$OUTPUT_DIR/package.json"
echo "==> Watcher runtime ready: $OUTPUT_DIR"
