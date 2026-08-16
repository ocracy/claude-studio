#!/bin/bash
# Yayınlanabilir paket üretir: universal binary + ad-hoc imza + ClaudeStudio.zip
# Güncelleyici (Updater.swift) bu zip'i indirip kurar — varlık adı değişmemeli.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
APP="Claude Studio.app"
ZIP="ClaudeStudio.zip"

echo "→ ikon üretiliyor…"
swift scripts/make-icon.swift >/dev/null
iconutil -c icns AppIcon.iconset -o AppIcon.icns

echo "→ universal binary derleniyor (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64

BIN=".build/apple/Products/Release/ClaudeStudio"
[ -f "$BIN" ] || BIN=".build/release/ClaudeStudio"
[ -f "$BIN" ] || { echo "✗ derleme başarısız"; exit 1; }

echo "→ paketleniyor…"
rm -rf "$APP" "$ZIP"
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

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "→ arşivleniyor…"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✓ v${VERSION} hazır"
echo "  $(pwd)/$ZIP  ($(du -h "$ZIP" | cut -f1))"
lipo -archs "$APP/Contents/MacOS/ClaudeStudio" 2>/dev/null | sed 's/^/  mimari: /'
echo
echo "Yayınlamak için:"
echo "  gh release create v${VERSION} \"$ZIP\" --title \"Claude Studio v${VERSION}\" --notes \"…\""
