#!/bin/zsh
#
# Issue the TLS material the bridge serves on.
#
# HTTPS is not decoration here: service workers, Web Push and "install as app"
# are all gated behind a secure context, so over plain HTTP the phone gets a
# terminal but never a notification.
#
# Two certificates, with different lifetimes on purpose:
#
#   ca.crt      the root the phone is told to trust — ONCE. It must survive IP
#               changes and reinstalls, so it is created only if missing and
#               never regenerated automatically. Replacing it silently would
#               break trust on every device that already accepted it.
#   server.crt  issued by that root for the current Netbird address. Cheap to
#               reissue, so it is refreshed whenever the address changes.
#
# Usage: make-cert.sh <ip> [--force]

emulate -L zsh
set -eu

ip="${1:-}"
force="${2:-}"
[[ -n "$ip" ]] || { print -u2 "make-cert: an IP is required"; exit 1 }

dir="$HOME/Library/Application Support/Claude Studio/tls"
mkdir -p "$dir"
chmod 700 "$dir"

# LibreSSL ships with macOS but its extension handling is patchier; prefer the
# Homebrew OpenSSL when it is there.
openssl_bin="/opt/homebrew/opt/openssl@3/bin/openssl"
[[ -x "$openssl_bin" ]] || openssl_bin="$(command -v openssl)"

# ── root ────────────────────────────────────────────────────────────────────

if [[ ! -s "$dir/ca.crt" || ! -s "$dir/ca.key" ]]; then
  print "→ creating the root certificate (you will trust this on the phone once)…"
  "$openssl_bin" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$dir/ca.key" -out "$dir/ca.crt" \
    -subj "/CN=Claude Studio Bridge/O=Claude Studio" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  chmod 600 "$dir/ca.key"
fi

# ── server ──────────────────────────────────────────────────────────────────

# Reissue only when the address changed, so a restart does not churn through
# certificates the browser has already seen.
current=""
if [[ -s "$dir/server.crt" ]]; then
  current="$("$openssl_bin" x509 -in "$dir/server.crt" -noout -text 2>/dev/null |
             grep -o 'IP Address:[0-9.]*' | head -1 | cut -d: -f2)"
fi

if [[ "$current" == "$ip" && "$force" != "--force" ]]; then
  exit 0
fi

print "→ issuing a server certificate for $ip…"

# The name must be in subjectAltName: modern browsers ignore the common name
# entirely. Loopback is included so the Mac can reach its own bridge, which
# Netbird's userspace stack does not allow through the Netbird address.
cat > "$dir/san.cnf" <<CNF
subjectAltName = IP:$ip, IP:127.0.0.1, DNS:localhost
extendedKeyUsage = serverAuth
basicConstraints = CA:FALSE
CNF

"$openssl_bin" req -newkey rsa:2048 -nodes \
  -keyout "$dir/server.key" -out "$dir/server.csr" \
  -subj "/CN=Claude Studio Bridge" >/dev/null 2>&1

# 800 days: comfortably under the 825-day ceiling browsers enforce on leaf
# certificates, including ones chaining to a user-installed root.
"$openssl_bin" x509 -req -in "$dir/server.csr" \
  -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial \
  -out "$dir/server.crt" -days 800 -sha256 \
  -extfile "$dir/san.cnf" >/dev/null 2>&1

chmod 600 "$dir/server.key"
rm -f "$dir/server.csr" "$dir/san.cnf"
