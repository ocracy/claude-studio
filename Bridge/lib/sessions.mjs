// Read and mutate `<project>/.cs/sessions.json` — the tab records the app owns.
//
// Two rules govern everything here:
//
//  1. Never write a remembered copy of the array. The app writes this same file
//     whenever a tab is renamed or a session_id arrives from the hook. If the
//     bridge held the list in memory and wrote it back wholesale, every such
//     app-side edit between our read and our write would be erased. So each
//     mutation re-reads from disk, applies one change, writes back.
//
//  2. Dates are Cocoa dates. Swift's default Date encoding is seconds since
//     2001-01-01, not the Unix epoch. Writing epoch seconds here would shift
//     every timestamp forward by ~31 years and reorder the app's session list.

import { readFileSync } from "node:fs"
import { projectSessions, writeAtomically } from "./paths.mjs"
import { newSessionName } from "./shortid.mjs"

/** Seconds between 1970-01-01 and Cocoa's 2001-01-01 reference date. */
const COCOA_EPOCH_OFFSET = 978_307_200

export const nowCocoa = () => Date.now() / 1000 - COCOA_EPOCH_OFFSET
export const cocoaToMillis = (value) => (value + COCOA_EPOCH_OFFSET) * 1000

/** The records for one project, or `[]` if the file is absent or unreadable. */
export function readSessions(projectPath) {
  try {
    const parsed = JSON.parse(readFileSync(projectSessions(projectPath), "utf8"))
    return Array.isArray(parsed) ? parsed : []
  } catch {
    // Missing file is the normal state for a project with no tabs yet; a
    // malformed one is the app mid-write. Either way an empty list is safe —
    // we only ever add to what we just read.
    return []
  }
}

function writeSessions(projectPath, records) {
  // Keys are emitted sorted to match the app's [.prettyPrinted, .sortedKeys]
  // encoder, so a bridge write and an app write produce the same diff shape.
  const body = JSON.stringify(records, null, 2)
  writeAtomically(projectSessions(projectPath), body + "\n")
}

function sorted(record) {
  const out = {}
  for (const key of Object.keys(record).sort()) out[key] = record[key]
  return out
}

/** Re-read, apply `change` to the fresh array, write back. See rule 1 above. */
function mutate(projectPath, change) {
  const records = readSessions(projectPath)
  const result = change(records)
  writeSessions(projectPath, records.map(sorted))
  return result
}

/**
 * Append a new tab record. The tmux session itself is NOT created here — it is
 * born on first attach (`new-session -A`), so that it takes its geometry from
 * the phone rather than from a detached 80x24 default.
 */
export function addSession(projectPath, projectShortID, name) {
  const { id, tmux } = newSessionName(projectShortID)
  const record = { id, name, tmux, lastUsed: nowCocoa() }
  mutate(projectPath, (records) => records.push(record))
  return record
}

export function removeSession(projectPath, tmuxName) {
  return mutate(projectPath, (records) => {
    const index = records.findIndex((r) => r.tmux === tmuxName)
    if (index < 0) return false
    records.splice(index, 1)
    return true
  })
}

export function touchSession(projectPath, tmuxName) {
  mutate(projectPath, (records) => {
    const record = records.find((r) => r.tmux === tmuxName)
    if (record) record.lastUsed = nowCocoa()
  })
}

export function findSession(projectPath, tmuxName) {
  return readSessions(projectPath).find((r) => r.tmux === tmuxName)
}
