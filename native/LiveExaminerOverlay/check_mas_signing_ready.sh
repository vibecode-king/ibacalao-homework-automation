#!/bin/bash
# Quick preflight before xcode_archive_mas.sh — checks Apple Distribution cert,
# team ID, and Xcode project presence.
set -euo pipefail
cd "$(dirname "$0")"

TEAM_ID="${DEVELOPMENT_TEAM:-3826C72RFN}"
OK=0
WARN=0

pass() { echo "OK: $*"; OK=$((OK + 1)); }
warn() { echo "TODO: $*"; WARN=$((WARN + 1)); }
fail() { echo "MISSING: $*"; }

echo "==> Apple Distribution identity (Mac App Store)"
DIST=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Apple Distribution" | grep -v "NOT_TRUSTED" | head -1 || true)
if [ -n "$DIST" ]; then
  pass "$DIST"
else
  fail "No Apple Distribution cert in Keychain."
  echo "     Create one at https://developer.apple.com/account/resources/certificates/list"
  echo "     (Software → Apple Distribution). Developer ID is NOT the same cert."
fi

echo ""
echo "==> Developer ID identity (Direct DMG — optional here)"
DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | grep -v "NOT_TRUSTED" | head -1 || true)
if [ -n "$DEV_ID" ]; then
  pass "$DEV_ID"
else
  warn "No Developer ID Application cert (only needed for release_digital.sh)."
fi

echo ""
echo "==> Xcode project"
if [ -d LiveExaminerOverlay.xcodeproj ]; then
  pass "LiveExaminerOverlay.xcodeproj"
else
  fail "Xcode project not found."
fi

echo ""
echo "==> Export options"
if [ -f ExportOptions-MAS.plist ]; then
  pass "ExportOptions-MAS.plist (team $TEAM_ID)"
else
  fail "ExportOptions-MAS.plist missing."
fi

echo ""
echo "==> xcodebuild"
if xcodebuild -version >/dev/null 2>&1; then
  pass "$(xcodebuild -version | head -1)"
else
  fail "xcodebuild not available — open Xcode once."
fi

echo ""
if [ -n "$DIST" ]; then
  echo "Ready to archive:"
  echo "  DEVELOPMENT_TEAM=$TEAM_ID \\"
  echo "  CODE_SIGN_IDENTITY=\"Apple Distribution: WAWALABS COMPANY SAS ($TEAM_ID)\" \\"
  echo "  ./xcode_archive_mas.sh --export"
else
  echo "Install Apple Distribution cert first, then re-run this script."
fi
