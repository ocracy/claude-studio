#!/bin/bash
# Syntax-check the phone bridge's JavaScript before it ships.
#
# Nothing else does. The Swift compiler covers the app, and the bridge's own
# files are only ever executed on a phone — where a syntax error is not an error
# message but an empty shell that loads its stylesheet and then does nothing, and
# a person on the other end of a chat trying to describe it.
#
# The mode matters as much as the check. `node --check` parses as a classic
# script, where a duplicate top-level `function` declaration is legal; in a
# module it is a SyntaxError that stops the whole file from executing. app.js is
# loaded with type="module", so checking it the other way passes exactly the bug
# it needs to catch — which is precisely what shipped in v1.18.6.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

check_module() {
  if ! node --input-type=module --check < "$1" 2>/tmp/cs-jscheck.err; then
    echo "✗ $1 (as an ES module)"
    sed 's/^/    /' /tmp/cs-jscheck.err
    fail=1
  fi
}

check_script() {
  if ! node --check "$1" 2>/tmp/cs-jscheck.err; then
    echo "✗ $1 (as a classic script)"
    sed 's/^/    /' /tmp/cs-jscheck.err
    fail=1
  fi
}

# Loaded with type="module" in index.html.
check_module Bridge/web/app.js
# The bridge itself and its library.
check_module Bridge/server.mjs
for file in Bridge/lib/*.mjs; do check_module "$file"; done
check_module Bridge/make-icons.mjs
# A classic service worker: `importScripts` territory, not a module.
check_script Bridge/web/sw.js

rm -f /tmp/cs-jscheck.err
[ "$fail" -eq 0 ] || { echo "✗ bridge JavaScript did not parse"; exit 1; }
echo "✓ bridge JavaScript parses"
