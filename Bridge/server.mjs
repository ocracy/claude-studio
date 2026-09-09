#!/usr/bin/env node
// cs-bridge — phone access to this Mac's Claude Studio sessions.
//
// The phone runs no model and holds no API key. Every prompt it sends becomes
// keystrokes delivered to a `claude` process already running in tmux on this
// Mac, under the user's own subscription. This process is a remote control, not
// a client of anything.
//
// It binds to the Netbird address only, never 0.0.0.0, and requires a bearer
// token on top of the WireGuard tunnel. ttyd listens on loopback and is reached
// exclusively through the /term proxy below, so there is one door and one key.

import { createServer, request as httpRequest } from "node:http"
import { createServer as createSecureServer } from "node:https"
import { connect } from "node:net"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { extname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { timingSafeEqual } from "node:crypto"
import { createSecureContext } from "node:tls"

import { appSupport, tokenFile } from "./lib/paths.mjs"
import { readChoices } from "./lib/choices.mjs"
import { assertMatchesSwift } from "./lib/shortid.mjs"
import { addSession, removeSession, touchSession } from "./lib/sessions.mjs"
import { locate, markSeen, readProjects, snapshot } from "./lib/state.mjs"
import * as tmux from "./lib/tmux.mjs"
import * as push from "./lib/push.mjs"
import * as watcher from "./lib/watcher.mjs"

const HERE = fileURLToPath(new URL(".", import.meta.url))
const WEB = join(HERE, "web")

/**
 * A stamp identifying the interface currently on disk.
 *
 * Derived from the files themselves rather than a version number, so it changes
 * whenever any of them is edited and nobody has to remember to bump anything.
 * Cheap enough to compute per request — a handful of stat calls.
 */
function buildId() {
  let newest = 0
  let total = 0
  try {
    for (const name of readdirSync(WEB)) {
      const info = statSync(join(WEB, name))
      newest = Math.max(newest, info.mtimeMs)
      total += info.size
    }
  } catch {
    return "unknown"
  }
  return `${Math.round(newest)}-${total}`
}

const PORT = Number(process.env.CS_BRIDGE_PORT || 7788)
const TLS_PORT = Number(process.env.CS_BRIDGE_TLS_PORT || 7443)
const HOST = process.env.CS_BRIDGE_HOST
const HOST6 = process.env.CS_BRIDGE_HOST6 || ""
const TTYD_PORT = Number(process.env.CS_TTYD_PORT || 7789)

const tlsDir = join(appSupport, "tls")
// The pair is TRIED before it is served.
//
// `createSecureContext` throws on a certificate and key that do not match, and it
// throws where it was called — at the top level, taking the whole process with it.
// That is not a hypothetical: a half-finished reissue left a new key beside an old
// certificate and the bridge died on every launch, so there was no HTTPS, no HTTP,
// and therefore no /ca.crt and no /setup — the two things the phone needs to climb
// back out. Reading it here turns a fatal pair into a missing one, and HTTP alone
// is a bridge that can still be fixed from the phone.
const tls = (() => {
  let material
  try {
    material = {
      cert: readFileSync(join(tlsDir, "server.crt")),
      key: readFileSync(join(tlsDir, "server.key")),
      ca: readFileSync(join(tlsDir, "ca.crt")),
    }
  } catch {
    return null
  }
  try {
    createSecureContext({ cert: material.cert, key: material.key })
    return material
  } catch (error) {
    console.error(`cs-bridge: the certificate and key do not match (${error.code || error.message}); `
                  + "serving HTTP only. Delete server.crt and server.key in the tls folder "
                  + "and restart to reissue them.")
    // The root is still worth serving: it is what /setup hands out, and it is
    // untouched by a bad leaf.
    return { ca: material.ca, broken: true }
  }
})()

// A drifted shortID would create sessions the Mac cannot see. Refuse to start.
assertMatchesSwift()

if (!HOST) {
  console.error("cs-bridge: CS_BRIDGE_HOST is required (the Netbird address).")
  console.error("Refusing to start rather than falling back to 0.0.0.0.")
  process.exit(1)
}

if (!tmux.tmuxPath) {
  console.error("cs-bridge: tmux not found.")
  process.exit(1)
}

// A server started outside the app keeps tmux's defaults, including a status
// bar that costs a line of the phone's screen.
tmux.ensureConfig()

const TOKEN = (() => {
  try {
    return readFileSync(tokenFile, "utf8").trim()
  } catch {
    console.error(`cs-bridge: no token at ${tokenFile}. Open Claude Studio → Settings → Phone and press Install.`)
    process.exit(1)
  }
})()

const TTYD_AUTH = "Basic " + Buffer.from(`cs:${TOKEN}`).toString("base64")

// ---------------------------------------------------------------- auth

function constantTimeEquals(a, b) {
  const left = Buffer.from(String(a))
  const right = Buffer.from(String(b))
  if (left.length !== right.length) return false
  return timingSafeEqual(left, right)
}

/** Bearer header, `?k=` on first visit, or the cookie we set from it. */
function presentedToken(req, url) {
  const header = req.headers.authorization
  if (header?.startsWith("Bearer ")) return header.slice(7).trim()
  const query = url?.searchParams.get("k")
  if (query) return query
  const cookie = req.headers.cookie?.match(/(?:^|;\s*)cs_token=([^;]+)/)
  return cookie ? decodeURIComponent(cookie[1]) : null
}

function authorized(req, url) {
  const presented = presentedToken(req, url)
  return Boolean(presented) && constantTimeEquals(presented, TOKEN)
}

// ---------------------------------------------------------------- helpers

function json(res, status, body) {
  const payload = JSON.stringify(body)
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  })
  res.end(payload)
}

