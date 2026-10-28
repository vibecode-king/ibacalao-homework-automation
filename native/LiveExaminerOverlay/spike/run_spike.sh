#!/bin/bash
# Phase 0.3 sandbox spike runner.
#
# Builds SandboxSpike.swift into two minimal, throwaway .app bundles — one
# signed with App Sandbox entitlements, one without (control) — and runs
# both, printing their AX/ScreenCaptureKit results side by side.
#
# Deterministic and non-destructive:
#   - Only writes under spike/build/ (gitignored, safe to delete anytime).
#   - Never touches /Applications, never installs anything.
#   - Uses only non-prompting permission queries (AXIsProcessTrusted,
#     CGPreflightScreenCaptureAccess) — no system dialogs, no captures.
#   - Ad-hoc signed (no Apple Distribution identity needed to run this).
#
# IMPORTANT — read docs/app-launch/SANDBOX_SPIKE.md before trusting the
# output. On first run both variants will almost certainly report
# "not authorized" for AX/Screen Recording — that is TCC (per-bundle-ID
# permission, granted once in System Settings > Privacy & Security), NOT
# the sandbox verdict. The sandbox-specific signal only becomes visible
# *after* granting both bundle IDs permission and re-running: if the
# non-sandboxed control succeeds but the sandboxed variant still fails
# (or vice versa succeeds), that delta is the real spike result. This
# script also cannot substitute for an actual Apple-signed, App
# Store–provisioned MAS build — see the doc for why.
set -euo pipefail
cd "$(dirname "$0")"

BUILD_DIR="build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Compiling SandboxSpike.swift"
swiftc -O SandboxSpike.swift -o "$BUILD_DIR/SandboxSpike" \
  -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit

make_bundle() {
  local variant="$1"        # "Sandboxed" | "NonSandboxed"
  local bundle_id="$2"
  local entitlements="$3"
  local app="$BUILD_DIR/${variant}.app"

  mkdir -p "$app/Contents/MacOS"
  cp "$BUILD_DIR/SandboxSpike" "$app/Contents/MacOS/${variant}"

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${variant}</string>
	<key>CFBundleIdentifier</key>
	<string>${bundle_id}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSAccessibilityUsageDescription</key>
	<string>Sandbox spike: checks whether Accessibility text reading still works under App Sandbox.</string>
	<key>NSScreenCaptureUsageDescription</key>
	<string>Sandbox spike: checks whether ScreenCaptureKit still works under App Sandbox.</string>
</dict>
</plist>
PLIST

  codesign --force --sign - \
    --identifier "$bundle_id" \
    --entitlements "$entitlements" \
    "$app"

  echo "$app"
}

SANDBOXED_APP=$(make_bundle "Sandboxed" "com.ibacalao.SandboxSpike.Sandboxed" "Sandboxed.entitlements")
CONTROL_APP=$(make_bundle "NonSandboxed" "com.ibacalao.SandboxSpike.NonSandboxed" "NonSandboxed.entitlements")

echo ""
echo "==> codesign -d --entitlements (sanity check both variants carry the right entitlements)"
for app in "$SANDBOXED_APP" "$CONTROL_APP"; do
  echo "--- $app ---"
  codesign -d --entitlements :- "$app" 2>/dev/null || true
done

echo ""
echo "==> Running NonSandboxed (control)"
"$CONTROL_APP/Contents/MacOS/NonSandboxed" || true

echo ""
echo "==> Running Sandboxed"
"$SANDBOXED_APP/Contents/MacOS/Sandboxed" || true

echo ""
echo "==> Done. If both runs above show *_TRUSTED=false / PREFLIGHT=false,"
echo "    grant Accessibility + Screen Recording to both:"
echo "      $SANDBOXED_APP"
echo "      $CONTROL_APP"
echo "    in System Settings > Privacy & Security, then re-run this script"
echo "    and compare. See docs/app-launch/SANDBOX_SPIKE.md."
