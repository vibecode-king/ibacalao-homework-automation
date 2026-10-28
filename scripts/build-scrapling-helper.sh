#!/bin/bash
# Build the self-contained, parser-only Scrapling helper (our own PyInstaller
# binary). Shipped signed inside the Mac app; the public runtime pieces
# (Node/Playwright/Chromium) are downloaded by the app after install.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:?usage: build-scrapling-helper.sh <output-directory>}"
SCRAPLING_VERSION="${IBACALAO_SCRAPLING_VERSION:-0.4.15}"
PYINSTALLER_VERSION="${IBACALAO_PYINSTALLER_VERSION:-6.22.2}"
if [ -n "${IBACALAO_PYTHON_BIN:-}" ]; then
  PYTHON_BIN="$IBACALAO_PYTHON_BIN"
elif command -v python3.12 >/dev/null 2>&1; then
  # Python 3.14 PyInstaller one-file bundles have a ~17s cold start on the
  # release Mac, which exceeds the watcher's 12s production helper budget.
  # Python 3.12 produces the same arm64 helper with a ~1s cold start.
  PYTHON_BIN="python3.12"
elif command -v python3.11 >/dev/null 2>&1; then
  PYTHON_BIN="python3.11"
else
  PYTHON_BIN="python3"
fi
mkdir -p "$OUTPUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Building self-contained Scrapling parser helper"
echo "==> Python runtime: $($PYTHON_BIN --version 2>&1)"
SCRAPLING_BUILD="$TMP_DIR/scrapling-build"
"$PYTHON_BIN" -m venv --without-pip "$SCRAPLING_BUILD/venv"
"$PYTHON_BIN" -m pip --python "$SCRAPLING_BUILD/venv/bin/python" install \
  --disable-pip-version-check --quiet \
  "scrapling==${SCRAPLING_VERSION}" "pyinstaller==${PYINSTALLER_VERSION}"
"$SCRAPLING_BUILD/venv/bin/python" -m PyInstaller \
  --onefile --clean --noconfirm \
  --name scrapling-repair \
  --distpath "$OUTPUT_DIR" \
  --workpath "$SCRAPLING_BUILD/work" \
  --specpath "$SCRAPLING_BUILD/spec" \
  "$ROOT_DIR/tools/scrapling-repair/scrapling_repair.py"
chmod +x "$OUTPUT_DIR/scrapling-repair"
if ! file "$OUTPUT_DIR/scrapling-repair" | grep -q "arm64"; then
  echo "ERROR: Scrapling helper is not arm64." >&2
  exit 1
fi
SCRAPLING_SMOKE='{"operation":"signature","currentHtml":"<main><ibacalao-card data-capture-id=\"c0\"><article class=\"assignment\"><h3>Biology assignment</h3></article></ibacalao-card></main>","currentUrl":"https://school.example/assignments","captureId":"c0"}'
# Match lib/school/scraplingSidecar.ts's production cold-start budget. Packaging
# used to wait forever here while the shipped watcher killed the same healthy
# helper after 3 seconds, so a green package smoke did not prove runtime use.
if ! SCRAPLING_HELPER="$OUTPUT_DIR/scrapling-repair" SCRAPLING_SMOKE="$SCRAPLING_SMOKE" python3 - <<'PYSMOKE'
import os
import subprocess
import sys

try:
    result = subprocess.run(
        [os.environ["SCRAPLING_HELPER"]],
        input=os.environ["SCRAPLING_SMOKE"] + "\n",
        text=True,
        capture_output=True,
        timeout=12,
        check=False,
    )
except subprocess.TimeoutExpired:
    sys.exit(1)
sys.exit(0 if result.returncode == 0 and '"ok":true' in result.stdout else 1)
PYSMOKE
then
  echo "ERROR: bundled Scrapling helper failed its parser-only smoke test inside the 12s runtime budget." >&2
  exit 1
fi
