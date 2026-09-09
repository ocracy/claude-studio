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

# It has to LOOK like an address, not merely be non-empty.
#
# `netbird status` prints "NetBird IP: N/A" when it is signed out, and the runner
# reduced that to the string "N" by cutting at the prefix slash. Non-empty, so it
# passed every check on the way here, and then openssl rejected "IP:N" — after the
# new key had already been written over the old one. The result was a key that did
# not match its certificate, which killed the bridge on every launch from then on.
# Two guards, deliberately: the runner refuses to pass it, and this refuses to use it.
if [[ ! "$ip" =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 "make-cert: \"$ip\" is not an IPv4 address"
  exit 1
fi
# The same for the name: "N/A" is not a hostname, and a SAN entry built from one
# fails the whole certificate.
[[ "$fqdn" == *[!A-Za-z0-9.-]* || "$fqdn" == "N/A" ]] && fqdn=""

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

# How this script issues leaves. Bump it whenever the SHAPE of the certificate
# changes — key usage, lifetime, the name in the subject.
#
# Without it a fix to the certificate reaches nobody: the reissue test only ever
# asked whether the ADDRESS changed, so an improved script would sit on disk
# beside an unchanged certificate and every symptom would survive the update
# that was supposed to end it.
policy=3
if [[ "$(cat "$dir/.issue-policy" 2>/dev/null)" != "$policy" ]]; then
  force="--force"
fi

# A pair that does not match is worse than no pair at all: Node throws where it
# builds the secure context, at the top level, so the bridge dies on every launch
# and takes the HTTP side down with it — no /ca.crt, no /setup, nothing to fix it
# from. Any run that finds one reissues, which is what makes a Mac left in that
# state repair itself rather than needing the files deleted by hand.
if [[ -s "$dir/server.crt" && -s "$dir/server.key" ]]; then
  key_mod="$("$openssl_bin" rsa -in "$dir/server.key" -noout -modulus 2>/dev/null || true)"
  crt_mod="$("$openssl_bin" x509 -in "$dir/server.crt" -noout -modulus 2>/dev/null || true)"
  if [[ -z "$key_mod" || "$key_mod" != "$crt_mod" ]]; then
    print -u2 "make-cert: the stored key and certificate do not match; reissuing"
    force="--force"
  fi
fi

# A leaf that is about to expire is reissued even when nothing else changed. It
# lives 397 days (see below), so without this the phone would one day meet an
# expired certificate and every symptom of a broken setup at once.
if [[ -s "$dir/server.crt" ]] && ! "$openssl_bin" x509 -in "$dir/server.crt" -noout \
     -checkend 2592000 >/dev/null 2>&1; then
  force="--force"
fi
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
# Netbird's DNS answers the mesh name with its AAAA record first, so a phone that
# opens the link is as likely to arrive over IPv6 as over IPv4 — and a certificate
# that does not cover the address it was reached on fails validation just as hard
# as an untrusted one.
[[ -n "${CS_MESH_IP6:-}" && "$CS_MESH_IP6" == *:* ]] && names="$names, IP:$CS_MESH_IP6"
[[ -n "$fqdn" ]] && names="DNS:$fqdn, $names"

# `keyUsage` is spelled out rather than left off: it is what an RSA server
# certificate is required to carry, and a leaf without it is the kind of detail a
# strict validator rejects while every command-line tool accepts it happily.
cat > "$dir/san.cnf" <<CNF
subjectAltName = $names
extendedKeyUsage = serverAuth
keyUsage = critical, digitalSignature, keyEncipherment
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
CNF

# The subject names the SERVER, the way every real certificate does. It used to
# repeat the root's own name, which is the one thing a leaf should never do: a
# certificate whose subject looks like its issuer's is what a path builder treats
# as self-signed, and the chain it then fails to build is reported as nothing more
# specific than "not trusted".
# Everything is built beside the live pair and moved into place only once BOTH
# halves exist. Writing `server.key` first and signing afterwards is what made a
# failed signature permanent: the key was new, the certificate was the old one,
# and nothing on the next run could tell that the pair had been broken — it
# reissued, failed at the same step, and left the same wreckage. Errors are no
# longer swallowed either; the log is the only place this can be diagnosed from.
tmp_key="$dir/.server.key.new"
tmp_crt="$dir/.server.crt.new"
trap 'rm -f "$tmp_key" "$tmp_crt" "$dir/server.csr" "$dir/san.cnf"' EXIT

# Captured rather than piped: key generation prints a screenful of progress dots
# to stderr, and this log is the only place a failure here can be diagnosed from —
# so the noise is kept back and only shown if something actually went wrong.
key_error="$("$openssl_bin" req -newkey rsa:2048 -nodes \
  -keyout "$tmp_key" -out "$dir/server.csr" \
  -subj "/CN=${fqdn:-$ip}" 2>&1 >/dev/null || true)"
if [[ ! -s "$tmp_key" ]]; then
  print -u2 "make-cert: could not create the server key: $key_error"
  exit 1
fi

# 397 days, not the 800 this used to issue. The 398-day ceiling is written for
# publicly trusted certificates and a locally trusted root is supposed to be
# exempt — but "supposed to be" is not something to bet a phone on when the
# failure mode is a silent "not secure" that also disables installing the app and
# every notification with it. It costs nothing: the leaf is reissued whenever the
# address or the name changes, and now also when it is within a month of expiry.
if ! sign_error="$("$openssl_bin" x509 -req -in "$dir/server.csr" \
       -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial \
       -out "$tmp_crt" -days 397 -sha256 \
       -extfile "$dir/san.cnf" 2>&1 >/dev/null)"; then
  print -u2 "make-cert: signing failed, the existing certificate is left untouched: $sign_error"
  exit 1
fi

# Belt and braces: prove the pair matches before it replaces a working one.
key_mod="$("$openssl_bin" rsa -in "$tmp_key" -noout -modulus 2>/dev/null)"
crt_mod="$("$openssl_bin" x509 -in "$tmp_crt" -noout -modulus 2>/dev/null)"
if [[ -z "$key_mod" || "$key_mod" != "$crt_mod" ]]; then
  print -u2 "make-cert: the new key and certificate do not match; keeping the old pair"
  exit 1
fi

chmod 600 "$tmp_key"
mv -f "$tmp_key" "$dir/server.key"
mv -f "$tmp_crt" "$dir/server.crt"
print -r -- "$policy" > "$dir/.issue-policy"
