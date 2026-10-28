#!/bin/bash
# Release pipeline for the canonical native source tree.
#
# A public build is only published after Developer ID signing, Apple
# notarization, stapling, and Gatekeeper verification. --skip-notary is a
# local-only packaging mode and never changes the dist directory.
set -euo pipefail

cd "$(dirname "$0")"

ROOT_DIR="$(cd ../.. && pwd)"
VERSION_FILE="$ROOT_DIR/release-version.json"
VERSION="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' "$VERSION_FILE")"
BUILD="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).build)' "$VERSION_FILE")"
BUNDLE_ID="com.ibacalao.LiveExaminerOverlay"
APP_NAME="iBacalao"
STAGING="build/release"
APP="$STAGING/${APP_NAME}.app"
DMG_NAME="iBacalao-Digital-${VERSION}-arm64.dmg"
DMG_PATH="$STAGING/$DMG_NAME"
DIST_DIR="${IB_DIST_DIR:-$ROOT_DIR/dist/digital}"
LATEST_JSON="$DIST_DIR/latest.json"
ENTITLEMENTS_RELEASE="Entitlements-Release.plist"
ENTITLEMENTS_NODE="Entitlements-Node.plist"
SKIP_NOTARY=0
NOTARY_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"

if [[ "${1:-}" == "--skip-notary" ]]; then
  SKIP_NOTARY=1
fi

set_plist_value() {
  local key="$1" value="$2" plist="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" >/dev/null
}

resolve_developer_id() {
  local line identity
  line=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" \
    | grep -v "CSSMERR_TP_CERT_REVOKED" \
    | head -1 || true)
  if [ -z "$line" ]; then
    echo "ERROR: No trusted Developer ID Application identity is available." >&2
    echo "Install/trust the WawaLabs Developer ID certificate, then rerun this release." >&2
    exit 1
  fi
  identity=$(echo "$line" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[A-F0-9]+[[:space:]]+"([^"]+)".*/\1/')
  if [ -z "$identity" ] || [ "$identity" = "$line" ]; then
    echo "ERROR: Could not parse the Developer ID identity." >&2
    exit 1
  fi
  echo "$identity"
}

echo "==> Checking release version"
node "$ROOT_DIR/scripts/check-release-version.cjs"

echo "==> Building canonical native source (native/marginalia)"
swift build -c release

BINARY=".build/release/LiveExaminerOverlay"
BRIDGE_BINARY=".build/release/iBacalaoSchoolBridge"
if [ ! -f "$BINARY" ]; then
  echo "ERROR: Missing $BINARY" >&2
  exit 1
fi
if [ ! -f "$BRIDGE_BINARY" ]; then
  echo "ERROR: Missing $BRIDGE_BINARY" >&2
  exit 1
fi
if [ ! -f "$ENTITLEMENTS_RELEASE" ]; then
  echo "ERROR: Missing $ENTITLEMENTS_RELEASE" >&2
  exit 1
fi
if [ ! -f "$ENTITLEMENTS_NODE" ]; then
  echo "ERROR: Missing $ENTITLEMENTS_NODE" >&2
  exit 1
fi
if grep -rq "Bundle\.module" Sources/; then
  echo "ERROR: Bundle.module referenced in Sources; shipped app would crash without its SPM resource bundle." >&2
  exit 1
fi

IDENTITY="$(resolve_developer_id)"
echo "==> Signing identity: $IDENTITY"

rm -rf "$STAGING"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/iBacalao"
chmod +x "$APP/Contents/MacOS/iBacalao"
cp "$BRIDGE_BINARY" "$APP/Contents/MacOS/iBacalaoSchoolBridge"
chmod +x "$APP/Contents/MacOS/iBacalaoSchoolBridge"
cp Info.plist "$APP/Contents/Info.plist"
set_plist_value CFBundleExecutable iBacalao "$APP/Contents/Info.plist"
set_plist_value CFBundleIdentifier "$BUNDLE_ID" "$APP/Contents/Info.plist"
set_plist_value CFBundleShortVersionString "$VERSION" "$APP/Contents/Info.plist"
set_plist_value CFBundleVersion "$BUILD" "$APP/Contents/Info.plist"

# Marginalia is the canonical code tree. The checked-in wordmark asset still
# lives with the old Xcode shell, so use that asset only until it is moved into
# this tree; never use the old tree's executable or Swift sources.
LOGO_SOURCE="Sources/LiveExaminerOverlayCore/Resources/logo.png"
if [ ! -f "$LOGO_SOURCE" ] && [ -f "$ROOT_DIR/native/LiveExaminerOverlay/Sources/LiveExaminerOverlayCore/Resources/logo.png" ]; then
  LOGO_SOURCE="$ROOT_DIR/native/LiveExaminerOverlay/Sources/LiveExaminerOverlayCore/Resources/logo.png"
fi
if [ -f "$LOGO_SOURCE" ]; then
  cp "$LOGO_SOURCE" "$APP/Contents/Resources/logo.png"
else
  echo "WARNING: logo.png is unavailable; native BrandLogo will use its text fallback." >&2
fi
for asset in launch-bg.png launch-bg-wide.png; do
  if [ -f "Sources/LiveExaminerOverlayCore/Resources/$asset" ]; then
    cp "Sources/LiveExaminerOverlayCore/Resources/$asset" "$APP/Contents/Resources/$asset"
  fi
done
for asset in Sources/LiveExaminerOverlayCore/Resources/tool-*; do
  if [ -f "$asset" ]; then cp "$asset" "$APP/Contents/Resources/$(basename "$asset")"; fi
done

