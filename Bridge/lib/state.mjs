// Assemble the one payload the phone needs: every project, every tab, and what
// each tab is doing right now.
//
// Nothing is invented here. Projects come from the app's recents list, tabs from
// each project's own records, liveness from tmux, and the working/waiting state
// from the files Claude Code's hook writes. The bridge is a reader; the app
// remains the author of all of it.

import { readdirSync, readFileSync } from "node:fs"
import { basename } from "node:path"
import { cocoaToMillis, readSessions } from "./sessions.mjs"
import { recents, sessionStateDir } from "./paths.mjs"
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

/**
 * @param {boolean} withPreview  capture pane contents (one tmux call per live
 *   session — fine for a list of tabs, skipped when the caller only needs badges)
 */
export function snapshot({ withPreview = true } = {}) {
  const live = tmux.list()
  const hooks = readHookStates()

  const projects = readProjects().map((project) => {
    const sessions = readSessions(project.path).map((record) => {
      const session = live.get(record.tmux)
      const hook = hooks.get(`session:${record.tmux}`)
      return {
        id: record.id,
        name: record.name,
        tmux: record.tmux,
        claudeSID: record.claudeSID ?? session?.sid ?? hook?.sid ?? null,
        lastUsed: record.lastUsed ? cocoaToMillis(record.lastUsed) : null,
        live: Boolean(session),
        attached: session?.attached ?? false,
        // No hook file means no Claude process has reported in: the tab exists
        // as a record but is not running.
        state: hook?.state === "working" ? "working" : hook?.state === "waiting" ? "waiting" : "idle",
        preview: withPreview && session ? tmux.capture(record.tmux) : [],
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