async function readBody(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > 256 * 1024) throw new Error("body too large")
    chunks.push(chunk)
  }
  if (!chunks.length) return {}
  return JSON.parse(Buffer.concat(chunks).toString("utf8"))
}

const TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
}

function serveStatic(res, name) {
  // Only ever the files we ship: the name is matched against a fixed set, so
  // no request can walk out of web/.
  const file = join(WEB, name)
  try {
    statSync(file)
  } catch {
    return json(res, 404, { error: "not found" })
  }
  res.writeHead(200, {
    "content-type": TYPES[extname(name)] ?? "application/octet-stream",
    // Revalidate rather than cache for a minute: the phone should pick up a
    // fixed stylesheet or script the moment it reloads, and the service worker
    // already covers being offline.
    "cache-control": "no-cache",
  })
  res.end(readFileSync(file))
}

const STATIC = new Set([
  "index.html", "app.js", "style.css", "manifest.json", "sw.js", "icon.svg", "setup.html",
  "icon-192.png", "icon-512.png", "icon-maskable-512.png", "apple-touch-icon.png",
])

/**
 * The manifest, named after THIS Mac.
 *
 * One phone can carry two of these — a laptop and a desktop, each publishing its
 * own bridge — and two icons both labelled "Claude Studio" is a Home Screen
 * nobody can navigate. The origin already keeps them apart technically; the name
 * is what keeps them apart for the person holding the phone.
 *
 * Served rather than read from disk so the file stays the artwork-and-colours
 * template it is, with no machine's name baked into the repository.
 */
