// The phone's half of the bridge.
//
// It never talks to a model. "Send" posts text to the bridge, which types it
// into the tmux session where Claude is already running on the Mac — the same
// thing the keyboard does when you sit in front of it.

const $ = (id) => document.getElementById(id)

const views = { list: $("list"), session: $("session"), settings: $("settings") }
let snapshot = { projects: [] }
let current = null // { tmux, name, claudeSID, projectPath, projectName }
let timer = null

// ── plumbing ─────────────────────────────────────────────────────────────

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: { "content-type": "application/json", ...(options.headers ?? {}) },
  })
  if (!response.ok) {
    const body = await response.json().catch(() => ({}))
    throw new Error(body.error || `HTTP ${response.status}`)
  }
  return response.json()
}

let toastTimer = null
function toast(message) {
  const element = $("toast")
  element.textContent = message
  element.classList.remove("hidden")
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => element.classList.add("hidden"), 2600)
}

// ── tab list ─────────────────────────────────────────────────────────────

/**
 * Update the list in place, keyed by project path and tmux name.
 *
 * This polls every few seconds, and rebuilding the DOM each time would swap
 * the element out from under a finger mid-tap — the tap then lands on nothing.
 * Existing rows are reused and only their text and badge change.
 */
function render() {
  const container = $("projects")
  const withSessions = snapshot.projects.filter((p) => p.sessions.length)

  if (!withSessions.length) {
    if (!container.querySelector(".empty")) {
      container.innerHTML = `<p class="empty">No sessions yet.<br>Create one below.</p>`
    }
    return
  }
  container.querySelector(".empty")?.remove()

  const keep = new Set()

  for (const project of withSessions) {
    keep.add(project.path)
    let group = container.querySelector(`[data-path="${CSS.escape(project.path)}"]`)
    if (!group) {
      group = document.createElement("section")
      group.className = "project"
      group.dataset.path = project.path
      const heading = document.createElement("h2")
      heading.textContent = project.name
      group.append(heading)
      container.append(group)
    }
    container.append(group) // keep the order the bridge returned

    const seen = new Set()
    for (const session of project.sessions) {
      seen.add(session.tmux)
      let row = group.querySelector(`[data-tmux="${CSS.escape(session.tmux)}"]`)
      if (!row) {
        // A row, not a button: it holds two independent targets — the body
        // opens the session, the ⋯ opens its actions. A button inside a button
        // is invalid and the inner one stops receiving taps.
        row = document.createElement("div")
        row.className = "session"
        row.dataset.tmux = session.tmux
        row.innerHTML = `
          <button class="session-open">
            <span class="dot"></span>
            <span class="body"><span class="name"></span><span class="preview"></span></span>
          </button>
          <button class="session-more" aria-label="Actions">⋯</button>`
        group.append(row)
      }
      group.append(row)

      row.querySelector(".dot").className = `dot ${session.state}`
      row.querySelector(".name").textContent = session.name
      row.querySelector(".preview").textContent = session.live
        ? session.preview.at(-1) || "running"
        : "not running — tap to start"

      const target = {
        tmux: session.tmux,
        name: session.name,
        claudeSID: session.claudeSID,
        projectPath: project.path,
        projectName: project.name,
      }
      row.querySelector(".session-open").onclick = () => openSession(target)
      row.querySelector(".session-more").onclick = () => openActions(target)
    }

    for (const row of group.querySelectorAll(".session")) {
      if (!seen.has(row.dataset.tmux)) row.remove()
    }
  }

  for (const group of container.querySelectorAll(".project")) {
    if (!keep.has(group.dataset.path)) group.remove()
  }
}

async function refresh() {
  try {
    snapshot = await api("/api/state")
    noteBuild(snapshot.buildId)
    if (views.list.classList.contains("hidden")) updateBadge()
    else render()
  } catch (error) {
    toast(error.message)
  }
}

function updateBadge() {
  if (!current) return
  const project = snapshot.projects.find((p) => p.path === current.projectPath)
  const session = project?.sessions.find((s) => s.tmux === current.tmux)
  $("session-state").className = `dot ${session?.state ?? "idle"}`
}

