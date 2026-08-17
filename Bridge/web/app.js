// The phone's half of the bridge.
//
// It never talks to a model. "Send" posts text to the bridge, which types it
// into the tmux session where Claude is already running on the Mac — the same
// thing the keyboard does when you sit in front of it.

const $ = (id) => document.getElementById(id)

const views = { list: $("list"), session: $("session") }
let snapshot = { projects: [] }
let current = null // { tmux, name, projectPath, projectName }
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
        row = document.createElement("button")
        row.className = "session"
        row.dataset.tmux = session.tmux
        row.innerHTML = `<span class="dot"></span>
          <span class="body"><span class="name"></span><span class="preview"></span></span>`
        group.append(row)
      }
      group.append(row)

      row.querySelector(".dot").className = `dot ${session.state}`
      row.querySelector(".name").textContent = session.name
      row.querySelector(".preview").textContent = session.live
        ? session.preview.at(-1) || "running"
        : "not running — tap to start"
      row.onclick = () =>
        openSession({
          tmux: session.tmux,
          name: session.name,
          projectPath: project.path,
          projectName: project.name,
        })
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

  // ttyd receives the session name, project path and tab title as URL
  // arguments; cs-attach.sh validates them before tmux sees them.
  const args = [session.tmux, session.projectPath, session.name]
    .map((value) => `arg=${encodeURIComponent(value)}`)
    .join("&")
  $("term").src = `/term/?${args}`

  views.list.classList.add("hidden")
  views.session.classList.remove("hidden")
  updateBadge()
  poll(4000)
}

function closeSession() {
  // Blank the iframe so ttyd drops the connection; tmux keeps the session
  // alive (destroy-unattached off), so nothing is lost.
  $("term").src = "about:blank"
  current = null
  views.session.classList.add("hidden")
  views.list.classList.remove("hidden")
  refresh()
  poll(3000)
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

async function send() {
  const box = $("prompt")
  const text = box.value
  if (!text.trim()) return
  box.value = ""
  box.style.height = "auto"
  await sendKeys({ text, enter: true })
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

async function killCurrent() {
  if (!current) return
  const name = current.tmux
  try {
    await api(`/api/sessions/${encodeURIComponent(name)}`, { method: "DELETE" })
    closeSession()
    toast("Tab closed")
  } catch (error) {
    toast(error.message)
  }
}

// ── wiring ───────────────────────────────────────────────────────────────

$("refresh").onclick = refresh
$("back").onclick = closeSession
$("compose").onclick = openSheet
$("new-cancel").onclick = () => $("sheet").classList.add("hidden")
$("new-create").onclick = create
$("send").onclick = send
$("kill").onclick = killCurrent

for (const button of document.querySelectorAll(".keys button[data-key]")) {
  button.onclick = () => sendKeys({ key: button.dataset.key })
}

const box = $("prompt")
box.addEventListener("input", () => {
  box.style.height = "auto"
  box.style.height = `${Math.min(box.scrollHeight, window.innerHeight * 0.4)}px`
})
box.addEventListener("keydown", (event) => {
  // A hardware keyboard sends Enter to submit; Shift+Enter still adds a line.
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault()
    send()
  }
})

// Coming back from the lock screen should show the truth immediately.
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refresh()
})

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("/sw.js").catch(() => {})
}

refresh()
poll(3000)