function serveManifest(res) {
  let manifest = {}
  try {
    manifest = JSON.parse(readFileSync(join(WEB, "manifest.json"), "utf8"))
  } catch {
    // Falls through to the defaults below: a phone with no manifest cannot
    // install the page at all, which is worse than a manifest with no icons.
  }
  const machine = (process.env.CS_BRIDGE_NAME ?? "").trim()
  const body = JSON.stringify({
    ...manifest,
    name: machine ? `Claude Studio — ${machine}` : "Claude Studio",
    short_name: machine ? machine.split(/[\s(]/)[0].slice(0, 12) : "Studio",
  })
  res.writeHead(200, {
    "content-type": "application/manifest+json; charset=utf-8",
    "cache-control": "no-cache",
  })
  res.end(body)
}

/**
 * Installability assets, served WITHOUT the token.
 *
 * Chrome fetches the manifest and its icons outside the page's own credential
 * context; a 401 there reads to it as "no manifest", and instead of installing
 * an app it drops a bookmark that opens in a tab with the address bar showing.
 * None of these files says anything about the Mac — the icon is artwork and the
 * manifest is four colours and a name — so exempting them costs nothing.
 */
const PUBLIC = new Set([
  "manifest.json", "icon.svg",
  "icon-192.png", "icon-512.png", "icon-maskable-512.png", "apple-touch-icon.png",
])

// ---------------------------------------------------------------- ttyd proxy

/**
 * Forward /term to ttyd on loopback, injecting its basic-auth credentials.
 *
 * Keeping ttyd behind this proxy means the terminal shares the PWA's origin
 * (so the iframe and the API agree about cookies) and there is exactly one
 * externally reachable port to reason about.
 */
function proxyToTtyd(req, res, url) {
  // ttyd runs with `--base-path /term`, so it expects the prefix intact and
  // emits asset URLs under it. Stripping the prefix here would break its own
  // index page.
  const upstream = {
    port: TTYD_PORT,
    host: "127.0.0.1",
    method: req.method,
    path: url.pathname + url.search,
    headers: { ...req.headers, host: `127.0.0.1:${TTYD_PORT}`, authorization: TTYD_AUTH },
  }
  const forward = httpRequest(upstream, (upstreamRes) => {
    res.writeHead(upstreamRes.statusCode, upstreamRes.headers)
    upstreamRes.pipe(res)
  })
  forward.on("error", () => json(res, 502, { error: "terminal service unavailable" }))
  req.pipe(forward)
}

// ---------------------------------------------------------------- routes

async function handleAPI(req, res, url) {
  const path = url.pathname

  if (req.method === "GET" && path === "/api/state") {
    // buildId travels with the state so the phone can tell it is running an
    // older copy of the interface. Installed to the Home Screen there is no
    // address bar and no reload button, so without this a change on the Mac can
    // stay invisible on the phone indefinitely.
    // The machine's name rides along for the same reason it is in the manifest:
    // with two Macs on one phone, "which one am I looking at" is a question the
    // interface has to answer without being asked.
    return json(res, 200, {
      ...snapshot(),
      buildId: buildId(),
      machine: (process.env.CS_BRIDGE_NAME ?? "").trim() || null,
    })
  }

  if (req.method === "POST" && path === "/api/sessions") {
    const body = await readBody(req)
    const project = readProjects().find((p) => p.path === body.projectPath)
    if (!project) return json(res, 400, { error: "unknown project" })

    const name = String(body.name || "").trim() || "Claude"
    const record = addSession(project.path, project.shortID, name)

    // With a prompt and `background`, start the work now and detach; otherwise
    // the tmux session is born on first attach, so it takes its size from the
    // phone instead of a detached 80x24 default.
    if (body.prompt && body.background) {
      const env = {
        CS_PROJECT: project.name,
        CS_TAB_ID: `session:${record.tmux}`,
        CS_TAB_NAME: name,
      }
      tmux.startDetached(record.tmux, project.path, env, `claude ${tmux.quoted(body.prompt)}`)
      tmux.tag(record.tmux, { project: project.shortID, title: name })
    }
    return json(res, 200, { session: record, project: project.path })
  }

  // What this session is waiting on, if it is a numbered prompt.
  //
  // The reader already existed for the notification, where the platform allows
  // two buttons on Android and none at all on iOS — so the phone could answer a
  // three-way permission prompt from the lock screen and NOT from inside the app
  // it opened, where the same question was a wall of TUI text and a keyboard.
  // Same `readChoices`, served over HTTP: one reader, one set of rules about
  // what counts as a question, and no second heuristic to keep in step.
  const asking = path.match(/^\/api\/sessions\/([^/]+)\/choices$/)
  if (req.method === "GET" && asking) {
    const name = decodeURIComponent(asking[1])
    if (!locate(name)) return json(res, 404, { error: "unknown session" })
    if (!tmux.exists(name)) return json(res, 200, { choices: null })
    return json(res, 200, { choices: readChoices(tmux.captureRaw(name)) })
  }

  // Opening a session on the phone IS looking at it, so a finished turn stops
  // being orange — on the Mac as well, because both write the same file. Without
  // this, reading an answer on the phone left it demanding attention on the desk
  // forever, which is the opposite of what reading it means.
  const seen = path.match(/^\/api\/sessions\/([^/]+)\/seen$/)
  if (req.method === "POST" && seen) {
    const name = decodeURIComponent(seen[1])
    if (!locate(name)) return json(res, 404, { error: "unknown session" })
    markSeen(name)
    return json(res, 200, { ok: true })
  }

  const keys = path.match(/^\/api\/sessions\/([^/]+)\/keys$/)
  if (req.method === "POST" && keys) {
    const name = decodeURIComponent(keys[1])
    const found = locate(name)
    if (!found) return json(res, 404, { error: "unknown session" })
    if (!tmux.exists(name)) return json(res, 409, { error: "session not running" })

    const body = await readBody(req)
    if (body.text) tmux.sendText(name, String(body.text))
    if (body.key) tmux.sendKey(name, String(body.key))
    if (body.enter) tmux.sendKey(name, "Enter")
    touchSession(found.project.path, name)
    return json(res, 200, { ok: true })
  }

  // ── notifications ──────────────────────────────────────────────────────

  // The phone has no console anyone can read. When something fails there, this
  // is how it reaches the bridge log where it can actually be diagnosed.
  if (req.method === "POST" && path === "/api/log") {
    const body = await readBody(req)
    console.error(`cs-bridge: [phone] ${String(body.message ?? "").slice(0, 500)}`)
    return json(res, 200, { ok: true })
  }

  if (req.method === "GET" && path === "/api/push/key") {
    // The phone needs this to subscribe; it is public by design.
    return json(res, 200, { publicKey: push.vapidKeys().publicKey })
  }

  if (req.method === "POST" && path === "/api/push/subscribe") {
    const body = await readBody(req)
    if (!body.subscription?.endpoint || !body.subscription?.keys?.p256dh) {
      return json(res, 400, { error: "invalid subscription" })
    }
    // Who and from where, so the Mac can show a list worth acting on. A phone
    // that installed the app twice — once from the address, once from the name —
    // registers TWICE and gets every notification twice; without the origin
    // recorded here, the two entries are indistinguishable 200-character URLs
    // and there is no way to tell which one to revoke.
    push.saveSubscription(body.subscription, body.preferences ?? { enabled: true }, {
      host: String(req.headers.host ?? ""),
      userAgent: String(req.headers["user-agent"] ?? "").slice(0, 200),
      secure: Boolean(req.socket.encrypted),
    })
    return json(res, 200, { ok: true })
  }

  if (req.method === "POST" && path === "/api/push/preferences") {
    const body = await readBody(req)
    if (!body.endpoint) return json(res, 400, { error: "endpoint required" })
    push.updatePreferences(body.endpoint, body.preferences ?? {})
    return json(res, 200, { ok: true })
  }

  if (req.method === "POST" && path === "/api/push/test") {
    const sent = await push.notify({
      title: "Claude Studio",
      body: "Notifications are working.",
    })
    return json(res, 200, { sent })
  }

  if (req.method === "POST" && path === "/api/push/unsubscribe") {
    const body = await readBody(req)
    if (body.endpoint) push.removeSubscription(body.endpoint)
    return json(res, 200, { ok: true })
  }

  if (req.method === "GET" && path === "/api/push/status") {
    const endpoint = url.searchParams.get("endpoint")
    const known = push.readSubscriptions().find((s) => s.endpoint === endpoint)
    return json(res, 200, { registered: Boolean(known), preferences: known?.preferences ?? null })
  }

  const scrolling = path.match(/^\/api\/sessions\/([^/]+)\/scroll$/)
  if (req.method === "POST" && scrolling) {
    const name = decodeURIComponent(scrolling[1])
    if (!tmux.exists(name)) return json(res, 409, { error: "session not running" })
    const body = await readBody(req)
    tmux.scroll(name, body.direction === "down" ? "down" : "up", Number(body.lines) || 3)
    return json(res, 200, { ok: true })
  }

  const one = path.match(/^\/api\/sessions\/([^/]+)$/)
  if (req.method === "DELETE" && one) {
    const name = decodeURIComponent(one[1])
    const found = locate(name)
    if (!found) return json(res, 404, { error: "unknown session" })
    // Record first, then the tmux session — the reverse order prints
    // "no server running" into a terminal someone may still be looking at.
    removeSession(found.project.path, name)
    tmux.kill(name)
    return json(res, 200, { ok: true })
  }

  return json(res, 404, { error: "not found" })
}

async function handle(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || HOST}`)

  // The root certificate is public by definition — it is what the phone has to
  // fetch BEFORE it can trust the HTTPS side, so it cannot sit behind a check
  // performed over that same HTTPS.
  if (url.pathname === "/ca.crt") {
    if (!tls) return json(res, 404, { error: "no certificate" })
    res.writeHead(200, {
      "content-type": "application/x-x509-ca-cert",
      "content-disposition": 'attachment; filename="claude-studio.crt"',
    })
    return res.end(tls.ca)
  }

  // One subresource fetched over plain http is enough for Chrome to call the
  // whole page insecure — and an insecure page installs no app and receives no
  // notification, with a missing padlock as the only visible symptom. This tells
  // the browser to fetch everything over https regardless of how a URL was
  // written, which turns a class of silent, hard-to-locate breakage into nothing
  // at all. Only on the secure listener: on the http one it would upgrade
  // requests to a port that answers differently.
  if (req.socket.encrypted) {
    res.setHeader("content-security-policy", "upgrade-insecure-requests")
  }

  // Every request except the terminal's own chatter.
  //
  // Without it there is no way to tell three situations apart that look
  // identical from the phone — a stale copy served by its own service worker, a
  // request that never left the device, and one that arrived and was refused —
  // and they need opposite fixes. The terminal is excluded because ttyd polls,
  // and a log nobody can read through is the same as no log.
  if (!url.pathname.startsWith("/term")) {
    console.log(`cs-bridge: ${req.socket.encrypted ? "https" : "http "} `
      + `${req.method} ${url.pathname} ← ${req.socket.remoteAddress}`)
  }

  const asset = url.pathname.slice(1)
  if (asset === "manifest.json") return serveManifest(res)
  if (PUBLIC.has(asset)) return serveStatic(res, asset)

  if (!authorized(req, url)) {
    res.writeHead(401, { "content-type": "text/plain; charset=utf-8" })
    return res.end("unauthorized")
  }

  // A fresh phone arrives with ?k=<token> from the QR code; persist it so the
  // token never has to be typed or kept in the address bar again.
  if (url.searchParams.get("k")) {
    res.setHeader(
      "set-cookie",
      `cs_token=${encodeURIComponent(TOKEN)}; Path=/; Max-Age=31536000; SameSite=Lax`,
    )
  }

  try {
    if (url.pathname.startsWith("/term")) return proxyToTtyd(req, res, url)
    if (url.pathname.startsWith("/api/")) return await handleAPI(req, res, url)

    // Where the QR code lands: it explains the one-time certificate step and
    // then hands over to the HTTPS site. Served over plain HTTP by necessity —
    // the phone cannot reach the secure side until it trusts the root.
    if (url.pathname === "/setup") return serveStatic(res, "setup.html")

    if (url.pathname === "/") {
      // Already on HTTPS, or no certificate to offer: go straight in. `tls.cert`
      // rather than `tls` — a broken pair still carries the root, and sending the
      // phone to a setup page for an HTTPS port that is not listening is a loop.
      if (req.socket.encrypted || !tls?.cert) return serveStatic(res, "index.html")
      return serveStatic(res, "setup.html")
    }
    const name = url.pathname.slice(1)
    if (STATIC.has(name)) return serveStatic(res, name)
    return json(res, 404, { error: "not found" })
  } catch (error) {
    json(res, 500, { error: String(error.message ?? error) })
  }
}

// WebSocket upgrade for the terminal: raw tunnel to ttyd, same injected auth.
function handleUpgrade(req, socket, head) {
  const url = new URL(req.url, `http://${HOST}`)
  if (!url.pathname.startsWith("/term") || !authorized(req, url)) {
    socket.destroy()
    return
  }

  const upstream = connect(TTYD_PORT, "127.0.0.1", () => {
    const path = url.pathname + url.search
    const headers = Object.entries({ ...req.headers, host: `127.0.0.1:${TTYD_PORT}`, authorization: TTYD_AUTH })
      .map(([key, value]) => `${key}: ${Array.isArray(value) ? value.join(", ") : value}`)
      .join("\r\n")
    upstream.write(`GET ${path} HTTP/1.1\r\n${headers}\r\n\r\n`)
    if (head?.length) upstream.write(head)
    upstream.pipe(socket)
    socket.pipe(upstream)
  })
  upstream.on("error", () => socket.destroy())
  socket.on("error", () => upstream.destroy())
}