function poll(interval) {
  clearInterval(timer)
  timer = setInterval(refresh, interval)
}

// ── one session ──────────────────────────────────────────────────────────

function openSession(session) {
  current = session
  $("session-name").textContent = session.name
  $("session-project").textContent = session.projectName

  // ttyd receives the session name, project path, tab title and Claude's own
  // session id as URL arguments; cs-attach.sh validates them before tmux sees
  // them. The last one is what lets a closed tab pick the conversation back up.
  const args = [session.tmux, session.projectPath, session.name, session.claudeSID ?? ""]
    .map((value) => `arg=${encodeURIComponent(value)}`)
    .join("&")

  const frame = document.createElement("iframe")
  frame.id = "term"
  frame.title = "Terminal"
  frame.src = `/term/?${args}`
  frame.addEventListener("load", () => attachScrollGesture(frame))
  $("term-host").replaceChildren(frame)

  views.list.classList.add("hidden")
  views.session.classList.remove("hidden")
  updateBadge()
  poll(4000)
}

function closeSession() {
  // Remove the iframe rather than pointing it at about:blank.
  //
  // ttyd registers a beforeunload handler, and navigating the frame away counts
  // as leaving its page — the browser then asks "Leave site? Changes you made
  // may not be saved". Removing the element tears the frame down without that
  // prompt. tmux keeps the session running either way
  // (`destroy-unattached off`), so nothing is lost by dropping the connection.
  $("term-host").replaceChildren()
  current = null
  views.session.classList.add("hidden")
  views.list.classList.remove("hidden")
  refresh()
  poll(3000)
}

// ── scrolling ────────────────────────────────────────────────────────────

let scrollPending = 0
let scrollTimer = null

/**
 * Ask tmux to scroll. Requests are coalesced: a drag produces a stream of small
 * deltas and one tmux call per frame would be far more than the pane needs.
 */
function requestScroll(lines) {
  scrollPending += lines
  if (scrollTimer) return
  scrollTimer = setTimeout(async () => {
    const amount = scrollPending
    scrollPending = 0
    scrollTimer = null
    if (!current || !amount) return
    await api(`/api/sessions/${encodeURIComponent(current.tmux)}/scroll`, {
      method: "POST",
      body: JSON.stringify({ direction: amount > 0 ? "up" : "down", lines: Math.abs(amount) }),
    }).catch(() => {})
  }, 120)
}

const LINE_HEIGHT = 18 // px of finger travel per line of scrollback

/**
 * Dragging on the terminal scrolls tmux's history.
 *
 * The history lives in tmux, not in the browser: Claude's TUI runs on the
 * alternate screen, so the emulator's own buffer is empty and a normal swipe
 * scrolls nothing. The listeners go on the frame's document — same origin, so
 * this is allowed — and run in the capture phase so the drag is read before
 * xterm.js decides to select text with it.
 */
function attachScrollGesture(frame) {
  const doc = frame.contentDocument
  if (!doc) return

  let anchor = null
  let carried = 0

  doc.addEventListener("touchstart", (event) => {
    if (event.touches.length !== 1) return
    anchor = event.touches[0].clientY
    carried = 0
  }, { capture: true, passive: true })

  doc.addEventListener("touchmove", (event) => {
    if (anchor === null || event.touches.length !== 1) return
    const y = event.touches[0].clientY
    const travelled = y - anchor + carried
    const lines = Math.trunc(travelled / LINE_HEIGHT)
    if (!lines) return
    // Dragging down reveals older output, the direction every phone uses.
    requestScroll(lines)
    anchor = y
    carried = travelled - lines * LINE_HEIGHT
  }, { capture: true, passive: true })

  doc.addEventListener("touchend", () => { anchor = null }, { capture: true, passive: true })

  doc.addEventListener("wheel", (event) => {
    requestScroll(-Math.trunc(event.deltaY / LINE_HEIGHT) || (event.deltaY < 0 ? 1 : -1))
  }, { capture: true, passive: true })
}

