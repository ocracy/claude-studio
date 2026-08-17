// Just enough service worker to make "Add to Home Screen" behave like an app.
//
// It caches the shell and nothing else. API responses describe live sessions
// and the terminal is a WebSocket — serving either from a cache would show a
// stale Mac, which is worse than showing nothing.

const CACHE = "cs-shell-v1"
const SHELL = ["/", "/app.js", "/style.css", "/icon.svg", "/manifest.json"]

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)))
  self.skipWaiting()
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))),
    ),
  )
  self.clients.claim()
})

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url)
  if (event.request.method !== "GET") return
  if (url.pathname.startsWith("/api/") || url.pathname.startsWith("/term")) return

  // Network first: the cache exists only so a cold launch out of signal still
  // opens, and it is refreshed on every successful load.
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone()
        caches.open(CACHE).then((cache) => cache.put(event.request, copy))
        return response
      })
      .catch(() => caches.match(event.request).then((hit) => hit ?? caches.match("/"))),
  )
})
