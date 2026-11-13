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
import * as tmux from "./tmux.mjs"
import { choiceActions, lastSpokenLine, readChoices } from "./choices.mjs"

const INTERVAL = 2500

/** tmux name → last state seen, so only changes are acted on. */
const lastSeen = new Map()
const turnStarted = new Map()

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
      if (session.state === "working" && previous !== "working") {
        turnStarted.set(session.tmux, Date.now())
      }

      // Only the moment of handing the turn back, and only from a session that
      // was actually working — an idle tab that gets opened reports "waiting"
      // straight away and is not news.
      if (session.state === "waiting" && previous === "working") {
        // If it is waiting on a numbered choice, the notification carries the
        // choice: answering it should not cost an app launch, a terminal
        // attach and a keyboard. Read once, here — the pane is a tmux call and
        // this loop runs every 2.5 seconds for every session.
        const raw = tmux.captureRaw(session.tmux)
        const choices = readChoices(raw)
        const asking = session.asking || Boolean(choices?.options?.length)
        const started = turnStarted.get(session.tmux)
        await notify({
          title: asking ? `${session.name} is waiting` : `${session.name} finished`,
          body: choices?.question || lastSpokenLine(raw) || `${project.name} — Claude finished and needs you.`,
          tmux: session.tmux,
          project: project.path,
          actions: choiceActions(choices),
          finished: !asking,
          elapsed: started ? (Date.now() - started) / 1000 : 0,
        }).catch(() => {})
      }
    }
  }

  for (const name of lastSeen.keys()) {
    if (!alive.has(name)) lastSeen.delete(name)
  }
  for (const [name] of turnStarted) {
    const state = lastSeen.get(name)
    if (state !== "working" && state !== "waiting") turnStarted.delete(name)
  }
}