async function sendKeys(body) {
  if (!current) return
  try {
    await api(`/api/sessions/${encodeURIComponent(current.tmux)}/keys`, {
      method: "POST",
      body: JSON.stringify(body),
    })
  } catch (error) {
    // The usual cause is a tab whose terminal has not been opened yet, so
    // there is no tmux session to type into.
    toast(error.message)
  }
}

// ── menu and updating ────────────────────────────────────────────────────

/** The interface build this phone loaded; compared against what the Mac serves. */
let loadedBuild = null

function noteBuild(buildId) {
  if (!buildId) return
  if (loadedBuild === null) loadedBuild = buildId
  $("update-banner").classList.toggle("hidden", buildId === loadedBuild)
}

function openMenu() {
  $("menu-build").textContent = loadedBuild ? `Build ${loadedBuild}` : ""
  $("menu").classList.remove("hidden")
}

const closeMenu = () => $("menu").classList.add("hidden")

/**
 * Load the interface the Mac is serving now.
 *
 * A plain reload is not enough: the service worker answers first and can hand
 * back the copy it cached. Its caches are dropped and the worker told to check
 * for a new version before reloading. The worker is NOT unregistered — that
 * would take the push subscription with it and notifications would silently
 * stop.
 */
async function updateApp() {
  closeMenu()
  toast("Updating…")
  try {
    if ("caches" in window) {
      const names = await caches.keys()
      await Promise.all(names.map((name) => caches.delete(name)))
    }
    const registrations = await navigator.serviceWorker?.getRegistrations?.() ?? []
    await Promise.all(registrations.map((registration) => registration.update().catch(() => {})))
  } catch {
    // Even if clearing failed, reloading is still the best next move.
  }
  location.reload()
}

// ── per-session actions ──────────────────────────────────────────────────

let actionTarget = null

function openActions(session) {
  actionTarget = session
  $("actions-title").textContent = session.name
  $("actions").classList.remove("hidden")
}

function closeActions() {
  actionTarget = null
  $("actions").classList.add("hidden")
}

// ── new session ──────────────────────────────────────────────────────────

function openSheet() {
  const select = $("new-project")
  select.innerHTML = ""
  for (const project of snapshot.projects) {
    const option = document.createElement("option")
    option.value = project.path
    option.textContent = project.name
    select.append(option)
  }
  $("new-name").value = ""
  $("new-prompt").value = ""
  $("new-background").checked = false
  $("sheet").classList.remove("hidden")
}

async function create() {
  const projectPath = $("new-project").value
  const prompt = $("new-prompt").value.trim()
  const background = $("new-background").checked
  const name = $("new-name").value.trim() || (prompt ? prompt.slice(0, 24) : "Claude")

  try {
    const result = await api("/api/sessions", {
      method: "POST",
      body: JSON.stringify({ projectPath, name, prompt, background }),
    })
    $("sheet").classList.add("hidden")
    await refresh()

    const project = snapshot.projects.find((p) => p.path === projectPath)
    if (background) {
      toast("Started on the Mac")
    } else {
      openSession({
        tmux: result.session.tmux,
        name: result.session.name,
        projectPath,
        projectName: project?.name ?? "",
      })
      // The session is created by the attach; give it a moment to come up
      // before typing the first task into it.
      if (prompt) setTimeout(() => sendKeys({ text: prompt }), 2500)
    }
  } catch (error) {
    toast(error.message)
  }
}

/** Close a tab: end the tmux session and forget its record. */
async function killSession(session) {
  try {
    await api(`/api/sessions/${encodeURIComponent(session.tmux)}`, { method: "DELETE" })
    // If the tab being closed is the one on screen, step back to the list —
    // its terminal is about to have nothing behind it.
    if (current?.tmux === session.tmux) closeSession()
    else await refresh()
    toast("Tab closed")
  } catch (error) {
    toast(error.message)
  }
}

// ── notifications ────────────────────────────────────────────────────────

let registration = null

