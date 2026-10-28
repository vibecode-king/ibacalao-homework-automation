#!/bin/bash
# Archives the Xcode app target (LiveExaminerOverlay.xcodeproj, scheme
# "LiveExaminerOverlay") in the MAS configuration for Mac App Store
# submission. This is the Xcode/App-Store-Connect path; it does not replace
# build_app.sh, which remains the fast SwiftPM dev-loop for local testing
# (ad-hoc/Developer-ID signed, installed straight into /Applications).
#
# Signing is intentionally NOT hardcoded here — no team ID or identity is
# baked into the project file. Override via environment variables so any
# developer/CI runner can archive with their own Apple Distribution identity:
#
#   CODE_SIGN_IDENTITY="Apple Distribution: WAWALABS COMPANY SAS (3826C72RFN)" \
#   DEVELOPMENT_TEAM=3826C72RFN \
#   ./xcode_archive_mas.sh
#
# Export a .pkg for App Store Connect upload (after archive):
#
#   ./xcode_archive_mas.sh --export
#
# Preflight (cert installed?):
#
#   ./check_mas_signing_ready.sh
#
# Requires: Xcode 15+, an "Apple Distribution" signing identity, and (for
# App Sandbox + keychain-access-groups) a provisioning profile for
# com.ibacalao.LiveExaminerOverlay associated with that team.
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="LiveExaminerOverlay.xcodeproj"
SCHEME="LiveExaminerOverlay"
CONFIGURATION="MAS"
ARCHIVE_PATH="build/${SCHEME}-MAS.xcarchive"
EXPORT_PATH="build/${SCHEME}-MAS-export"
EXPORT_OPTIONS="ExportOptions-MAS.plist"

EXPORT_AFTER_ARCHIVE=0
for arg in "$@"; do
  case "$arg" in
    --export) EXPORT_AFTER_ARCHIVE=1 ;;
  esac
done

CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

EXTRA_SETTINGS=()
if [ -n "$CODE_SIGN_IDENTITY" ]; then
  EXTRA_SETTINGS+=("CODE_SIGN_IDENTITY=${CODE_SIGN_IDENTITY}")
fi
if [ -n "$DEVELOPMENT_TEAM" ]; then
  EXTRA_SETTINGS+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
fi

if [ -z "$CODE_SIGN_IDENTITY" ] || [ -z "$DEVELOPMENT_TEAM" ]; then
  echo "NOTE: CODE_SIGN_IDENTITY and/or DEVELOPMENT_TEAM not set — xcodebuild"
  echo "      will fall back to Automatic signing, which requires a signed-in"
  echo "      Apple Distribution identity/team in Xcode's account settings."
  echo ""
fi

mkdir -p build

echo "==> Archiving ($CONFIGURATION)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  "${EXTRA_SETTINGS[@]}" \
  archive

echo ""
echo "==> Archive created at $ARCHIVE_PATH"

if [ "$EXPORT_AFTER_ARCHIVE" = "1" ]; then
  if [ ! -f "$EXPORT_OPTIONS" ]; then
    echo "ERROR: Missing $EXPORT_OPTIONS"
    exit 1
  fi
  echo "==> Exporting for App Store Connect → $EXPORT_PATH"
  rm -rf "$EXPORT_PATH"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    "${EXTRA_SETTINGS[@]}"
  echo "==> Export complete. Upload the .pkg from $EXPORT_PATH via Transporter or Xcode Organizer."
else
  echo "Next steps:"
  echo "  1. Open in Organizer: open \"$ARCHIVE_PATH\""
  echo "  2. Or export locally: ./xcode_archive_mas.sh --export"
  echo "  3. Upload via Transporter or Organizer → Distribute App"
fi

echo ""
echo "After installing the exported build, re-test AX + ScreenCaptureKit under"
echo "sandbox — see docs/app-launch/SANDBOX_SPIKE.md."
