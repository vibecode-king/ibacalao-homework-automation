#!/bin/bash
# Post-Xcode checklist for Digital release signing.
# Run after Xcode is in /Applications and you've opened it once.
set -euo pipefail

echo "==> Disk"
df -h /System/Volumes/Data | tail -1

echo ""
echo "==> Xcode location"
if [ -d /Applications/Xcode.app ]; then
  du -sh /Applications/Xcode.app
  echo "OK: /Applications/Xcode.app"
else
  echo "MISSING: Move Xcode.app into /Applications first."
  if [ -d "$HOME/Downloads/Xcode.app" ]; then
    echo "Found $HOME/Downloads/Xcode.app ($(du -sh "$HOME/Downloads/Xcode.app" | awk '{print $1}'))"
    echo "  Drag it to Applications, or run:"
    echo "  mv \"$HOME/Downloads/Xcode.app\" /Applications/"
  fi
fi

echo ""
echo "==> Switch active developer dir to Xcode"
if [ -d /Applications/Xcode.app ]; then
  if [ "$(xcode-select -p 2>/dev/null)" != "/Applications/Xcode.app/Contents/Developer" ]; then
    echo "Need: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  else
    echo "OK: xcode-select points at Xcode"
  fi
fi

echo ""
echo "==> notarytool"
xcrun --find notarytool 2>/dev/null || echo "MISSING notarytool"
xcrun notarytool --help >/dev/null 2>&1 && echo "OK: notarytool runs" || echo "FAIL: notarytool"

echo ""
echo "==> Developer ID Application identity"
IDS=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" || true)
if [ -n "$IDS" ]; then
  echo "$IDS"
  echo "OK: signing identity present"
else
  echo "MISSING: Upload Desktop/ibacalao_developerID.certSigningRequest at"
  echo "  https://developer.apple.com/account/resources/certificates/list"
  echo "  → Developer ID Application → download .cer → double-click"
fi

echo ""
echo "==> Release script"
if [ -x "$(dirname "$0")/release_digital.sh" ]; then
  echo "OK: release_digital.sh ready"
else
  echo "MISSING release_digital.sh"
fi

echo ""
echo "==> Notary authentication (do not print secrets)"
if [ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]; then
  if xcrun notarytool history --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "OK: Keychain profile $NOTARYTOOL_KEYCHAIN_PROFILE works"
  else
    echo "FAIL: Keychain profile $NOTARYTOOL_KEYCHAIN_PROFILE is missing or unauthorized"
  fi
elif [ -n "${ASC_KEY_ID:-}" ] || [ -n "${ASC_ISSUER_ID:-}" ] || [ -n "${ASC_KEY_PATH:-}" ]; then
  for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    if [ -n "${!v:-}" ]; then
      echo "OK: $v is set"
    else
      echo "TODO: export $v=..."
    fi
  done
  if [ -n "${ASC_KEY_PATH:-}" ] && [ -f "$ASC_KEY_PATH" ]; then
    echo "OK: ASC_KEY_PATH points to a file"
  elif [ -n "${ASC_KEY_PATH:-}" ]; then
    echo "FAIL: ASC_KEY_PATH does not point to a file"
  fi
else
  echo "TODO: configure ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH"
  echo "   or set NOTARYTOOL_KEYCHAIN_PROFILE after running xcrun notarytool store-credentials"
fi

echo ""
echo "When Xcode + Developer ID cert + API key or Keychain profile are ready:"
echo "  cd \"$(dirname "$0")\" && ./release_digital.sh"
