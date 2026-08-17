#!/bin/bash
# Builds and installs into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

# Persistent sessions need tmux. Install it rather than leaving the app degraded —
# without it sessions die with the app and terminals draw at the wrong size until a
# resize (SwiftTerm's column count is stale at spawn; tmux is what hides that).
if ! command -v tmux >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "→ tmux is missing; installing with Homebrew…"
    brew install tmux || echo "  ✗ brew install tmux failed — sessions will not persist"
  else
    echo "  ⚠ tmux is missing and Homebrew is not installed."
    echo "    Install tmux for persistent sessions:  https://github.com/tmux/tmux/wiki/Installing"
  fi
fi

./build.sh

echo "→ installing into /Applications…"
rm -rf "/Applications/Claude Studio.app"
cp -R "Claude Studio.app" /Applications/
xattr -cr "/Applications/Claude Studio.app" 2>/dev/null || true

echo "✓ installed — launching"
# Open by full path: otherwise LaunchServices may pick the build output in the
# project folder and run that instead of the installed copy.
open "/Applications/Claude Studio.app"
