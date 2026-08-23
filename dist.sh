#!/bin/bash
# Produces the release artifact: universal binary + ad-hoc signature + ClaudeStudio.zip
# Updater.swift downloads and installs this zip — the asset name must not change.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
APP="Claude Studio.app"
ZIP="ClaudeStudio.zip"

# The phone's JavaScript is never compiled by anything else, and on a phone a
# syntax error is an empty screen with no explanation attached.
echo "→ checking the bridge's JavaScript…"
./scripts/check-bridge-js.sh

echo "→ generating icon…"
swift scripts/make-icon.swift >/dev/null
iconutil -c icns AppIcon.iconset -o AppIcon.icns

# A universal build needs the Metal Toolchain for SwiftTerm's Metal shader
# (xcodebuild -downloadComponent MetalToolchain). Without it we fall back to the
# native architecture — the release still ships, just single-arch.
echo "→ attempting universal binary (arm64 + x86_64)…"
if swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  BIN=".build/apple/Products/Release/ClaudeStudio"
else
  echo "  no Metal Toolchain → building for the native architecture only"
  swift build -c release
  BIN=".build/release/ClaudeStudio"
fi
[ -f "$BIN" ] || { echo "✗ build failed"; exit 1; }

echo "→ packaging…"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/ClaudeStudio"
chmod +x "$APP/Contents/MacOS/ClaudeStudio"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
BRIDGE="$(dirname "$BIN")/StudioBridge"
cp "$BRIDGE" "$APP/Contents/Helpers/claude-studio-bridge"
chmod +x "$APP/Contents/Helpers/claude-studio-bridge"

# The phone bridge. It MUST be here as well as in build.sh: this script does its own
# packaging, and without it the release ships an app whose Install button reports the
# bridge missing from the bundle — see PhoneInstaller.
cp -R "Bridge" "$APP/Contents/Resources/Bridge"
chmod +x "$APP/Contents/Resources/Bridge/cs-attach.sh" \
         "$APP/Contents/Resources/Bridge/make-cert.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeStudio</string>
  <key>CFBundleIdentifier</key><string>com.claudestudio.app</string>
  <key>CFBundleName</key><string>Claude Studio</string>
  <key>CFBundleDisplayName</key><string>Claude Studio</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "→ archiving…"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✓ v${VERSION} ready"
echo "  $(pwd)/$ZIP  ($(du -h "$ZIP" | cut -f1))"
lipo -archs "$APP/Contents/MacOS/ClaudeStudio" 2>/dev/null | sed 's/^/  arch: /'
echo
echo "To publish:"
echo "  gh release create v${VERSION} \"$ZIP\" --title \"Claude Studio v${VERSION}\" --notes \"…\""
