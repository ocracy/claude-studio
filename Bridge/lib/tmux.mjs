// Thin wrappers over the same tmux server the app drives.
//
// Mirrors Sources/ClaudeStudio/Core/Tmux.swift: same socket, same config file,
// same `@cs_*` session options. Anything that diverges here shows up as a tab
// the Mac cannot see, so the constants live in paths.mjs and the flags below
// are deliberate — see the comments on attachArgs and startDetached.

import { execFileSync, execSync } from "node:child_process"
import { existsSync } from "node:fs"
import { tmuxConfig, tmuxSocket } from "./paths.mjs"

const CANDIDATES = [
  "/opt/homebrew/bin/tmux",
  "/usr/local/bin/tmux",
  "/opt/local/bin/tmux",
  "/usr/bin/tmux",
]

export const tmuxPath = (() => {
  for (const candidate of CANDIDATES) if (existsSync(candidate)) return candidate
  try {
    // Login + interactive: PATH lives in .zshrc, and a launchd-spawned process
    // inherits almost none of it.
    return execSync('/bin/zsh -l -i -c "command -v tmux"', { encoding: "utf8" }).trim()
  } catch {
    return null
  }
})()

function run(args) {
  try {
    const stdout = execFileSync(tmuxPath, ["-S", tmuxSocket, ...args], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    })
    return { ok: true, stdout }
  } catch (error) {
    return { ok: false, stdout: error.stdout ?? "", stderr: error.stderr ?? "" }
  }
}

/** Single-quote for a shell, escaping embedded quotes. Mirrors Shell.quoted. */
export function quoted(text) {
  return `'${String(text).replaceAll("'", `'\\''`)}'`
}

const FORMAT = [
  "#{session_name}",
  "#{@cs_project}",
  "#{@cs_title}",
  "#{@cs_sid}",
  "#{session_attached}",
  "#{@cs_used}",
].join("\t")

/** Live sessions on the shared socket, keyed by session name. */
export function list() {
  const result = run(["list-sessions", "-F", FORMAT])
  if (!result.ok) return new Map() // no server running yet — not an error
  const sessions = new Map()
  for (const line of result.stdout.split("\n")) {
    if (!line.trim()) continue
    const [name, project, title, sid, attached, used] = line.split("\t")
    sessions.set(name, {
      name,
      project,
      title,
      sid: sid || null,
      attached: Number(attached) > 0,
      used: used ? Number(used) : null,
    })
  }
  return sessions
}

export function exists(name) {
  return run(["has-session", "-t", name]).ok
}

export function kill(name) {
  return run(["kill-session", "-t", name]).ok
}

export function setOption(name, key, value) {
  run(["set-option", "-t", name, key, String(value)])
}

/** Tag a session so the app recognises it as ours (it filters on @cs_project). */
export function tag(name, { project, title, sid }) {
  if (project) setOption(name, "@cs_project", project)
  if (title) setOption(name, "@cs_title", title)
  if (sid) setOption(name, "@cs_sid", sid)
  setOption(name, "@cs_used", Math.floor(Date.now() / 1000))
}

// Chrome the TUI paints every frame: box rules, the prompt caret, the hint
// footer. None of it says what Claude is doing, so it is dropped from previews.
const CHROME = /^[\s─━═╌•]*$/u

/**
 * The last few meaningful lines of the pane, for the preview under each tab in
 * the list. `capture-pane` returns the whole visible screen, so the trimming
 * happens here rather than via `-S`.
 */
export function capture(name, lines = 2) {
  const result = run(["capture-pane", "-p", "-t", name])
  if (!result.ok) return []
  return result.stdout
    .split("\n")
    .map((line) => line.trimEnd())
    .filter((line) => line.length && !CHROME.test(line) && !line.startsWith("❯"))
    .slice(-lines)
}

const CHUNK = 400

/**
 * Type text into the session as if it came from the keyboard.
 *
 * `-l` sends the text literally, so a prompt beginning with `/init` reaches
 * Claude as text rather than being parsed as a tmux key name. Newlines become
 * `\` + Enter, which is exactly the Shift+Enter continuation the app installs
 * in TerminalEngine.installKeyMonitor — sending a bare Enter mid-prompt would
 * submit half the message.
 */
export function sendText(name, text) {
  const lines = text.replaceAll("\r\n", "\n").split("\n")
  lines.forEach((line, index) => {
    for (let at = 0; at < line.length; at += CHUNK) {
      run(["send-keys", "-t", name, "-l", "--", line.slice(at, at + CHUNK)])
    }
    if (index < lines.length - 1) {
      run(["send-keys", "-t", name, "-l", "--", "\\"])
      run(["send-keys", "-t", name, "Enter"])
    }
  })
}

/** A named key: Enter, Escape, Up, C-c … */
export function sendKey(name, key) {
  run(["send-keys", "-t", name, key])
}

/**
 * Create a session that runs a task without anyone watching — "give Claude a
 * job and put the phone away".
 *
 * Wrapped in `/bin/zsh -l -i -c` because a detached session inherits the tmux
 * server's environment, which under launchd has none of the user's PATH; `-i`
 * is required since PATH is exported from .zshrc. The CS_* variables are what
 * make the Claude Code hook report state for this tab, so the phone (and the
 * Mac) can see it working and can resume it later.
 */
export function startDetached(name, projectPath, env, claudeCommand) {
  const inner = `cd ${quoted(projectPath)} && exec ${claudeCommand}`
  const wrapped = `/bin/zsh -l -i -c ${quoted(inner)}`
  const args = ["-f", tmuxConfig, "new-session", "-d", "-s", name]
  for (const [key, value] of Object.entries(env).sort()) {
    args.push("-e", `${key}=${value}`)
  }
  args.push(wrapped)
  return run(args).ok
}
