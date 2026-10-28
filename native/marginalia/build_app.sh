#!/bin/bash
# Packages the SwiftPM executable into a real .app bundle. Without this, macOS
# has no stable bundle identity to attach Screen Recording grants to, so TCC
# re-prompts after every rebuild when signed ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

ROOT_DIR="$(cd ../.. && pwd)"
RELEASE_VERSION="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version)' "$ROOT_DIR/release-version.json")"
RELEASE_BUILD="$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).build)' "$ROOT_DIR/release-version.json")"

apply_bundle_metadata() {
  local plist="$1"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable iBacalao" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.ibacalao.LiveExaminerOverlay" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_BUILD" "$plist"
}

IDENTITY_NAME="LiveExaminer Overlay"
BUNDLE_ID="com.ibacalao.LiveExaminerOverlay"
LEO_KEYCHAIN="${HOME}/Library/Keychains/LiveExaminer.keychain-db"
# Password lives in a local, gitignored file (see setup_codesign.sh) — never
# hardcoded in a script that gets committed.
LEO_KEYCHAIN_PASSWORD_FILE="$(dirname "$0")/.leo_keychain_password"
if [ ! -f "$LEO_KEYCHAIN_PASSWORD_FILE" ]; then
  # Git worktrees do not copy ignored local files. Reuse the canonical checkout's
  # signing secret when this script is running from a worktree, without copying
  # the secret into the worktree or printing it.
  GIT_COMMON_DIR="$(git -C "$ROOT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$GIT_COMMON_DIR" ]; then
    CANONICAL_PASSWORD_FILE="$(dirname "$GIT_COMMON_DIR")/native/marginalia/.leo_keychain_password"
    if [ -f "$CANONICAL_PASSWORD_FILE" ]; then
      LEO_KEYCHAIN_PASSWORD_FILE="$CANONICAL_PASSWORD_FILE"
    fi
  fi
fi
LEO_KEYCHAIN_PASSWORD="$(cat "$LEO_KEYCHAIN_PASSWORD_FILE" 2>/dev/null || true)"

prepare_signing_keychain() {
  if [ -f "$LEO_KEYCHAIN" ]; then
    security list-keychains -d user -s "$LEO_KEYCHAIN" "${HOME}/Library/Keychains/login.keychain-db"
    security unlock-keychain -p "$LEO_KEYCHAIN_PASSWORD" "$LEO_KEYCHAIN" >/dev/null 2>&1 || true
  fi
}

codesign_identity_works() {
  local tmp app ent
  tmp=$(mktemp -d)
  app="$tmp/TestSign.app"
  ent="$tmp/ent.plist"
  mkdir -p "$app/Contents/MacOS"
  echo '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$app/Contents/Info.plist"
  echo '#!/bin/sh' > "$app/Contents/MacOS/TestSign"
  chmod +x "$app/Contents/MacOS/TestSign"
  cat > "$ent" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
EOF
  prepare_signing_keychain
  if ! codesign --force --sign "$IDENTITY_NAME" --entitlements "$ent" "$app" >/dev/null 2>&1; then
    rm -rf "$tmp"
    return 1
  fi
  if codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  return 0
}

# Returns: valid | untrusted | missing
resolve_sign_state() {
  prepare_signing_keychain
  if security find-identity -v -p codesigning 2>/dev/null \
    | grep "$IDENTITY_NAME" \
    | grep -qv "NOT_TRUSTED"; then
    echo "valid"
    return 0
  fi
  if security find-certificate -c "$IDENTITY_NAME" >/dev/null 2>&1; then
    if codesign_identity_works; then
      echo "valid"
      return 0
    fi
    echo "untrusted"
    return 0
  fi
  echo "missing"
}

resolve_sign_identity() {
  prepare_signing_keychain
  local from_list
  from_list=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "$IDENTITY_NAME" \
    | grep -v "NOT_TRUSTED" \
    | head -1 \
    | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+[A-F0-9]+[[:space:]]+"([^"]+)".*/\1/' || true)
  if [ -n "$from_list" ]; then
    echo "$from_list"
    return 0
  fi
  if codesign_identity_works; then
    echo "$IDENTITY_NAME"
  fi
}

