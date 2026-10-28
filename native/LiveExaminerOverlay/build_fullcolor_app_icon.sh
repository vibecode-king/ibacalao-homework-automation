#!/usr/bin/env bash
# Bake the mobile-style green+black mark into AppIcon.icns for all Dock appearances.
#
# macOS 26 "Icon & widget style" (Tinted / Dark / Clear) recolors Liquid Glass
# icons shipped via Assets.car + CFBundleIconName. Legacy full-color .icns only
# (CFBundleIconFile) keeps brand colors — same approach as Hermes / Electron apps.
#
# Usage: ./build_fullcolor_app_icon.sh
set -euo pipefail
cd "$(dirname "$0")"

RES="Sources/LiveExaminerOverlayCore/Resources"
SRC="$RES/AppIcon-1024.png"
ICONSET="$RES/AppIcon.iconset"
OUT="$RES/AppIcon.icns"

if [ ! -f "$SRC" ]; then
  echo "ERROR: missing $SRC" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

sips -z 16 16 "$SRC" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SRC" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$SRC" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "Wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
