#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:?output directory required}"
ESBUILD="$ROOT_DIR/node_modules/.bin/esbuild"
if [ ! -x "$ESBUILD" ]; then ESBUILD="$ROOT_DIR/node_modules/esbuild/bin/esbuild"; fi
if [ ! -x "$ESBUILD" ]; then echo "ERROR: esbuild is not installed." >&2; exit 1; fi
mkdir -p "$OUTPUT_DIR"
"$ESBUILD" "$ROOT_DIR/src/pair.ts" --bundle --platform=node --format=cjs --target=node22 --outfile="$OUTPUT_DIR/homework-pair.cjs"
"$ESBUILD" "$ROOT_DIR/src/ping.ts" --bundle --platform=node --format=cjs --target=node22 --outfile="$OUTPUT_DIR/homework-worker.cjs"
"$ESBUILD" "$ROOT_DIR/scripts/setup-homework-worker.ts" --bundle --platform=node --format=cjs --target=node22 --outfile="$OUTPUT_DIR/homework-setup.cjs"