sign_app_bundle() {
  local app="$1"
  local identity="$2"
  codesign --force --deep --sign "$identity" \
    --identifier "$BUNDLE_ID" \
    --entitlements "$ENTITLEMENTS" \
    "$app"
}

print_untrusted_help() {
  echo ""
  echo "ERROR: Certificate \"$IDENTITY_NAME\" exists but is NOT trusted for Code Signing."
  echo "Ad-hoc signing was NOT used — that would reset Screen Recording every rebuild."
  echo ""
  echo "Fix ONCE (Keychain Access):"
  echo "  1. Open Keychain Access → login → Certificates"
  echo "  2. Double-click \"$IDENTITY_NAME\""
  echo "  3. Trust → Code Signing → Always Trust → close (enter password)"
  echo "  4. Re-run: ./setup_codesign.sh && ./build_app.sh"
  echo ""
}

print_missing_help() {
  echo ""
  echo "ERROR: No Code Signing identity for \"$IDENTITY_NAME\"."
  echo "Ad-hoc signing was NOT used — Screen Recording would not stick across rebuilds."
  echo ""
  echo "Fix ONCE: ./setup_codesign.sh"
  echo "Then trust the cert in Keychain Access (see setup_codesign.sh output)."
  echo ""
  echo "Emergency dev-only ad-hoc (TCC will re-prompt): ALLOW_ADHOC=1 ./build_app.sh"
  echo ""
}

swift build -c debug

prepare_signing_keychain

APP="iBacalao.app"
INSTALL_APP="/Applications/iBacalao.app"
BINARY=".build/debug/LiveExaminerOverlay"
BRIDGE_BINARY=".build/debug/iBacalaoSchoolBridge"
WATCHER_RUNTIME="$(pwd)/$APP/Contents/Resources/WatcherRuntime"
# SwiftPM doesn't emit a usable entitlements plist for executables, so this
# uses the checked-in, non-sandboxed DirectDMG entitlements (same file the
# Xcode DirectDMG target references) instead of a `swift build` artifact.
# Override with LEO_ENTITLEMENTS=/path/to/file.plist if needed.
ENTITLEMENTS="${LEO_ENTITLEMENTS:-Entitlements-Release.plist}"
LEGACY_INSTALL_APP="/Applications/LiveExaminerOverlay.app"

if [ ! -f "$ENTITLEMENTS" ]; then
  echo "ERROR: Entitlements not found at $ENTITLEMENTS"
  exit 1
fi

# Prefer updating an existing bundle in place so TCC keeps the same path/inode
# association. Only create from scratch when missing.
if [ ! -d "$APP" ]; then
  mkdir -p "$APP/Contents/MacOS"
fi
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
# Install executable as iBacalao so Dock/Finder name matches (not LiveExaminerOverlay).
cp "$BINARY" "$APP/Contents/MacOS/iBacalao"
chmod +x "$APP/Contents/MacOS/iBacalao"
cp "$BRIDGE_BINARY" "$APP/Contents/MacOS/iBacalaoSchoolBridge"
chmod +x "$APP/Contents/MacOS/iBacalaoSchoolBridge"
rm -f "$APP/Contents/MacOS/LiveExaminerOverlay"
cp Info.plist "$APP/Contents/Info.plist"
apply_bundle_metadata "$APP/Contents/Info.plist"

