#!/bin/bash
# Claude Studio'yu release derler ve Claude Studio.app olarak paketler.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
APP="Claude Studio.app"
BIN=".build/release/ClaudeStudio"

echo "→ ikon üretiliyor…"
swift scripts/make-icon.swift >/dev/null
iconutil -c icns AppIcon.iconset -o AppIcon.icns

echo "→ derleniyor (release)…"
swift build -c release

[ -f "$BIN" ] || { echo "✗ derleme başarısız: $BIN yok"; exit 1; }

echo "→ paketleniyor…"
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

# Ad-hoc imza: imzasız paket macOS 15+ üzerinde açılmayabilir.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ hazır: $(pwd)/$APP"
