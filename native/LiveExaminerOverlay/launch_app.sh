#!/bin/bash
# Default: launch the existing /Applications copy WITHOUT rebuilding or re-signing,
# so an existing Screen Recording TCC grant (tied to CDHash) stays valid.
#
# Rebuild only when explicitly requested: ./launch_app.sh --rebuild
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY_NAME="LiveExaminer Overlay"
LEO_KEYCHAIN="${HOME}/Library/Keychains/LiveExaminer.keychain-db"
# Password lives in a local, gitignored file (see setup_codesign.sh) — never
# hardcoded in a script that gets committed.
LEO_KEYCHAIN_PASSWORD_FILE="$(dirname "$0")/.leo_keychain_password"
LEO_KEYCHAIN_PASSWORD="$(cat "$LEO_KEYCHAIN_PASSWORD_FILE" 2>/dev/null || true)"
APP="/Applications/iBacalao.app"
LEGACY_APP="/Applications/LiveExaminerOverlay.app"

prepare_signing_keychain() {
  if [ -f "$LEO_KEYCHAIN" ]; then
    security list-keychains -d user -s "$LEO_KEYCHAIN" "${HOME}/Library/Keychains/login.keychain-db"
    security unlock-keychain -p "$LEO_KEYCHAIN_PASSWORD" "$LEO_KEYCHAIN" >/dev/null 2>&1 || true
  fi
}

signing_ready() {
  prepare_signing_keychain
  if security find-identity -v -p codesigning 2>/dev/null \
    | grep "$IDENTITY_NAME" \
    | grep -qv "NOT_TRUSTED"; then
    return 0
  fi
  if security find-certificate -c "$IDENTITY_NAME" >/dev/null 2>&1; then
    local tmp app ent
    tmp=$(mktemp -d)
    app="$tmp/TestSign.app"
    ent="$tmp/ent.plist"
    mkdir -p "$app/Contents/MacOS"
    echo '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$app/Contents/Info.plist"
    echo '#!/bin/sh' > "$app/Contents/MacOS/TestSign"
    chmod +x "$app/Contents/MacOS/TestSign"
    echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict/></plist>' > "$ent"
    if codesign --force --sign "$IDENTITY_NAME" --entitlements "$ent" "$app" >/dev/null 2>&1 \
      && ! codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
      rm -rf "$tmp"
      return 0
    fi
    rm -rf "$tmp"
  fi
  return 1
}

if [[ "${1:-}" != "--rebuild" && "${1:-}" != "--local" ]]; then
  if [ -d "$APP" ]; then
    echo "Running existing app (no re-sign) so Screen Recording grant stays valid."
    echo "Launching $APP …"
    open "$APP"
    echo ""
    echo "To rebuild: ./launch_app.sh --rebuild"
    echo "Local dev build: ./launch_app.sh --local"
    echo "Logs: ~/Library/Logs/LiveExaminerOverlay/live_examiner_debug.log"
    exit 0
  fi
  if [ -d "$LEGACY_APP" ]; then
    echo "Found legacy $LEGACY_APP — rebuilding as iBacalao.app …"
    exec "$0" --rebuild
  fi
  LOCAL_APP="$(dirname "$0")/iBacalao.app"
  if [ ! -d "$LOCAL_APP" ]; then
    LOCAL_APP="$(dirname "$0")/LiveExaminerOverlay.app"
  fi
  if [ -d "$LOCAL_APP" ]; then
    echo "No app at $APP — launching local build at $LOCAL_APP"
    open "$LOCAL_APP"
    exit 0
  fi
  echo "No app at $APP."
  echo "Build and install first: ./launch_app.sh --rebuild"
  exit 1
fi

if [[ "${1:-}" == "--local" ]]; then
  LOCAL_APP="$(dirname "$0")/iBacalao.app"
  if [ ! -d "$LOCAL_APP" ]; then
    LOCAL_APP="$(dirname "$0")/LiveExaminerOverlay.app"
  fi
  if [ ! -d "$LOCAL_APP" ]; then
    echo "No local build at $LOCAL_APP — run: ALLOW_ADHOC=1 ./build_app.sh"
    exit 1
  fi
  echo "Launching local build (no /Applications install) …"
  open "$LOCAL_APP"
  echo "Logs: ~/Library/Logs/LiveExaminerOverlay/live_examiner_debug.log"
  exit 0
fi

# --- --rebuild path ---

# Ensure codesign identity exists (creates cert if missing).
if ! signing_ready; then
  if security find-certificate -c "$IDENTITY_NAME" >/dev/null 2>&1; then
    echo "Certificate \"$IDENTITY_NAME\" exists but is not trusted for Code Signing."
    echo ""
    echo "Trust it ONCE in Keychain Access:"
    echo "  login → Certificates → \"$IDENTITY_NAME\" → Trust → Code Signing: Always Trust"
    echo ""
    echo "Or run without rebuilding to keep your existing TCC grant:"
    echo "  ./launch_app.sh"
    exit 1
  fi
  echo "Setting up stable code signing (one-time)…"
  ./setup_codesign.sh || {
    echo ""
    echo "Stable signing not ready. To launch the existing app without rebuilding:"
    echo "  ./launch_app.sh"
    exit 1
  }
fi

./build_app.sh

if [ ! -d "$APP" ]; then
  echo "ERROR: $APP not found after build."
  exit 1
fi

if codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"; then
  echo ""
  echo "WARNING: $APP is ad-hoc signed. A rebuild changes CDHash and may re-prompt for Screen Recording."
  echo "Prefer: ./launch_app.sh  (runs existing app, no re-sign)"
  echo ""
fi

echo "Launching $APP …"
open "$APP"

echo ""
echo "Tip: use ./launch_app.sh (no flags) to relaunch without rebuilding."
echo "Logs: ~/Library/Logs/LiveExaminerOverlay/live_examiner_debug.log"
