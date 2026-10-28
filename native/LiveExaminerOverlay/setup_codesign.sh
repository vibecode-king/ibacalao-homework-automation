#!/bin/bash
# Creates a local Code Signing identity so Screen Recording grants stick across
# rebuilds. Trust in Keychain Access is required once (macOS will not auto-trust
# self-signed certs without user confirmation).
set -euo pipefail

IDENTITY_NAME="LiveExaminer Overlay"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
LEO_KEYCHAIN="${HOME}/Library/Keychains/LiveExaminer.keychain-db"
OPENSSL=/usr/bin/openssl

# Password lives in a local, gitignored file — never hardcoded in a script
# that gets committed. Generated once, reused by build_app.sh/launch_app.sh.
LEO_KEYCHAIN_PASSWORD_FILE="$(cd "$(dirname "$0")" && pwd)/.leo_keychain_password"
if [ ! -f "$LEO_KEYCHAIN_PASSWORD_FILE" ]; then
  "$OPENSSL" rand -hex 24 > "$LEO_KEYCHAIN_PASSWORD_FILE"
  chmod 600 "$LEO_KEYCHAIN_PASSWORD_FILE"
fi
LEO_KEYCHAIN_PASSWORD="$(cat "$LEO_KEYCHAIN_PASSWORD_FILE")"

identity_is_valid() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "$IDENTITY_NAME" \
    | grep -qv "NOT_TRUSTED"
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
  configure_leo_keychain
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

cert_exists() {
  security find-certificate -c "$IDENTITY_NAME" >/dev/null 2>&1
}

configure_leo_keychain() {
  security list-keychains -d user -s "$LEO_KEYCHAIN" "$LOGIN_KEYCHAIN"
  security default-keychain -s "$LEO_KEYCHAIN"
  security unlock-keychain -p "$LEO_KEYCHAIN_PASSWORD" "$LEO_KEYCHAIN"
  security set-keychain-settings -lut 21600 "$LEO_KEYCHAIN"
}

print_trust_instructions() {
  echo ""
  echo "ONE-TIME manual step (macOS requires your password — cannot be automated):"
  echo "  1. Open Keychain Access (Spotlight → \"Keychain Access\")"
  echo "  2. Select \"LiveExaminer\" keychain (left sidebar) → category \"Certificates\""
  echo "     (If missing, use \"login\" keychain instead.)"
  echo "  3. Double-click \"$IDENTITY_NAME\""
  echo "  4. Expand \"Trust\" → set \"Code Signing\" to \"Always Trust\""
  echo "  5. Close the window → enter your Mac password when prompted"
  echo "  6. Verify: security find-identity -v -p codesigning | grep \"$IDENTITY_NAME\""
  echo "  7. Re-run: ./launch_app.sh --rebuild"
  echo ""
  echo "Do NOT run 'security add-trusted-cert' — it creates a duplicate cert without"
  echo "the private key and codesign will fail with 'no identity found'."
  echo ""
}

create_identity() {
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  cat > "$TMP/leo.ext" <<'EOF'
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

  "$OPENSSL" req -new -newkey rsa:2048 -nodes \
    -keyout "$TMP/leo.key" \
    -out "$TMP/leo.csr" \
    -subj "/CN=${IDENTITY_NAME}/O=iBacalao/C=US" \
    2>/dev/null

  "$OPENSSL" x509 -req -days 3650 \
    -in "$TMP/leo.csr" \
    -signkey "$TMP/leo.key" \
    -out "$TMP/leo.crt" \
    -extfile "$TMP/leo.ext" \
    -extensions v3_req \
    2>/dev/null

  "$OPENSSL" pkcs12 -export \
    -out "$TMP/leo.p12" \
    -inkey "$TMP/leo.key" \
    -in "$TMP/leo.crt" \
    -name "$IDENTITY_NAME" \
    -passout pass:"$LEO_KEYCHAIN_PASSWORD" \
    2>/dev/null

  if [ ! -f "$LEO_KEYCHAIN" ]; then
    security create-keychain -p "$LEO_KEYCHAIN_PASSWORD" "$LEO_KEYCHAIN"
  fi

  configure_leo_keychain

  security import "$TMP/leo.p12" \
    -k "$LEO_KEYCHAIN" \
    -P "$LEO_KEYCHAIN_PASSWORD" \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$LEO_KEYCHAIN_PASSWORD" \
    "$LEO_KEYCHAIN" >/dev/null 2>&1 || true
}

ensure_identity() {
  if identity_is_valid && codesign_identity_works; then
    configure_leo_keychain
    echo "Code signing identity ready: \"$IDENTITY_NAME\""
    security find-identity -v -p codesigning | grep "$IDENTITY_NAME" || true
    return 0
  fi

  if cert_exists; then
    configure_leo_keychain
    echo "Certificate \"$IDENTITY_NAME\" found but NOT trusted for Code Signing."
    print_trust_instructions
    exit 1
  fi

  create_identity
  configure_leo_keychain

  if identity_is_valid && codesign_identity_works; then
    echo "Created + trusted Code Signing identity: \"$IDENTITY_NAME\""
    return 0
  fi

  echo "Created certificate \"$IDENTITY_NAME\" — trust step still required."
  print_trust_instructions
  exit 1
}

ensure_identity
echo "Next: ./launch_app.sh --rebuild → grant Screen Recording ONCE in System Settings."
