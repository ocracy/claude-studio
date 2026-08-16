#!/bin/bash
# Derler ve /Applications altına kurar.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

echo "→ /Applications'a kuruluyor…"
rm -rf "/Applications/Claude Studio.app"
cp -R "Claude Studio.app" /Applications/
xattr -cr "/Applications/Claude Studio.app" 2>/dev/null || true

echo "✓ kuruldu — açılıyor"
# Tam yolla aç: LaunchServices aksi hâlde proje klasöründeki build çıktısını
# seçebiliyor ve kurulu sürüm yerine o çalışıyor.
open "/Applications/Claude Studio.app"
