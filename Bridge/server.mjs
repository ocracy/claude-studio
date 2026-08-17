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
import { connect } from "node:net"
import { readFileSync, statSync } from "node:fs"
import { extname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { timingSafeEqual } from "node:crypto"

import { tokenFile } from "./lib/paths.mjs"
import { assertMatchesSwift } from "./lib/shortid.mjs"
import { addSession, removeSession, touchSession } from "./lib/sessions.mjs"
import { locate, readProjects, snapshot } from "./lib/state.mjs"
import * as tmux from "./lib/tmux.mjs"

const HERE = fileURLToPath(new URL(".", import.meta.url))
const WEB = join(HERE, "web")

const PORT = Number(process.env.CS_BRIDGE_PORT || 7788)
const HOST = process.env.CS_BRIDGE_HOST
const TTYD_PORT = Number(process.env.CS_TTYD_PORT || 7789)

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

const TOKEN = (() => {
  try {
    return readFileSync(tokenFile, "utf8").trim()
  } catch {
    console.error(`cs-bridge: no token at ${tokenFile}. Run Bridge/install.sh first.`)
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
    "cache-control": name === "index.html" ? "no-store" : "max-age=60",
  })
  res.end(readFileSync(file))
}

const STATIC = new Set(["index.html", "app.js", "style.css", "manifest.json", "sw.js", "icon.svg"])

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
    return json(res, 200, snapshot())
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
    if (url.pathname === "/") return serveStatic(res, "index.html")
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
for (const host of [HOST, "127.0.0.1"]) {
  const server = createServer(handle)
  server.on("upgrade", handleUpgrade)
  server.on("error", (error) => console.error(`cs-bridge: ${host}: ${error.message}`))
  server.listen(PORT, host, () => console.log(`cs-bridge listening on http://${host}:${PORT}`))
}
