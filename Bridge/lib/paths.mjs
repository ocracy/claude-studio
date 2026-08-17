// Mirror of Sources/ClaudeStudio/Core/Paths.swift.
//
// Every location the bridge touches is declared here and nowhere else. The app
// and the bridge write the same files; if the two ever disagree about a path,
// sessions silently fork into two half-states. One list, one source of truth.

import { homedir, userInfo } from "node:os"
import { join } from "node:path"
import { mkdirSync, renameSync, writeFileSync } from "node:fs"

const home = homedir()

export const appSupport = join(home, "Library", "Application Support", "Claude Studio")

export const recents = join(appSupport, "recents.json")
export const tmuxConfig = join(appSupport, "tmux.conf")
export const sessionStateDir = join(appSupport, "session-state")
export const tokenFile = join(appSupport, "bridge-token")

// Fixed socket, never `-L`: the GUI app and a login shell resolve TMUX_TMPDIR
// differently, which would spawn two separate tmux servers. See Tmux.swift.
export const tmuxSocket = `/tmp/claude-studio-${userInfo().uid}.sock`

/** `<project>/.cs/sessions.json` — the tab records, a flat array. */
export function projectSessions(projectPath) {
  return join(projectPath, ".cs", "sessions.json")
}

/** Hook state for a tab, keyed by `CS_TAB_ID` (= `session:<tmux name>`). */
export function sessionState(tabID) {
  return join(sessionStateDir, `${tabID}.json`)
}

/**
 * Same contract as Paths.writeAtomically: write a sibling temp file, then
 * rename over the destination. A reader never observes a half-written file,
 * and the app polls these files continuously.
 */
export function writeAtomically(dest, data) {
  mkdirSync(join(dest, ".."), { recursive: true })
  const tmp = `${dest}.${process.pid}.tmp`
  writeFileSync(tmp, data, { mode: 0o644 })
  renameSync(tmp, dest)
}
