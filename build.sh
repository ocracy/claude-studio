#!/bin/bash
# Builds Claude Studio in release mode and packages it as Claude Studio.app.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
APP="Claude Studio.app"
BIN=".build/release/ClaudeStudio"

echo "→ generating icon…"
swift scripts/make-icon.swift >/dev/null
iconutil -c icns AppIcon.iconset -o AppIcon.icns

echo "→ building (release)…"
swift build -c release

[ -f "$BIN" ] || { echo "✗ build failed: $BIN missing"; exit 1; }

echo "→ packaging…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeStudio"
chmod +x "$APP/Contents/MacOS/ClaudeStudio"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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

# Ad-hoc signature: an unsigned bundle may refuse to open on recent macOS.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ ready: $(pwd)/$APP"