async function currentSubscription() {
  if (!("serviceWorker" in navigator)) return null
  // Wait for the worker rather than reading the variable the registration
  // callback fills in later: on a fresh load that callback has usually not run
  // yet, and treating that as "no subscription" hides a device that is in fact
  // subscribed — which is exactly what stopped the repair below from firing.
  registration = registration ?? (await navigator.serviceWorker.ready)
  return registration.pushManager.getSubscription()
}

/**
 * Turn notifications on for this device.
 *
 * iOS only allows this from a PWA added to the Home Screen, and only from a
 * real tap — never on load — so this runs from the switch and says plainly what
 * went wrong rather than failing silently.
 */
/** Report a failure to the bridge log — the phone has no console to inspect. */
function report(stage, error) {
  const name = error?.name
  const detail = `${stage}: ${name ? `${name}: ` : ""}${error?.message || error}`
  fetch("/api/log", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ message: detail }),
  }).catch(() => {})
  return detail
}

/**
 * Send the phone's capabilities to the bridge log.
 *
 * Whether push can work at all is decided by facts only the phone knows —
 * whether the page is on HTTPS, whether it is running as an installed app,
 * what the browser exposes. None of it is visible from the Mac, and asking a
 * person to read it off a screen loses the details that matter.
 */
async function reportEnvironment() {
  let registrations = []
  let subscribed = false
  try {
    registrations = await navigator.serviceWorker.getRegistrations()
    subscribed = Boolean(await (await navigator.serviceWorker.ready).pushManager.getSubscription())
  } catch {
    // Absent APIs are themselves part of the answer.
  }
  report("environment", {
    name: "",
    message: JSON.stringify({
      origin: location.origin,
      secure: window.isSecureContext,
      standalone: window.matchMedia("(display-mode: standalone)").matches,
      serviceWorker: "serviceWorker" in navigator,
      pushManager: "PushManager" in window,
      permission: typeof Notification === "undefined" ? "absent" : Notification.permission,
      registrations: registrations.length,
      subscribed,
    }),
  })
}

async function enablePush() {
  if (!window.isSecureContext) {
    throw new Error(report("secure context",
      { name: "InsecureContext", message: `not HTTPS: ${location.origin}` }))
  }
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    throw new Error(report("push support", {
      name: "Unsupported",
      message: `serviceWorker=${"serviceWorker" in navigator} pushManager=${"PushManager" in window}`,
    }))
  }

  // Each step is reported separately: the failure is invisible on the phone and
  // "it did not work" does not say whether the browser, the permission or the
  // push service refused.
  try {
    registration = await navigator.serviceWorker.ready
  } catch (error) {
    throw new Error(report("service worker", error))
  }

  const permission = await Notification.requestPermission()
  if (permission !== "granted") {
    throw new Error(`Notifications are ${permission} in your phone's settings.`)
  }

  let publicKey
  try {
    ;({ publicKey } = await api("/api/push/key"))
  } catch (error) {
    throw new Error(report("fetching the key", error))
  }

  let subscription = await registration.pushManager.getSubscription()
  if (!subscription) {
    try {
      subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: base64UrlToBytes(publicKey),
      })
    } catch (error) {
      // The usual causes: no network path to the push service, or Play Services
      // missing. Both surface here as an AbortError with little detail.
      throw new Error(report("subscribing", error))
    }
  }

  try {
    await api("/api/push/subscribe", {
      method: "POST",
      body: JSON.stringify({
        subscription: subscription.toJSON(),
        preferences: { enabled: true, projects: [] },
      }),
    })
  } catch (error) {
    throw new Error(report("registering with the Mac", error))
  }
  return subscription
}

async function disablePush() {
  const subscription = await currentSubscription()
  if (!subscription) return
  await api("/api/push/unsubscribe", {
    method: "POST",
    body: JSON.stringify({ endpoint: subscription.endpoint }),
  }).catch(() => {})
  await subscription.unsubscribe().catch(() => {})
}

function base64UrlToBytes(value) {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(padded.padEnd(Math.ceil(padded.length / 4) * 4, "="))
  return Uint8Array.from(raw, (c) => c.charCodeAt(0))
}

