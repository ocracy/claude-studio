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
# Usage: make-cert.sh <ip> [fqdn] [--force]
#
# The mesh HOSTNAME matters more than the address. An installed web app is bound
# to its origin, and a Netbird address can change — at which point the app on the
# Home Screen dies with no address bar to correct it from. So the name goes in
# the SAN and the phone is pointed at the name; the IP stays in as well, for a
# mesh whose DNS is not answering.
#
# CS_BRIDGE_NAME, when set, names the root after this Mac. Two Macs mean two
# roots on one phone, and "Claude Studio Bridge" twice is a list nobody can act
# on. It applies to a NEW root only — an existing one is never reissued.

emulate -L zsh
set -eu

ip="${1:-}"
fqdn="${2:-}"
force="${3:-}"
[[ "$fqdn" == "--force" ]] && { force="--force"; fqdn="" }
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
  # ASCII only, and no field separators. A slash or a comma would end the -subj
  # field early, and anything outside ASCII — a Mac called "Kerem’s MacBook Pro"
  # has a curly apostrophe — comes back as \xC3\xA2… in every certificate viewer,
  # which is the opposite of a name you can recognise on a phone.
  ca_name="Claude Studio Bridge"
  if [[ -n "${CS_BRIDGE_NAME:-}" ]]; then
    clean="$(print -r -- "$CS_BRIDGE_NAME" | LC_ALL=C tr -cd '[:alnum:] ._()-' |
             sed 's/^ *//; s/ *$//')"
    [[ -n "$clean" ]] && ca_name="Claude Studio Bridge ($clean)"
  fi
  "$openssl_bin" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$dir/ca.key" -out "$dir/ca.crt" \
    -subj "/CN=$ca_name/O=Claude Studio" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
  chmod 600 "$dir/ca.key"
fi

# ── server ──────────────────────────────────────────────────────────────────

# Reissue only when the address changed, so a restart does not churn through
# certificates the browser has already seen.
current_ip=""
current_dns=""
if [[ -s "$dir/server.crt" ]]; then
  san="$("$openssl_bin" x509 -in "$dir/server.crt" -noout -text 2>/dev/null |
         grep -A1 'Subject Alternative Name' | tail -1)"
  current_ip="$(print -r -- "$san" | grep -o 'IP Address:[0-9.]*' | head -1 | cut -d: -f2)"
  # The mesh name, not localhost — that one is always there.
  current_dns="$(print -r -- "$san" | tr ',' '\n' | grep -o 'DNS:[^ ]*' |
                 cut -d: -f2 | grep -v '^localhost$' | head -1)"
fi

if [[ "$current_ip" == "$ip" && "$current_dns" == "$fqdn" && "$force" != "--force" ]]; then
  exit 0
fi

print "→ issuing a server certificate for ${fqdn:-$ip}…"

# The name must be in subjectAltName: modern browsers ignore the common name
# entirely. Loopback is included so the Mac can reach its own bridge, which
# Netbird's userspace stack does not allow through the Netbird address.
names="IP:$ip, IP:127.0.0.1, DNS:localhost"
[[ -n "$fqdn" ]] && names="DNS:$fqdn, $names"

cat > "$dir/san.cnf" <<CNF
subjectAltName = $names
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
