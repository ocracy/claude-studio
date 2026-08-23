// Just enough service worker to make "Add to Home Screen" behave like an app.
//
// It caches the shell and nothing else. API responses describe live sessions
// and the terminal is a WebSocket — serving either from a cache would show a
// stale Mac, which is worse than showing nothing.

const CACHE = "cs-shell-v2"
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

// ── notifications ────────────────────────────────────────────────────────

self.addEventListener("push", (event) => {
  let message = { title: "Claude Studio", body: "A session needs you." }
  try {
    if (event.data) message = { ...message, ...event.data.json() }
  } catch {
    // A payload that will not parse is still worth showing: iOS requires a
    // notification for every push, and dropping it would revoke permission.
  }

  event.waitUntil(
    self.registration.showNotification(message.title, {
      body: message.body,
      icon: "/icon-192.png",
      badge: "/icon-192.png",
      // One notification per session: a later one replaces the earlier.
      tag: message.tmux || "cs",
      // Replacing a notification is silent by default, so a session that comes
      // back for you twice would only make a sound the first time.
      renotify: true,
      // The Notification API has no way to choose a sound — the `sound` field
      // was dropped from the spec and no browser implements it. The tone comes
      // from the notification channel Android gives this app, which is also
      // where the user can change it. Vibration is the one part of the alert
      // the page still controls.
      vibrate: message.silent ? [] : [180, 90, 180],
      silent: Boolean(message.silent),
      // When the session is waiting on a numbered choice, the answer is a
      // button. Android shows two; iOS shows none and the tap still opens the
      // session, which is why the body has to read as a complete notification
      // on its own. `maxActions` is 0 there, and passing actions anyway is
      // harmless — they are simply ignored.
      actions: (message.actions || []).slice(0, Notification.maxActions ?? 2),
      data: message,
    }),
  )
})

/**
 * Answer without opening anything.
 *
 * The digit goes straight to the session over the same endpoint the terminal
 * uses. `credentials: "include"` is what carries the token cookie — a service
 * worker fetch does not send it otherwise, and the request would come back 401
 * with nothing on screen to explain why.
 */
async function sendKey(tmuxName, key) {
  const response = await fetch(`/api/sessions/${encodeURIComponent(tmuxName)}/keys`, {
    method: "POST",
    credentials: "include",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: key }),
  })
  if (!response.ok) throw new Error(`keys: ${response.status}`)
}

// Tapping the notification should land on the session it is about; tapping one
// of its buttons should answer and leave the phone alone.
self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const data = event.notification.data ?? {}
  const target = data.tmux ? `/?open=${data.tmux}` : "/"

  // A choice button. Claude's numbered prompts act on the keypress itself, so
  // the digit is sent WITHOUT Enter — an extra newline would land in whatever
  // came after the prompt.
  if (event.action?.startsWith("key:") && data.tmux) {
    const key = event.action.slice(4)
    const label = (event.notification.actions ?? [])
      .find((entry) => entry.action === event.action)?.title
    event.waitUntil(
      sendKey(data.tmux, key)
        .then(() =>
          self.registration.showNotification(data.title ?? "Claude Studio", {
            body: label ? `Answered: ${label}` : `Sent ${key}`,
            icon: "/icon-192.png",
            badge: "/icon-192.png",
            tag: data.tmux,
            silent: true,
            data,
          }),
        )
        .catch((error) =>
          // The phone has no console anyone can read; this is the one place a
          // failed answer can say so, and it must not look like it worked.
          self.registration.showNotification("Could not answer", {
            body: String(error?.message ?? error),
            icon: "/icon-192.png",
            tag: data.tmux,
            data,
          }),
        ),
    )
    return
  }

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ("focus" in client) {
          client.postMessage({ type: "open-session", tmux: event.notification.data?.tmux })
          return client.focus()
        }
      }
      return self.clients.openWindow(target)
    }),
  )
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
