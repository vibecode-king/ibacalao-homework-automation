#!/usr/bin/env bash
# Bake the fixed-color Dock PNG and matching legacy .icns fallback.
# The Dock PNG is also embedded in the docktileplugin and bypasses Tahoe tinting.
# Liquid Glass Assets.car is checked in separately and is not regenerated here.
set -euo pipefail
cd "$(dirname "$0")"

RES="Sources/LiveExaminerOverlayCore/Resources"
SRC="$RES/AppIcon-1024.png"
DOCK="$RES/AppIconDock.png"
ICONSET="$RES/AppIcon.iconset"
OUT="$RES/AppIcon.icns"

if [ ! -f "$SRC" ]; then
  echo "ERROR: missing $SRC" >&2
  exit 1
fi

python3 ./bake_macos_icon.py "$SRC" "$DOCK"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16 "$DOCK" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$DOCK" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$DOCK" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$DOCK" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$DOCK" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$DOCK" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$DOCK" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$DOCK" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$DOCK" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$DOCK" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"

echo "Wrote $DOCK and $OUT"