// Two listeners rather than 0.0.0.0.
//
// The Netbird address is the one the phone uses. Loopback is added because
// Netbird runs a userspace WireGuard stack, so this Mac cannot reach its own
// Netbird address — without 127.0.0.1 the bridge would be unreachable from the
// machine it runs on, which makes it untestable and blocks the app's status
// check. Every other interface stays closed.
// The mesh's IPv6 address belongs in this list because Netbird's DNS answers the
// mesh NAME with the AAAA record first, and the name is what the phone is pointed
// at. Binding only to the v4 address meant the phone opened the link, resolved it
// to v6, and found nothing there — a link that "does not open" with a bridge that
// is demonstrably up. Loopback's v6 form is included for symmetry with 127.0.0.1.
for (const host of [HOST, HOST6, "127.0.0.1", "::1"].filter(Boolean)) {
  const server = createServer(handle)
  server.on("upgrade", handleUpgrade)
  server.on("error", (error) => console.error(`cs-bridge: ${host}: ${error.message}`))
  server.listen(PORT, host, () => console.log(`cs-bridge listening on http://${host}:${PORT}`))

  // HTTPS is what unlocks service workers, notifications and installing the
  // page as an app; the HTTP port stays up so the phone can still fetch the
  // root certificate and read the setup page.
  if (tls?.cert) {
    const secure = createSecureServer({ cert: tls.cert, key: tls.key }, handle)
    secure.on("upgrade", handleUpgrade)
    secure.on("error", (error) => console.error(`cs-bridge: ${host} (tls): ${error.message}`))
    secure.listen(TLS_PORT, host, () =>
      console.log(`cs-bridge listening on https://${host}:${TLS_PORT}`))
  }
}

if (!tls?.cert) {
  console.warn("cs-bridge: no certificate; notifications and app install stay unavailable.")
}

// Announce sessions that hand the turn back, so the phone can stay in a pocket.
watcher.start()
