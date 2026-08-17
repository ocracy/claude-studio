// Watch what the sessions are doing and push a notification when one finishes.
//
// The signal already exists: Claude Code's hook writes a state file per tab, and
// `Stop` / `Notification` both land as "waiting" — Claude has handed the turn
// back. What matters is the TRANSITION into that state. Notifying on the state
// itself would fire every poll for as long as the session sat idle.
//
// Polled rather than watched for the same reason the app polls: these files are
// written by processes outside this one (hooks under tmux, launchd runs), and a
// missed event is worse than a a slightly late one.

import { snapshot } from "./state.mjs"
import { notify } from "./push.mjs"

const INTERVAL = 2500

/** tmux name → last state seen, so only changes are acted on. */
const lastSeen = new Map()

let timer = null

export function start() {
  if (timer) return
  // Seed from the current state: a bridge restart must not announce every
  // session that happens to be waiting right now.
  prime()
  timer = setInterval(tick, INTERVAL)
  timer.unref?.()
}

function prime() {
  for (const project of snapshot({ withPreview: false }).projects) {
    for (const session of project.sessions) lastSeen.set(session.tmux, session.state)
  }
}

async function tick() {
  let current
  try {
    current = snapshot({ withPreview: false })
  } catch {
    return
  }

  const alive = new Set()

  for (const project of current.projects) {
    for (const session of project.sessions) {
      alive.add(session.tmux)
      const previous = lastSeen.get(session.tmux)
      lastSeen.set(session.tmux, session.state)

      // Only the moment of handing the turn back, and only from a session that
      // was actually working — an idle tab that gets opened reports "waiting"
      // straight away and is not news.
      if (session.state === "waiting" && previous === "working") {
        await notify({
          title: `${session.name} is waiting`,
          body: `${project.name} — Claude finished and needs you.`,
          tmux: session.tmux,
          project: project.path,
        }).catch(() => {})
      }
    }
  }

  for (const name of lastSeen.keys()) {
    if (!alive.has(name)) lastSeen.delete(name)
  }
}
