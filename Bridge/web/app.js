// The phone's half of the bridge.
//
// It never talks to a model. "Send" posts text to the bridge, which types it
// into the tmux session where Claude is already running on the Mac — the same
// thing the keyboard does when you sit in front of it.

// ── the only console this page has ───────────────────────────────────────
//
// FIRST, before anything else runs. A phone has no inspectable console, and a
// script that dies halfway leaves a page that loads its stylesheet, paints an
// empty shell and then does nothing — indistinguishable from a network problem,
// a certificate problem or a stale cache. Every one of those has a different
// fix, and guessing between them is how an evening disappears.
//
// Registered at the top so it catches errors thrown while this very module is
// still evaluating; anything later would be a handler that arrives after the
// failure it was meant to report.
function tell(message) {
  try {
    fetch("/api/log", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message }),
    }).catch(() => {})
  } catch {}
}

addEventListener("error", (event) => {
  tell(`js error: ${event.message} @ ${event.filename}:${event.lineno}:${event.colno}`)
})
addEventListener("unhandledrejection", (event) => {
  tell(`js rejection: ${event.reason?.message ?? String(event.reason)}`)
})
tell(`app booting ${location.protocol}//${location.host}${location.pathname}`
   + ` secure=${window.isSecureContext}`
   + ` standalone=${matchMedia("(display-mode: standalone)").matches}`)

const $ = (id) => document.getElementById(id)

const views = { list: $("list"), session: $("session"), settings: $("settings") }
let snapshot = { projects: [] }
let current = null // { tmux, name, claudeSID, projectPath, projectName }
let timer = null

// ── the system back gesture ──────────────────────────────────────────────

/**
 * Installed on the Home Screen there is no address bar and no back button, so
 * Android's edge swipe is the only "back" there is — and on Android it is muscle
 * memory. With a single history entry the browser has nowhere to go and leaves
 * the app instead, which mid-session reads as the app crashing.
 *
 * So while anything is open over the session list, one sentinel history entry is
 * kept armed. A back gesture pops it, `handleBack` closes the topmost thing, and
 * the sentinel is re-armed if something is still open. At the root — the list
 * with nothing over it — nothing is armed and back leaves the app, which is what
 * it should do there.
 *
 * Deliberately NO depth counter: the truth is read off the DOM every time. A
 * counter drifts the moment something closes on its own — a sheet that submits,
 * a tab killed from the actions menu — and a drifted counter swallows the
 * gesture silently, which is worse than the bug it was meant to fix.
 */
let guardArmed = false

const isOpen = (id) => !$(id).classList.contains("hidden")

const anyLayerOpen = () =>
  isOpen("menu") || isOpen("actions") || isOpen("sheet") || isOpen("rename") ||
  isOpen("snippets") || isOpen("session") || isOpen("settings")

/** Closes the topmost open layer. Innermost first — overlays before views. */
function handleBack() {
  if (isOpen("menu")) return closeMenu()
  if (isOpen("actions")) return closeActions()
  if (isOpen("rename")) return closeRename()
  if (isOpen("snippets")) return closeSnippets()
  if (isOpen("sheet")) return closeSheet()
  if (isOpen("session")) return closeSessionView()
  if (isOpen("settings")) return closeSettingsView()
}

/**
 * Matches the sentinel to what is actually on screen. Called after everything
 * that opens or closes a layer, so a programmatic close disarms itself instead
 * of leaving an entry behind to eat the next swipe.
 */
function syncBackGuard() {
  const open = anyLayerOpen()
  if (open && !guardArmed) {
    history.pushState({ guard: true }, "")
    guardArmed = true
  } else if (!open && guardArmed) {
    // Something closed itself rather than being backed out of. Consume the
    // sentinel — but on a microtask, and only if nothing has opened in the
    // meantime: "close the menu, then open settings" runs both in one turn, and
    // popping here would take the entry settings is about to rely on.
    queueMicrotask(() => {
      if (anyLayerOpen() || !guardArmed) return
      guardArmed = false
      history.back()
    })
  }
}

addEventListener("popstate", () => {
  guardArmed = false // the sentinel we pushed is what was just popped
  handleBack()
  syncBackGuard()
})

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
/**
 * Which sessions the list shows. Kept across launches, because it is a way of
 * working rather than a momentary choice.
 *
 * `open` is the default and the reason the filter exists at all: a project keeps
 * every session record it has ever had, so the list opened on a wall of closed
 * conversations with the two that were actually running somewhere inside it.
 */
let filter = localStorage.getItem("cs.filter") || "open"

function matchesFilter(session) {
  if (filter === "all") return true
  if (filter === "attention") return session.state === "waiting"
  return session.live
}