// ── installing as an app ─────────────────────────────────────────────────
//
// Chrome fires `beforeinstallprompt` only when it considers the site
// installable (manifest reachable, a ≥192px raster icon, a service worker, a
// trusted certificate). Holding on to the event is the only way to offer a
// button — and its absence is itself the diagnosis, so the note says what is
// missing rather than staying blank.

let installPrompt = null

window.addEventListener("beforeinstallprompt", (event) => {
  // Prevented so Chrome's own mini-infobar does not compete with the button.
  event.preventDefault()
  installPrompt = event
  if (!views.settings.classList.contains("hidden")) renderInstall()
})

window.addEventListener("appinstalled", () => {
  installPrompt = null
  renderInstall()
  toast("Installed — open it from your Home Screen")
})

const installed = () =>
  window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true

function renderInstall() {
  const note = $("install-note")
  const button = $("install")
  button.classList.toggle("hidden", !installPrompt)

  if (installed()) {
    note.textContent = "Running as an installed app."
  } else if (installPrompt) {
    note.textContent = "Install it to lose the address bar and receive notifications."
  } else if (!window.isSecureContext) {
    note.textContent = "Open the HTTPS address first — a phone can only install a secure site."
  } else if (/iPhone|iPad|iPod/.test(navigator.userAgent)) {
    // Only Safari can create a standalone app on iOS; Chrome's "Add to Home
    // Screen" there produces a shortcut that reopens inside Chrome.
    note.textContent = "On iPhone: open this in Safari, then Share → Add to Home Screen."
  } else {
    note.textContent = "Already installed, or your browser offers it from its own ⋮ menu → Install app."
  }
}

$("install").onclick = async () => {
  if (!installPrompt) return
  const prompt = installPrompt
  installPrompt = null
  prompt.prompt()
  await prompt.userChoice.catch(() => {})
  renderInstall()
}

async function openSettings() {
  views.list.classList.add("hidden")
  views.settings.classList.remove("hidden")
  renderInstall()

  const subscription = await currentSubscription().catch(() => null)
  const on = Boolean(subscription)
  $("push-enabled").checked = on
  $("push-projects-wrap").classList.toggle("hidden", !on)

  if (!on) {
    $("push-note").textContent = window.matchMedia("(display-mode: standalone)").matches
      ? "Get a notification when a session finishes and needs you."
      : "On iPhone, add this to your Home Screen first — notifications only work from there."
    return
  }

  const status = await api(`/api/push/status?endpoint=${encodeURIComponent(subscription.endpoint)}`)
    .catch(() => ({ registered: false, preferences: null }))

  // The browser can hold a subscription the Mac never stored — if the
  // registering call failed after the browser had already subscribed, the switch
  // reads as on while the Mac has no device to notify. Repair it here rather
  // than making the user toggle it off and on.
  if (!status.registered) {
    try {
      await api("/api/push/subscribe", {
        method: "POST",
        body: JSON.stringify({
          subscription: subscription.toJSON(),
          preferences: { enabled: true, projects: [] },
        }),
      })
      $("push-note").textContent = "Registered with your Mac."
    } catch (error) {
      $("push-note").textContent = report("re-registering", error)
    }
  }

  renderProjectChoices(status.preferences?.projects ?? [])
}

function renderProjectChoices(selected) {
  const container = $("push-projects")
  container.innerHTML = ""
  for (const project of snapshot.projects) {
    const label = document.createElement("label")
    label.className = "setting"
    label.innerHTML = `<span></span><input type="checkbox">`
    label.querySelector("span").textContent = project.name
    const box = label.querySelector("input")
    box.checked = selected.length === 0 || selected.includes(project.path)
    box.onchange = saveProjectChoices
    box.dataset.path = project.path
    container.append(label)
  }
}

