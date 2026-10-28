#!/bin/bash
# Packages the SwiftPM executable into a real .app bundle. Without this, macOS
# has no stable bundle identity to attach Screen Recording grants to, so TCC
# re-prompts after every rebuild when signed ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY_NAME="LiveExaminer Overlay"
BUNDLE_ID="com.ibacalao.LiveExaminerOverlay"
LEO_KEYCHAIN="${HOME}/Library/Keychains/LiveExaminer.keychain-db"
# Password lives in a local, gitignored file (see setup_codesign.sh) — never
# hardcoded in a script that gets committed.
LEO_KEYCHAIN_PASSWORD_FILE="$(dirname "$0")/.leo_keychain_password"
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
rm -f "$APP/Contents/MacOS/LiveExaminerOverlay"
cp Info.plist "$APP/Contents/Info.plist"

if [ -f "Sources/LiveExaminerOverlayCore/Resources/logo.png" ]; then
  cp "Sources/LiveExaminerOverlayCore/Resources/logo.png" "$APP/Contents/Resources/logo.png"
fi
if [ -x "./build_fullcolor_app_icon.sh" ]; then
  ./build_fullcolor_app_icon.sh
fi
if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" ]; then
  cp "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "ERROR: missing Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" >&2
  exit 1
fi
rm -f "$APP/Contents/Resources/Assets.car"

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
    rm -f "$INSTALL_APP/Contents/MacOS/LiveExaminerOverlay"
    cp Info.plist "$INSTALL_APP/Contents/Info.plist"
    mkdir -p "$INSTALL_APP/Contents/Resources"
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/logo.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/logo.png" "$INSTALL_APP/Contents/Resources/logo.png"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" "$INSTALL_APP/Contents/Resources/AppIcon.icns"
    fi
    rm -f "$INSTALL_APP/Contents/Resources/Assets.car"
  elif [ -d "$LEGACY_INSTALL_APP" ]; then
    # First rename after branding: preserve inode/path lineage when possible by
    # updating contents then moving to the new display name.
    cp "$BINARY" "$LEGACY_INSTALL_APP/Contents/MacOS/iBacalao"
    chmod +x "$LEGACY_INSTALL_APP/Contents/MacOS/iBacalao"
    rm -f "$LEGACY_INSTALL_APP/Contents/MacOS/LiveExaminerOverlay"
    cp Info.plist "$LEGACY_INSTALL_APP/Contents/Info.plist"
    mkdir -p "$LEGACY_INSTALL_APP/Contents/Resources"
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/logo.png" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/logo.png" "$LEGACY_INSTALL_APP/Contents/Resources/logo.png"
    fi
    if [ -f "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" ]; then
      cp "Sources/LiveExaminerOverlayCore/Resources/AppIcon.icns" "$LEGACY_INSTALL_APP/Contents/Resources/AppIcon.icns"
    fi
    rm -f "$LEGACY_INSTALL_APP/Contents/Resources/Assets.car"
    mv "$LEGACY_INSTALL_APP" "$INSTALL_APP"
  else
    cp -R "$APP" "$INSTALL_APP"
  fi

  # Do not NSWorkspace.setIcon — it adds Icon\r / xattrs that break codesign.
  # Dock/Finder read Contents/Resources/AppIcon.icns via CFBundleIconFile.

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