function render() {
  const container = $("projects")
  const withSessions = snapshot.projects
    .map((project) => ({ ...project, sessions: project.sessions.filter(matchesFilter) }))
    .filter((project) => project.sessions.length)

  if (!withSessions.length) {
    const message = filter === "attention"
      ? "Nothing is waiting on you."
      : filter === "open"
        ? "Nothing is running.<br>Create a session below."
        : "No sessions yet.<br>Create one below."
    const existing = container.querySelector(".empty")
    if (!existing || existing.dataset.for !== filter) {
      container.innerHTML = `<p class="empty" data-for="${filter}">${message}</p>`
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
            <span class="body"><span class="name"><span class="label"></span></span><span class="preview"></span></span>
          </button>
          <button class="session-more" aria-label="Actions">⋯</button>`
        group.append(row)
      }
      group.append(row)

      row.querySelector(".dot").className = `dot ${session.state}`
      row.querySelector(".name .label").textContent = session.name

      // Orange means two things and only one of them clears by being read, so
      // the one that does not says so.
      let tag = row.querySelector(".name .tag")
      if (session.asking && !tag) {
        tag = document.createElement("span")
        tag.className = "tag"
        tag.textContent = "asking"
        row.querySelector(".name").append(tag)
      } else if (!session.asking && tag) {
        tag.remove()
      }

      // The headline is chosen on the Mac — the question when there is one, the
      // last thing said otherwise — so the phone is not running a second guess
      // at what a session's screen means.
      row.querySelector(".preview").textContent = session.live
        ? session.headline || "running"
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
    if (snapshot.machine) $("machine-name").textContent = snapshot.machine
    if (views.list.classList.contains("hidden")) updateBadge()
    else render()
    if (current) refreshAsk()
  } catch (error) {
    toast(error.message)
  }
}

// ── what Claude is asking ────────────────────────────────────────────────

/**
 * The numbered prompt the open session is sitting on, as buttons.
 *
 * The notification has carried these for a while, but a notification can hold
 * two of them on Android and none at all on iOS — so the phone could answer a
 * permission prompt from the lock screen and NOT from inside the app it opened,
 * where the same question was a wall of TUI text and an on-screen keyboard. The
 * reader is the bridge's `readChoices`, unchanged and unduplicated: one set of
 * rules about what counts as a question, and it returns nothing whenever the
 * shape is not unmistakable.
 */
async function refreshAsk() {
  const session = current
  if (!session) return
  try {
    const { choices } = await api(`/api/sessions/${encodeURIComponent(session.tmux)}/choices`)
    // The view may have moved on while this was in flight.
    if (current?.tmux === session.tmux) renderAsk(choices)
  } catch {
    // A session that has gone, or a tab with no terminal open yet. Neither is
    // worth a toast: this runs on a timer, and it would fire on every tick.
    if (current?.tmux === session.tmux) renderAsk(null)
  }
}

function renderAsk(choices) {
  const panel = $("ask")
  if (!choices?.options?.length) {
    panel.classList.add("hidden")
    $("ask-options").replaceChildren()
    return
  }

  $("ask-question").textContent = choices.question || "Claude is waiting for an answer."
  $("ask-options").replaceChildren(...choices.options.map((option) => {
    const button = document.createElement("button")
    button.className = "ask-option"
    button.type = "button"

    const number = document.createElement("span")
    number.className = "ask-number"
    number.textContent = option.number
    const label = document.createElement("span")
    label.textContent = option.label

    button.append(number, label)
    button.onclick = () => answer(option)
    return button
  }))
  panel.classList.remove("hidden")
}

/**
 * Sends the digit — WITHOUT Enter, because Claude's numbered prompts act on the
 * keypress itself and a stray newline would land in whatever comes next.
 *
 * The panel is hidden immediately rather than waiting to be told: the prompt is
 * gone from the screen the moment it is answered, so leaving the buttons up
 * until the next poll would invite a second tap on a question that no longer
 * exists. The re-read a moment later is what catches the NEXT prompt, which
 * Claude often draws right away.
 */
async function answer(option) {
  renderAsk(null)
  await sendKeys({ key: String(option.number) })
  setTimeout(refreshAsk, 700)
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
  syncBackGuard()
  updateBadge()
  // Read it now, not on the next tick. Arriving here from a notification means
  // there is almost certainly a question on screen already, and four seconds of
  // staring at a TUI is exactly the friction the buttons exist to remove.
  renderAsk(null)
  refreshAsk()
  // Opening it IS reading it, so a finished turn stops being orange — here and
  // on the Mac, which shares the file this writes. A question is untouched: the
  // colour only clears when it is answered.
  api(`/api/sessions/${encodeURIComponent(session.tmux)}/seen`, { method: "POST" })
    .catch(() => {})
  poll(4000)
}

function closeSessionView() {
  // Remove the iframe rather than pointing it at about:blank.
  //
  // ttyd registers a beforeunload handler, and navigating the frame away counts
  // as leaving its page — the browser then asks "Leave site? Changes you made
  // may not be saved". Removing the element tears the frame down without that
  // prompt. tmux keeps the session running either way
  // (`destroy-unattached off`), so nothing is lost by dropping the connection.
  $("term-host").replaceChildren()
  current = null
  renderAsk(null)
  views.session.classList.add("hidden")
  views.list.classList.remove("hidden")
  syncBackGuard()
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
  syncBackGuard()
}

function closeMenu() {
  $("menu").classList.add("hidden")
  syncBackGuard()
}

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
  syncBackGuard()
}

function closeActions() {
  actionTarget = null
  $("actions").classList.add("hidden")
  syncBackGuard()
}

// ── rename ───────────────────────────────────────────────────────────────

function openRename() {
  if (!current) return
  $("rename-name").value = current.name
  $("rename").classList.remove("hidden")
  syncBackGuard()
  // Focused and selected: the reason to open this is almost always to replace
  // the name outright, not to edit a character of it.
  setTimeout(() => $("rename-name").select(), 50)
}

function closeRename() {
  $("rename").classList.add("hidden")
  syncBackGuard()
}

async function saveRename() {
  const name = $("rename-name").value.trim()
  if (!current || !name) return closeRename()
  try {
    await api(`/api/sessions/${encodeURIComponent(current.tmux)}`, {
      method: "PATCH",
      body: JSON.stringify({ name }),
    })
    current.name = name
    $("session-name").textContent = name
    closeRename()
    refresh()
  } catch (error) {
    toast(error.message)
  }
}

// ── ready-made commands ──────────────────────────────────────────────────

/**
 * Phrases kept on the MAC and pressed from here.
 *
 * The one thing a phone is bad at is the thing a session is made of, and what
 * you want to say from one is short and always the same. They live beside the
 * Mac's own files rather than in this browser, so the list is the same from
 * every phone and survives clearing the site data — which an installed web app
 * gives you no way to undo.
 */
let snippets = []

async function openSnippets() {
  $("snippets").classList.remove("hidden")
  syncBackGuard()
  renderSnippets()
  try {
    snippets = (await api("/api/snippets")).snippets ?? []
    renderSnippets()
  } catch (error) {
    toast(error.message)
  }
}

function closeSnippets() {
  $("snippets").classList.add("hidden")
  syncBackGuard()
}

function renderSnippets() {
  const list = $("snippet-list")
  if (!snippets.length) {
    list.innerHTML = `<p class="group-note">Nothing yet. Add one below.</p>`
    return
  }
  list.replaceChildren(...snippets.map((entry) => {
    const row = document.createElement("div")
    row.className = "snippet"

    // Two targets, two siblings — a button inside a button is invalid markup
    // and the inner one stops receiving taps. Same shape as a session row.
    const use = document.createElement("button")
    use.className = "snippet-use"
    const name = document.createElement("span")
    name.className = "snippet-name"
    name.textContent = entry.name
    const text = document.createElement("span")
    text.className = "snippet-text"
    text.textContent = entry.text
    use.append(name, text)
    use.onclick = () => useSnippet(entry)

    const remove = document.createElement("button")
    remove.className = "snippet-remove"
    remove.setAttribute("aria-label", `Delete ${entry.name}`)
    remove.textContent = "×"
    remove.onclick = () => deleteSnippet(entry)

    row.append(use, remove)
    return row
  }))
}

async function useSnippet(entry) {
  closeSnippets()
  await sendKeys({ text: entry.text, enter: entry.send !== false })
  toast(entry.send === false ? `Typed ${entry.name}` : `Sent ${entry.name}`)
}

async function addSnippet() {
  const text = $("snippet-text").value.trim()
  if (!text) return toast("A command needs some text")
  try {
    const { snippet } = await api("/api/snippets", {
      method: "POST",
      body: JSON.stringify({
        name: $("snippet-name").value.trim(),
        text,
        send: $("snippet-send").checked,
      }),
    })
    snippets.push(snippet)
    $("snippet-name").value = ""
    $("snippet-text").value = ""
    renderSnippets()
  } catch (error) {
    toast(error.message)
  }
}

async function deleteSnippet(entry) {
  try {
    await api(`/api/snippets/${encodeURIComponent(entry.id)}`, { method: "DELETE" })
    snippets = snippets.filter((one) => one.id !== entry.id)
    renderSnippets()
  } catch (error) {
    toast(error.message)
  }
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
  syncBackgroundOption()
  $("sheet").classList.remove("hidden")
  syncBackGuard()
}

/**
 * "Start now in the background" only means something with a first task: without
 * one there is nothing to start. It used to accept the tap and silently do
 * nothing, which is the worst of the three possible behaviours.
 */
function syncBackgroundOption() {
  const hasTask = Boolean($("new-prompt").value.trim())
  const box = $("new-background")
  box.disabled = !hasTask
  if (!hasTask) box.checked = false
  $("new-background-row").style.opacity = hasTask ? "1" : "0.45"
  $("new-background-note").textContent = hasTask
    ? "Claude starts on the Mac straight away and you can put the phone down — no terminal is opened."
    : "Write a first task above to use this."
}

function closeSheet() {
  $("sheet").classList.add("hidden")
  syncBackGuard()
}

async function create() {
  const projectPath = $("new-project").value
  const prompt = $("new-prompt").value.trim()
  const background = $("new-background").checked
  // Left empty on purpose when nothing was typed: "Claude" is the one name the
  // Mac is allowed to replace with Claude's own title for the conversation
  // (`SessionRecord.isAutoNamed`), and a name cut from the first task would
  // count as one you chose and freeze there.
  const name = $("new-name").value.trim()

  try {
    const result = await api("/api/sessions", {
      method: "POST",
      body: JSON.stringify({ projectPath, name, prompt, background }),
    })
    closeSheet()
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
    if (current?.tmux === session.tmux) closeSessionView()
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
  syncBackGuard()
  renderInstall()

  const subscription = await currentSubscription().catch(() => null)
  const on = Boolean(subscription)
  $("push-enabled").checked = on
  $("push-projects-wrap").classList.toggle("hidden", !on)
  $("push-silent-row").classList.toggle("hidden", !on)

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

  $("push-silent").checked = Boolean(status.preferences?.silent)
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

$("filter").value = filter
$("filter").onchange = (event) => {
  filter = event.target.value
  localStorage.setItem("cs.filter", filter)
  render()
}

$("open-menu").onclick = openMenu
$("menu-cancel").onclick = closeMenu
$("menu").onclick = (event) => { if (event.target === $("menu")) closeMenu() }
$("menu-refresh").onclick = () => { closeMenu(); refresh(); toast("Refreshed") }
$("menu-update").onclick = updateApp
$("menu-settings").onclick = () => { closeMenu(); openSettings() }
$("update-banner").onclick = updateApp

$("back").onclick = closeSessionView
$("compose").onclick = openSheet
$("new-cancel").onclick = closeSheet
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

$("session-title").onclick = openRename
$("rename-cancel").onclick = closeRename
$("rename-save").onclick = saveRename
$("rename-name").addEventListener("keydown", (event) => {
  if (event.key === "Enter") { event.preventDefault(); saveRename() }
})

$("snippets-open").onclick = openSnippets
$("snippet-close").onclick = closeSnippets
$("snippet-add").onclick = addSnippet
$("new-prompt").addEventListener("input", syncBackgroundOption)

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

function closeSettingsView() {
  views.settings.classList.add("hidden")
  views.list.classList.remove("hidden")
  syncBackGuard()
}

$("settings-back").onclick = closeSettingsView

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

$("push-silent").onchange = async (event) => {
  const subscription = await currentSubscription()
  if (!subscription) return
  await api("/api/push/preferences", {
    method: "POST",
    body: JSON.stringify({
      endpoint: subscription.endpoint,
      preferences: { silent: event.target.checked },
    }),
  }).catch((error) => toast(error.message))
}

$("push-test").onclick = async () => {
  try {
    const { sent } = await api("/api/push/test", { method: "POST" })
    toast(sent ? "Sent — check your notifications" : "No device is registered yet")
  } catch (error) {
    toast(error.message)
  }
}

// Anything the page pulled in over plain http.
//
// The name matters: `reportEnvironment` already exists above, and declaring it
// twice in a module is a SyntaxError that stops the whole file from executing —
// which is not a broken function but a phone showing an empty shell, with no
// clue on it as to why.
function reportInsecureResources() {
  // Anything the page pulled in over plain http. ONE such resource is enough for
  // Chrome to call the whole page insecure — which silently withdraws installing
  // it as an app and every notification with it, while the padlock is the only
  // visible symptom. The browser knows exactly which resource it was; nothing
  // else here does, and a phone has no console to ask it from.
  let insecure = []
  try {
    insecure = performance.getEntriesByType("resource")
      .map((entry) => entry.name)
      .filter((name) => name.startsWith("http://") || name.startsWith("ws://"))
      .slice(0, 5)
  } catch {}

  fetch("/api/log", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      message: `app loaded, insecure resources=[${insecure.join(" ")}]`,
    }),
  }).catch(() => {})
}

// After load, so the resource list is not empty when it is read.
if (document.readyState === "complete") setTimeout(reportInsecureResources, 1500)
else addEventListener("load", () => setTimeout(reportInsecureResources, 1500))

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
      syncBackGuard()
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