async function saveProjectChoices() {
  const subscription = await currentSubscription()
  if (!subscription) return
  const boxes = [...$("push-projects").querySelectorAll("input")]
  const chosen = boxes.filter((b) => b.checked).map((b) => b.dataset.path)
  // Everything ticked means "all projects", which is stored as an empty list so
  // a project added later is included without having to come back here.
  const projects = chosen.length === boxes.length ? [] : chosen
  await api("/api/push/preferences", {
    method: "POST",
    body: JSON.stringify({ endpoint: subscription.endpoint, preferences: { projects } }),
  }).catch((error) => toast(error.message))
}

// ── wiring ───────────────────────────────────────────────────────────────

$("open-menu").onclick = openMenu
$("menu-cancel").onclick = closeMenu
$("menu").onclick = (event) => { if (event.target === $("menu")) closeMenu() }
$("menu-refresh").onclick = () => { closeMenu(); refresh(); toast("Refreshed") }
$("menu-update").onclick = updateApp
$("menu-settings").onclick = () => { closeMenu(); openSettings() }
$("update-banner").onclick = updateApp

$("back").onclick = closeSession
$("compose").onclick = openSheet
$("new-cancel").onclick = () => $("sheet").classList.add("hidden")
$("new-create").onclick = create

$("action-cancel").onclick = closeActions
$("action-close").onclick = () => {
  const session = actionTarget
  closeActions()
  if (session) killSession(session)
}
// Tapping the dimmed area behind the sheet dismisses it.
$("actions").onclick = (event) => { if (event.target === $("actions")) closeActions() }

for (const button of document.querySelectorAll("button[data-key]")) {
  button.onclick = () => sendKeys({ key: button.dataset.key })
}

// Shift+Enter is not a key tmux can name: the app maps it to a backslash
// followed by Return, which is what Claude Code reads as "new line, keep
// typing". Sending a bare newline through sendText produces the same pair.
for (const button of document.querySelectorAll("button[data-newline]")) {
  button.onclick = () => sendKeys({ text: "\n" })
}

// Coming back from the lock screen should show the truth immediately.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refresh()
})

$("settings-back").onclick = () => {
  views.settings.classList.add("hidden")
  views.list.classList.remove("hidden")
}

$("push-enabled").onchange = async (event) => {
  const wanted = event.target.checked
  try {
    if (wanted) {
      await enablePush()
      toast("Notifications on")
    } else {
      await disablePush()
      toast("Notifications off")
    }
    await openSettings()
  } catch (error) {
    event.target.checked = !wanted
    $("push-note").textContent = error.message
    toast(error.message)
    // Whatever the phone can and cannot do is the context that makes the
    // failure above readable, so it is sent only when something went wrong.
    reportEnvironment()
  }
}

// Start over cleanly: drop whatever the browser is holding and subscribe again.
// Useful when an earlier attempt left a subscription the Mac never saw.
$("push-repair").onclick = async () => {
  try {
    await disablePush()
    await enablePush()
    toast("Registered")
    await openSettings()
  } catch (error) {
    $("push-note").textContent = error.message
    toast(error.message)
  }
}

$("push-test").onclick = async () => {
  try {
    const { sent } = await api("/api/push/test", { method: "POST" })
    toast(sent ? "Sent — check your notifications" : "No device is registered yet")
  } catch (error) {
    toast(error.message)
  }
}

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js")
    .then((reg) => { registration = reg })
    .catch(() => {})

  // Tapping a notification opens the session it was about.
  navigator.serviceWorker.addEventListener("message", (event) => {
    if (event.data?.type === "open-session") openByName(event.data.tmux)
  })
}

/** Find a tab by tmux name in the latest snapshot and open it. */
function openByName(tmuxName) {
  if (!tmuxName) return
  for (const project of snapshot.projects) {
    const session = project.sessions.find((s) => s.tmux === tmuxName)
    if (session) {
      views.settings.classList.add("hidden")
      openSession({
        tmux: session.tmux,
        name: session.name,
        claudeSID: session.claudeSID,
        projectPath: project.path,
        projectName: project.name,
      })
      return
    }
  }
}

// Opened from a notification while the app was closed.
const requested = new URL(location.href).searchParams.get("open")

refresh().then(() => { if (requested) openByName(requested) })
poll(3000)
