#!/bin/zsh
#
# Compiles the phone app's stylesheet: Bridge/styles/app.css → Bridge/web/style.css
#
# The COMPILED file is committed, and that is the point. Bridge/web is served
# straight off disk by a launchd agent with no build step of its own, and the
# page has to work offline from the service worker cache — so a stylesheet that
# needed tooling at run time, or a CDN at load time, would break the two things
# this app is built around. Tailwind runs here, on a developer's machine, and
# what ships is plain CSS.
#
# The compiler is the standalone binary: no npm, no node_modules, nothing added
# to the repo (it is 76 MB). It is cached outside the tree and downloaded once.
#
# Usage: scripts/build-css.sh [--watch]

emulate -L zsh
set -eu

root="${0:A:h:h}"
src="$root/Bridge/styles/app.css"
out="$root/Bridge/web/style.css"

version="v4.3.3"
cache="$HOME/.cache/claude-studio"
case "$(uname -m)" in
  arm64) arch="macos-arm64" ;;
  *)     arch="macos-x64" ;;
esac
cli="$cache/tailwindcss-$version-$arch"

if [[ ! -x "$cli" ]]; then
  print "→ fetching the Tailwind CLI ($version, once)…"
  mkdir -p "$cache"
  url="https://github.com/tailwindlabs/tailwindcss/releases/download/$version/tailwindcss-$arch"
  if ! curl -fsSL --max-time 300 -o "$cli.part" "$url"; then
    print -u2 "✗ could not download the Tailwind CLI."
    print -u2 "  The committed $out is still valid — this is only needed to CHANGE the styles."
    rm -f "$cli.part"
    exit 1
  fi
  chmod +x "$cli.part"
  mv -f "$cli.part" "$cli"
fi

if [[ "${1:-}" == "--watch" ]]; then
  exec "$cli" --input "$src" --output "$out" --watch
fi

# --minify: this is served to a phone over a tunnel, and it is cached by the
# service worker, so the bytes are worth trimming once here.
"$cli" --input "$src" --output "$out" --minify
print "✓ $(basename "$out") — $(wc -c < "$out" | tr -d ' ') bytes"