# Keep the local DEV app on the exact watcher source that was just built. The
# runtime is large (Node + Playwright + Chromium), so reuse an existing runtime
# when possible and refresh only the bundled daemon. On a clean Mac, fall back
# to constructing the hermetic runtime once.
if [ ! -x "$WATCHER_RUNTIME/node/bin/node" ] || [ ! -d "$WATCHER_RUNTIME/node_modules/playwright" ]; then
  INSTALLED_WATCHER_RUNTIME="$INSTALL_APP/Contents/Resources/WatcherRuntime"
  if [ -x "$INSTALLED_WATCHER_RUNTIME/node/bin/node" ] && [ -d "$INSTALLED_WATCHER_RUNTIME/node_modules/playwright" ]; then
    echo "==> Reusing installed WatcherRuntime for DEV build"
    rm -rf "$WATCHER_RUNTIME"
    cp -R "$INSTALLED_WATCHER_RUNTIME" "$WATCHER_RUNTIME"
  else
    echo "==> Building WatcherRuntime for DEV app"
    "$ROOT_DIR/scripts/package-watcher-runtime.sh" "$WATCHER_RUNTIME"
  fi
fi

echo "==> Refreshing bundled school watcher daemon"
(
  cd "$ROOT_DIR"
  npx --no-install esbuild scripts/watcher-daemon.ts \
    --bundle \
    --platform=node \
    --format=cjs \
    --target=node22 \
    --external:playwright \
    --outfile="$WATCHER_RUNTIME/watcher-daemon.cjs"
)

if [ -f "Sources/LiveExaminerOverlayCore/Resources/logo.png" ]; then
  cp "Sources/LiveExaminerOverlayCore/Resources/logo.png" "$APP/Contents/Resources/logo.png"
fi
if [ -f "Sources/LiveExaminerOverlayCore/Resources/launch-bg.png" ]; then
  cp "Sources/LiveExaminerOverlayCore/Resources/launch-bg.png" "$APP/Contents/Resources/launch-bg.png"
fi
if [ -f "Sources/LiveExaminerOverlayCore/Resources/launch-bg-wide.png" ]; then
  cp "Sources/LiveExaminerOverlayCore/Resources/launch-bg-wide.png" "$APP/Contents/Resources/launch-bg-wide.png"
fi
for asset in Sources/LiveExaminerOverlayCore/Resources/tool-*; do
  if [ -f "$asset" ]; then cp "$asset" "$APP/Contents/Resources/$(basename "$asset")"; fi
done
# Finder/App Switcher use the checked-in Liquid Glass Assets.car. Dock uses a
# fixed-color PNG via contentView + docktileplugin so Tinted cannot recolor it.
if [ -x "./build_fullcolor_app_icon.sh" ]; then
  ./build_fullcolor_app_icon.sh
fi
if [ -f "Sources/LiveExaminerOverlayCore/Resources/Assets.car" ]; then
  cp "Sources/LiveExaminerOverlayCore/Resources/Assets.car" "$APP/Contents/Resources/Assets.car"
fi
if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" ]; then
  cp "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIconDock.png" ]; then
  cp "Sources/LiveExaminerOverlayCore/Resources/AppIconDock.png" "$APP/Contents/Resources/AppIconDock.png"
fi
chmod +x ./build_dock_tile_plugin.sh
./build_dock_tile_plugin.sh "$APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin"
rm -f "$APP/Contents/Resources/AppIconV4.icns"

SIGN_STATE=$(resolve_sign_state)
SIGN_IDENTITY=""

case "$SIGN_STATE" in
  valid)
    SIGN_IDENTITY=$(resolve_sign_identity)
    if [ -z "$SIGN_IDENTITY" ]; then
      echo "ERROR: Identity lookup failed despite valid state."
      exit 1
    fi
    sign_app_bundle "$APP" "$SIGN_IDENTITY"
    echo "Signed with: $SIGN_IDENTITY"
    ;;
  untrusted)
    if [ "${ALLOW_ADHOC:-}" = "1" ]; then
      codesign --force --deep --sign - \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP"
      SIGN_IDENTITY="-"
      echo "WARNING: Ad-hoc signed (ALLOW_ADHOC=1, cert untrusted). Trust cert for stable TCC."
    else
      print_untrusted_help
      exit 1
    fi
    ;;
  missing)
    if [ "${ALLOW_ADHOC:-}" = "1" ]; then
      codesign --force --deep --sign - \
        --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" \
        "$APP"
      SIGN_IDENTITY="-"
      echo "WARNING: Ad-hoc signed (ALLOW_ADHOC=1). Screen Recording will NOT stick."
    else
      print_missing_help
      exit 1
    fi
    ;;
