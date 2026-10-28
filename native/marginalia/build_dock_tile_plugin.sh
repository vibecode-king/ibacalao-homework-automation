#!/usr/bin/env bash
# Build Contents/PlugIns/iBacalaoDockTile.docktileplugin (custom Dock art when quit).
set -euo pipefail
cd "$(dirname "$0")"

PLUGIN_SRC="Sources/DockTilePlugin/DockTilePlugin.swift"
PLUGIN_PLIST="Sources/DockTilePlugin/Info.plist"
DOCK_PNG="Sources/LiveExaminerOverlayCore/Resources/AppIconDock.png"
OUT="${1:-iBacalao.app/Contents/PlugIns/iBacalaoDockTile.docktileplugin}"

if [ ! -f "$PLUGIN_SRC" ]; then
  echo "ERROR: missing $PLUGIN_SRC" >&2
  exit 1
fi
if [ ! -f "$DOCK_PNG" ]; then
  echo "ERROR: missing $DOCK_PNG — bake the dock PNG first" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$PLUGIN_PLIST" "$OUT/Contents/Info.plist"
cp "$DOCK_PNG" "$OUT/Contents/Resources/AppIconDock.png"

SDK="$(xcrun --show-sdk-path)"
swiftc -parse-as-library \
  -emit-library \
  -module-name iBacalaoDockTile \
  -sdk "$SDK" \
  -target arm64-apple-macos14 \
  -framework AppKit \
  -Xlinker -bundle \
  -o "$OUT/Contents/MacOS/iBacalaoDockTile" \
  "$PLUGIN_SRC"

echo "Wrote $OUT"
