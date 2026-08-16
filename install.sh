#!/bin/bash
# Builds and installs into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

echo "→ installing into /Applications…"
rm -rf "/Applications/Claude Studio.app"
cp -R "Claude Studio.app" /Applications/
xattr -cr "/Applications/Claude Studio.app" 2>/dev/null || true

echo "✓ installed — launching"
# Open by full path: otherwise LaunchServices may pick the build output in the
# project folder and run that instead of the installed copy.
open "/Applications/Claude Studio.app"