esac

# Install under /Applications — update Contents in place (never rm -rf) so TCC
# path/inode association survives rebuilds.
install_to_applications() {
  if [ "$SIGN_IDENTITY" = "-" ] && [ -d "$INSTALL_APP" ]; then
    echo ""
    echo "REFUSED: Will not ad-hoc re-sign $INSTALL_APP — that invalidates your Screen Recording grant."
    echo "Built locally at $APP only."
    echo ""
    echo "Launch existing grant: ./launch_app.sh"
    echo "Or remove $INSTALL_APP first if you accept losing the grant."
    SKIPPED_INSTALL=1
    return 0
  fi

  if [ -d "$INSTALL_APP" ]; then
    cp "$BINARY" "$INSTALL_APP/Contents/MacOS/iBacalao"
    chmod +x "$INSTALL_APP/Contents/MacOS/iBacalao"
    cp "$BRIDGE_BINARY" "$INSTALL_APP/Contents/MacOS/iBacalaoSchoolBridge"
    chmod +x "$INSTALL_APP/Contents/MacOS/iBacalaoSchoolBridge"
    rm -f "$INSTALL_APP/Contents/MacOS/LiveExaminerOverlay"
    cp Info.plist "$INSTALL_APP/Contents/Info.plist"
    apply_bundle_metadata "$INSTALL_APP/Contents/Info.plist"
    mkdir -p "$INSTALL_APP/Contents/Resources"
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/logo.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/logo.png" "$INSTALL_APP/Contents/Resources/logo.png"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/launch-bg.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/launch-bg.png" "$INSTALL_APP/Contents/Resources/launch-bg.png"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/launch-bg-wide.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/launch-bg-wide.png" "$INSTALL_APP/Contents/Resources/launch-bg-wide.png"
    fi
    for asset in Sources/LiveExaminerOverlayCore/Resources/tool-*; do
      if [ -f "$asset" ]; then cp "$asset" "$INSTALL_APP/Contents/Resources/$(basename "$asset")"; fi
    done
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/Assets.car" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/Assets.car" "$INSTALL_APP/Contents/Resources/Assets.car"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" "$INSTALL_APP/Contents/Resources/AppIcon.icns"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIconDock.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/AppIconDock.png" "$INSTALL_APP/Contents/Resources/AppIconDock.png"
    fi
    mkdir -p "$INSTALL_APP/Contents/PlugIns"
    rm -rf "$INSTALL_APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin"
    if [ -d "$APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin" ]; then
      cp -R "$APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin" "$INSTALL_APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin"
    fi
    rm -f "$INSTALL_APP/Contents/Resources/AppIconV4.icns"
    mkdir -p "$INSTALL_APP/Contents/Resources/WatcherRuntime"
    if [ -x "$INSTALL_APP/Contents/Resources/WatcherRuntime/node/bin/node" ]; then
      # Runtime dependencies already exist in the installed app; update only the
      # daemon so normal DEV rebuilds do not recopy Chromium/Node unnecessarily.
      cp "$WATCHER_RUNTIME/watcher-daemon.cjs" "$INSTALL_APP/Contents/Resources/WatcherRuntime/watcher-daemon.cjs"
    else
      rm -rf "$INSTALL_APP/Contents/Resources/WatcherRuntime"
      cp -R "$WATCHER_RUNTIME" "$INSTALL_APP/Contents/Resources/WatcherRuntime"
    fi
  elif [ -d "$LEGACY_INSTALL_APP" ]; then
    # First rename after branding: preserve inode/path lineage when possible by
    # updating contents then moving to the new display name.
    cp "$BINARY" "$LEGACY_INSTALL_APP/Contents/MacOS/iBacalao"
    chmod +x "$LEGACY_INSTALL_APP/Contents/MacOS/iBacalao"
    cp "$BRIDGE_BINARY" "$LEGACY_INSTALL_APP/Contents/MacOS/iBacalaoSchoolBridge"
    chmod +x "$LEGACY_INSTALL_APP/Contents/MacOS/iBacalaoSchoolBridge"
    rm -f "$LEGACY_INSTALL_APP/Contents/MacOS/LiveExaminerOverlay"
    cp Info.plist "$LEGACY_INSTALL_APP/Contents/Info.plist"
    apply_bundle_metadata "$LEGACY_INSTALL_APP/Contents/Info.plist"
    mkdir -p "$LEGACY_INSTALL_APP/Contents/Resources"
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/logo.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/logo.png" "$LEGACY_INSTALL_APP/Contents/Resources/logo.png"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/launch-bg.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/launch-bg.png" "$LEGACY_INSTALL_APP/Contents/Resources/launch-bg.png"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/launch-bg-wide.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/launch-bg-wide.png" "$LEGACY_INSTALL_APP/Contents/Resources/launch-bg-wide.png"
    fi
    for asset in Sources/LiveExaminerOverlayCore/Resources/tool-*; do
      if [ -f "$asset" ]; then cp "$asset" "$LEGACY_INSTALL_APP/Contents/Resources/$(basename "$asset")"; fi
    done
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/Assets.car" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/Assets.car" "$LEGACY_INSTALL_APP/Contents/Resources/Assets.car"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" "$LEGACY_INSTALL_APP/Contents/Resources/AppIcon.icns"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIconDock.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/AppIconDock.png" "$LEGACY_INSTALL_APP/Contents/Resources/AppIconDock.png"
    fi
    mkdir -p "$LEGACY_INSTALL_APP/Contents/PlugIns"
    rm -rf "$LEGACY_INSTALL_APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin"
    if [ -d "$APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin" ]; then
      cp -R "$APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin" "$LEGACY_INSTALL_APP/Contents/PlugIns/iBacalaoDockTile.docktileplugin"
    fi
    rm -f "$LEGACY_INSTALL_APP/Contents/Resources/AppIconV4.icns"
    mkdir -p "$LEGACY_INSTALL_APP/Contents/Resources/WatcherRuntime"
    if [ -x "$LEGACY_INSTALL_APP/Contents/Resources/WatcherRuntime/node/bin/node" ]; then
      cp "$WATCHER_RUNTIME/watcher-daemon.cjs" "$LEGACY_INSTALL_APP/Contents/Resources/WatcherRuntime/watcher-daemon.cjs"
    else
      rm -rf "$LEGACY_INSTALL_APP/Contents/Resources/WatcherRuntime"
      cp -R "$WATCHER_RUNTIME" "$LEGACY_INSTALL_APP/Contents/Resources/WatcherRuntime"
    fi
    mv "$LEGACY_INSTALL_APP" "$INSTALL_APP"
  else
    cp -R "$APP" "$INSTALL_APP"
  fi

  # Dock: plugin + running contentView. Finder: Assets.car / icns.

  if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - \
      --identifier "$BUNDLE_ID" \
      --entitlements "$ENTITLEMENTS" \
      "$INSTALL_APP"
  else
    sign_app_bundle "$INSTALL_APP" "$SIGN_IDENTITY"
  fi
}
SKIPPED_INSTALL=0
install_to_applications

echo "Built $APP"
if [ "$SKIPPED_INSTALL" = "1" ]; then
  echo "Install skipped — existing $INSTALL_APP left untouched."
else
  echo "Installed $INSTALL_APP"
fi
echo "Launch: ./launch_app.sh  (no rebuild — keeps TCC grant)"
echo ""
if [ -d "$INSTALL_APP" ]; then
  echo "Verify signing:"
  codesign -dv "$INSTALL_APP" 2>&1 | egrep 'Identifier|Signature|Authority|TeamIdentifier' || true
fi
