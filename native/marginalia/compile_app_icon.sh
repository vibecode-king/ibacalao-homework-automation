#!/usr/bin/env bash
# Optional: compile AppIcon.icon → Assets.car for Liquid Glass (macOS 26).
#
# NOT used for shipping builds — Liquid Glass icons are recolored in Dock
# Tinted/Dark/Clear widget styles. Use ./build_fullcolor_app_icon.sh instead.
#
# Requires full Xcode 26+ (actool is not in Command Line Tools):
#   /Applications/Xcode.app/Contents/Developer/usr/bin/actool
#
# Usage: ./compile_app_icon.sh
set -euo pipefail
cd "$(dirname "$0")"

ICON_SOURCE="Sources/LiveExaminerOverlayCore/Resources/AppIcon.icon"
OUT_DIR="Sources/LiveExaminerOverlayCore/Resources"
ICON_NAME="AppIcon"

if [ ! -d "$ICON_SOURCE" ]; then
  echo "ERROR: missing $ICON_SOURCE" >&2
  exit 1
fi

ACTOOL=""
for candidate in \
  "/Applications/Xcode.app/Contents/Developer/usr/bin/actool" \
  "/Applications/Xcode-beta.app/Contents/Developer/usr/bin/actool"
do
  if [ -x "$candidate" ]; then
    ACTOOL="$candidate"
    break
  fi
done
if [ -z "$ACTOOL" ] && command -v xcrun >/dev/null 2>&1; then
  if xcrun --find actool >/dev/null 2>&1; then
    ACTOOL="$(xcrun --find actool)"
  fi
fi
if [ -z "$ACTOOL" ] || [ ! -x "$ACTOOL" ]; then
  echo "ERROR: actool not found. Install Xcode 26+ from the App Store, then re-run:" >&2
  echo "  ./compile_app_icon.sh" >&2
  exit 1
fi

# actool can fail on cloud-synced paths — compile from /tmp.
ICON_TMP="$(mktemp -d)/AppIcon.icon"
BUILD_TMP="$(mktemp -d)"
cleanup() { rm -rf "$(dirname "$ICON_TMP")" "$BUILD_TMP"; }
trap cleanup EXIT
cp -R "$ICON_SOURCE" "$ICON_TMP"

echo "Compiling Liquid Glass icon with: $ACTOOL"
"$ACTOOL" "$ICON_TMP" \
  --compile "$BUILD_TMP" \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --app-icon "$ICON_NAME" \
  --include-all-app-icons \
  --output-partial-info-plist "$BUILD_TMP/partial.plist"

if [ ! -f "$BUILD_TMP/Assets.car" ]; then
  echo "ERROR: actool did not produce Assets.car" >&2
  exit 1
fi

cp "$BUILD_TMP/Assets.car" "$OUT_DIR/Assets.car"
if [ -f "$BUILD_TMP/${ICON_NAME}.icns" ]; then
  cp "$BUILD_TMP/${ICON_NAME}.icns" "$OUT_DIR/AppIcon.icns"
fi

echo "Wrote $OUT_DIR/Assets.car"
ls -la "$OUT_DIR/Assets.car" "$OUT_DIR/AppIcon.icns"
