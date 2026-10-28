#!/bin/bash
# Repackages the already-notarized+stapled .app into a Finder-styled DMG
# (custom background, icon positions, Applications shortcut). Does not
# re-sign or re-notarize — the app's staple ticket travels with it inside
# whatever DMG it ends up in.
set -euo pipefail
cd "$(dirname "$0")"

APP="../build/release/iBacalao.app"
BACKGROUND="background.png"
VOLNAME="iBacalao"
DMG_NAME="iBacalao-Digital-1.0.1-arm64.dmg"
OUT_DMG="../build/release/$DMG_NAME"

if [ ! -d "$APP" ]; then
  echo "ERROR: $APP not found — run release_digital.sh first."
  exit 1
fi
if [ ! -f "$BACKGROUND" ]; then
  echo "ERROR: $BACKGROUND not found — run compose_background.py first."
  exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/iBacalao.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$BACKGROUND" "$STAGE/.background/background.png"

RW_DMG=$(mktemp -u).dmg
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -fs HFS+ -format UDRW "$RW_DMG" >/dev/null

MOUNT_OUTPUT=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)
MOUNT_DIR=$(echo "$MOUNT_OUTPUT" | grep -E '^/dev/' | awk -F '\t' '{print $NF}' | tail -1)
echo "Mounted at: $MOUNT_DIR"

style_window() {
  osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 200 + 660, 120 + 460}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set background picture of viewOptions to file ".background:background.png"
    set position of item "iBacalao.app" of container window to {180, 230}
    set position of item "Applications" of container window to {480, 230}
    update without registering applications
  end tell
end tell
EOF
}

# Finder sometimes auto-fits the window back to content size on the first
# open of a fresh volume — apply the styling twice, with settle time, so the
# second pass overwrites whatever Finder computed on its own before .DS_Store
# actually persists it.
style_window
sleep 2
style_window
sleep 2

osascript -e "tell application \"Finder\" to close window \"$VOLNAME\""
sleep 1
sync
sleep 1

hdiutil detach "$MOUNT_DIR" >/dev/null
rm -f "$OUT_DMG"
hdiutil convert "$RW_DMG" -format UDZO -o "$OUT_DMG" >/dev/null
rm -f "$RW_DMG"
codesign --force --sign "Developer ID Application: WAWALABS COMPANY SAS (3826C72RFN)" --timestamp "$OUT_DMG" 2>/dev/null || true

SHA=$(shasum -a 256 "$OUT_DMG" | awk '{print $1}')
SIZE=$(stat -f%z "$OUT_DMG")
echo ""
echo "Styled DMG ready: $OUT_DMG"
echo "  SHA256: $SHA"
echo "  Size:   $SIZE bytes"