# The heavy runtime (Node, Playwright, Chromium; ~230 MB) is not shipped in
# the DMG and not hosted by iBacalao. The app downloads each piece from its
# official public source after install (WatcherRuntimeInstaller.swift), pinned
# by runtime-manifest.json inside this signed bundle. Only our own small pieces
# ship in the app: the watcher script and the Scrapling parser helper.
# Absolute on purpose: a relative path here plus the `cd` below once shipped a
# stale daemon into the wrong app (2026-09-14 crash-loop incident).
WATCHER_RUNTIME="$PWD/$APP/Contents/Resources/WatcherRuntime"
mkdir -p "$WATCHER_RUNTIME"

ESBUILD_BIN="$ROOT_DIR/node_modules/.bin/esbuild"
if [ ! -x "$ESBUILD_BIN" ]; then
  ESBUILD_BIN="$ROOT_DIR/node_modules/esbuild/bin/esbuild"
fi
if [ ! -x "$ESBUILD_BIN" ]; then
  echo "ERROR: esbuild is not installed. Run npm install before releasing." >&2
  exit 1
fi

echo "==> Bundling watcher script into the app"
(
  cd "$ROOT_DIR"
  "$ESBUILD_BIN" scripts/watcher-daemon.ts \
    --bundle --platform=node --format=cjs --target=node22 \
    --external:playwright \
    --outfile="$WATCHER_RUNTIME/watcher-daemon.cjs"
)

echo "==> Building Scrapling parser helper into the app"
"$ROOT_DIR/scripts/build-scrapling-helper.sh" "$WATCHER_RUNTIME"
codesign --force --options runtime --sign "$IDENTITY" --timestamp "$WATCHER_RUNTIME/scrapling-repair"

echo "==> Pinning official runtime downloads"
node "$ROOT_DIR/scripts/watcher-runtime-manifest.mjs" "$WATCHER_RUNTIME/runtime-manifest.json" "$PWD/build/runtime-cache/src"

echo "==> Signing app"
codesign --force --options runtime \
  --sign "$IDENTITY" \
  --timestamp \
  "$APP/Contents/MacOS/iBacalaoSchoolBridge"
codesign --force --options runtime \
  --sign "$IDENTITY" \
  --identifier "$BUNDLE_ID" \
  --entitlements "$ENTITLEMENTS_RELEASE" \
  --timestamp \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$SKIP_NOTARY" = "0" ]; then
  if ! command -v xcrun >/dev/null || ! xcrun notarytool --help >/dev/null 2>&1; then
    echo "ERROR: xcrun notarytool is unavailable; open Xcode once and retry." >&2
    exit 1
  fi

  ZIP="$STAGING/${APP_NAME}-${VERSION}.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> Submitting to Apple notarization"
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    : "${ASC_KEY_ID:?Set ASC_KEY_ID or NOTARYTOOL_KEYCHAIN_PROFILE}"
    : "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID or NOTARYTOOL_KEYCHAIN_PROFILE}"
    : "${ASC_KEY_PATH:?Set ASC_KEY_PATH or NOTARYTOOL_KEYCHAIN_PROFILE}"
    if [ ! -f "$ASC_KEY_PATH" ]; then
      echo "ERROR: ASC_KEY_PATH does not point to a file." >&2
      exit 1
    fi
    xcrun notarytool submit "$ZIP" \
      --key "$ASC_KEY_PATH" \
      --key-id "$ASC_KEY_ID" \
      --issuer "$ASC_ISSUER_ID" \
      --wait
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
else
  echo "==> Notarization skipped; local artifact will stay out of the dist directory"
fi

echo "==> Building DMG"
rm -f "$DMG_PATH"
hdiutil create -volname "iBacalao Digital" -srcfolder "$APP" -ov -format UDZO "$DMG_PATH"
codesign --force --sign "$IDENTITY" --timestamp "$DMG_PATH"

if [ "$SKIP_NOTARY" = "0" ]; then
  echo "==> Submitting final DMG to Apple notarization"
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$DMG_PATH" \
      --key "$ASC_KEY_PATH" \
      --key-id "$ASC_KEY_ID" \
      --issuer "$ASC_ISSUER_ID" \
      --wait
  fi
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
  hdiutil verify "$DMG_PATH"
fi

# Stapling changes the final artifact bytes, so calculate release metadata only
# after the DMG carries and validates its notarization ticket.
SHA="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
SIZE="$(stat -f%z "$DMG_PATH")"
RELEASED="$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")"

if [ "$SKIP_NOTARY" = "0" ]; then
  mkdir -p "$DIST_DIR"
  cp "$DMG_PATH" "$DIST_DIR/$DMG_NAME"
  node - "$LATEST_JSON" "$VERSION" "$DMG_NAME" "$SHA" "$SIZE" "$RELEASED" <<'NODE'
const fs = require("fs");

const [latestPath, version, fileName, sha256, sizeBytes, releasedAt] = process.argv.slice(2);
let latest = { product: "digital", platforms: {} };

if (fs.existsSync(latestPath)) {
  latest = JSON.parse(fs.readFileSync(latestPath, "utf8"));
}

latest.product = "digital";
latest.platforms ||= {};
latest.platforms["macos-arm64"] = {
  version,
  minimumOs: "macOS 14",
  fileName,
  url: `/downloads/digital/${fileName}`,
  sha256,
  sizeBytes: Number(sizeBytes),
  releasedAt,
};

fs.writeFileSync(latestPath, `${JSON.stringify(latest, null, 2)}\n`);
NODE
  echo "Release ready: $DIST_DIR/$DMG_NAME"
  echo "SHA-256: $SHA"
else
  echo "Local artifact ready: $DMG_PATH"
  echo "SHA-256: $SHA"
fi
