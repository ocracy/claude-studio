// Assemble the one payload the phone needs: every project, every tab, and what
// each tab is doing right now.
//
// Nothing is invented here. Projects come from the app's recents list, tabs from
// each project's own records, liveness from tmux, and the working/waiting state
// from the files Claude Code's hook writes. The bridge is a reader; the app
// remains the author of all of it.

import { readdirSync, readFileSync } from "node:fs"
import { basename } from "node:path"
import { lastSpokenLine, readChoices } from "./choices.mjs"
import { cocoaToMillis, readSessions } from "./sessions.mjs"
import { recents, seenSessions, sessionStateDir, writeAtomically } from "./paths.mjs"
import { shortID } from "./shortid.mjs"
import * as tmux from "./tmux.mjs"

/** Projects the app has opened, most recent first. */
export function readProjects() {
  let entries = []
  try {
    entries = JSON.parse(readFileSync(recents, "utf8"))
  } catch {
    return []
  }
  if (!Array.isArray(entries)) return []
  return entries
    .filter((entry) => entry?.path)
    .map((entry) => {
      const name = entry.name || basename(entry.path)
      return {
        path: entry.path,
        name,
        shortID: shortID(entry.path, name),
        lastOpened: entry.lastOpened ? cocoaToMillis(entry.lastOpened) : null,
      }
    })
}

/**
 * Hook state per tab, keyed by CS_TAB_ID (`session:<tmux name>`).
 * Read fresh on every request — launchd runs and tmux write these files behind
 * the app's back, which is why the app polls them too rather than watching.
 */
function readHookStates() {
  const states = new Map()
  let files = []
  try {
    files = readdirSync(sessionStateDir)
  } catch {
    return states
  }
  for (const file of files) {
    if (!file.endsWith(".json")) continue
    try {
      const body = JSON.parse(readFileSync(`${sessionStateDir}/${file}`, "utf8"))
      states.set(file.slice(0, -".json".length), body)
    } catch {
      // A half-written state file is momentary; skip it this poll.
    }
  }
  return states
}

/** What the phone and the Mac have already read. `tab id → hook timestamp`. */
export function readSeen() {
  try {
    const parsed = JSON.parse(readFileSync(seenSessions, "utf8"))
    return parsed && typeof parsed === "object" ? parsed : {}
  } catch {
    return {}
  }
}

/**
 * Marks a finished turn read — what opening a session on the phone means.
 *
 * The TIMESTAMP is stored, not just the key: what was read is a particular
 * finish, not the session, so the next one is orange again. Re-read immediately
 * before writing, because the Mac writes this file too.
 */
export function markSeen(tmuxName) {
  const key = `session:${tmuxName}`
  const hook = readHookStates().get(key)
  const seen = readSeen()
  seen[key] = Math.max(Number(seen[key] ?? 0), Number(hook?.ts ?? 0))
  writeAtomically(seenSessions, JSON.stringify(seen))
}

/**
 * The three colours, and what each one is allowed to mean.
 *
 *   working — a turn is IN FLIGHT. Not "a terminal is open": starting Claude
 *             fires SessionStart and nothing else until something is typed, so
 *             a freshly opened or resumed tab used to sit on green forever.
 *             That is fixed at the source (SessionStart now reports idle), and
 *             this is the reader that depends on it.
 *   waiting — it is on you: Claude is holding a question, OR a turn finished
 *             and nobody has looked at it yet.
 *   idle    — nothing is pending. A turn that has been read, or a session
 *             sitting at its prompt.
 *
 * The SCREEN decides whether a finished turn is a question, exactly as the Mac
 * does — the prompt is drawn in the TUI and disappears the moment it is
 * answered, so its presence is proof and its absence is proof. Only when the
 * screen cannot be read does the hook get a say, and the sixty-second idle
 * Notification is refused there: it fires on every finished turn left alone for
 * a minute, and taking it for a question would make everything orange forever.
 */
function resolve(hook, screen, seenAt) {
  if (hook?.state === "working") return { state: "working", asking: false }
  if (hook?.state !== "waiting") return { state: "idle", asking: false }

  const asking = screen
    ? Boolean(screen.options?.length)
    : hook.kind === "notify" && !/waiting for your input/i.test(hook.msg ?? "")
  if (asking) return { state: "waiting", asking: true }

  const ts = Number(hook.ts ?? 0)
  const read = seenAt != null && Number(seenAt) >= ts
  return { state: read ? "idle" : "waiting", asking: false }
}

/**
 * @param {boolean} withPreview  capture pane contents (one tmux call per live
 *   session — fine for a list of tabs, skipped when the caller only needs badges)
 */
export function snapshot({ withPreview = true } = {}) {
  const live = tmux.list()
  const hooks = readHookStates()
  const seen = readSeen()

  const projects = readProjects().map((project) => {
    const sessions = readSessions(project.path).map((record) => {
      const session = live.get(record.tmux)
      const hook = hooks.get(`session:${record.tmux}`)

      // ONE capture per live session, as before — the preview and the question
      // are two readings of the same screen, and taking it twice would double
      // the tmux calls this poll makes for nothing.
      const raw = withPreview && session ? tmux.captureRaw(record.tmux) : null
      const screen = raw ? readChoices(raw) : null

      // Not running is not a colour: a record with no session behind it is a
      // thing you could start, not a thing that wants something.
      const resolved = session
        ? resolve(hook, screen, seen[`session:${record.tmux}`])
        : { state: "idle", asking: false }

      return {
        id: record.id,
        name: record.name,
        tmux: record.tmux,
        claudeSID: record.claudeSID ?? session?.sid ?? hook?.sid ?? null,
        lastUsed: record.lastUsed ? cocoaToMillis(record.lastUsed) : null,
        live: Boolean(session),
        attached: session?.attached ?? false,
        state: resolved.state,
        asking: resolved.asking,
        // One line, already chosen: the question when there is one, otherwise
        // the last thing the session said. The phone should not have to guess
        // which of the two it is holding.
        headline: screen?.question || (raw ? lastSpokenLine(raw) : null),
      }
    })
    sessions.sort((a, b) => (b.lastUsed ?? 0) - (a.lastUsed ?? 0))
    return { ...project, sessions }
  })

  return { projects, generatedAt: Date.now() }
}

/** Locate a tab by tmux name across all projects. */
export function locate(tmuxName) {
  for (const project of readProjects()) {
    const record = readSessions(project.path).find((r) => r.tmux === tmuxName)
    if (record) return { project, record }
  }
  return null
}
