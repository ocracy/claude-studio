// What Claude is asking, read off the screen.
//
// When a session hands the turn back it is often not with a question in prose
// but with a numbered list — "1. Yes  2. Yes, and don't ask again  3. No". On
// the phone that is one tap's worth of decision buried behind: open the app,
// wait for the terminal to attach, find the keyboard, type a digit. So the
// notification carries the choices as buttons and the answer never opens
// anything.
//
// The screen is the only place these live. There is no hook payload for them,
// no file, no API: Claude Code draws the prompt into the TUI and waits for a
// keypress. So this reads the pane — deliberately conservatively. Everything
// here is a heuristic over someone else's interface, and a wrong guess would
// put a button on a notification that sends a digit into a text prompt. When
// the shape is not unmistakable, it returns nothing and the notification stays
// exactly as it was.

/**
 * Box drawing and the padding tmux returns — but NOT the selection caret,
 * which is the one mark that tells a prompt apart from prose (see `SELECTED`).
 */
function stripFrame(line) {
  return line
    .replace(/[│┃|]/gu, " ")
    .replace(/^[\s╭╰─━═┌└]*/u, "")
    .replace(/[\s╮╯─━═┐┘]*$/u, "")
    .trim()
}

const OPTION = /^(?:[❯›‣>]\s*)?(\d{1,2})[.)]\s+(\S.*)$/u

/**
 * A caret in front of an option: the TUI's cursor, drawn on whichever choice is
 * currently selected.
 *
 * This is the discriminator the whole reader rests on. Claude writes numbered
 * lists in its ANSWERS all the time — "here are the three options I considered"
 * — and one of those, sitting above the input box, is shape-identical to a
 * prompt. Only a prompt has something selected. Without this check the phone
 * would offer buttons that type a digit into a text box.
 */
const SELECTED = /^[❯›‣>]\s*\d{1,2}[.)]\s/u

/**
 * The numbered options at the bottom of the screen, if that is what this is.
 *
 * Requirements, all of them deliberate:
 *   • at least two options, numbered from 1 and consecutive — a stray "1." in
 *     prose or a numbered list Claude printed as part of an ANSWER fails this;
 *   • they must sit in the last screenful, adjacent to each other;
 *   • nothing but the options between the first and the last of them.
 *
 * @returns {{question: string, options: {number: number, label: string}[]} | null}
 */
export function readChoices(rawLines) {
  const lines = rawLines.map(stripFrame)

  // Walk up from the bottom to the last option line, then keep walking while
  // the numbers count down. A prompt is the last thing drawn, so anything that
  // matches further up is not what the session is waiting on.
  let end = -1
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    if (OPTION.test(lines[index])) { end = index; break }
    // A few lines of footer ("esc to interrupt") may follow the box.
    if (end === -1 && lines.length - index > 8) return null
  }
  if (end === -1) return null

  const collected = []
  let anySelected = false
  for (let index = end; index >= 0; index -= 1) {
    const match = lines[index].match(OPTION)
    if (match) {
      if (SELECTED.test(lines[index])) anySelected = true
      collected.unshift({ number: Number(match[1]), label: match[2].trim(), at: index })
      continue
    }
    // Blank lines inside the box are fine; anything else ends the block.
    if (lines[index] === "") continue
    break
  }

  if (collected.length < 2 || !anySelected) return null
  const numbered = collected.every((option, index) => option.number === index + 1)
  if (!numbered) return null

  // The question is the last thing said above the list. Claude's prompts put a
  // title there ("Bash command", "Edit file"), so a couple of lines are joined
  // rather than only the nearest one.
  const question = []
  for (let index = collected[0].at - 1; index >= 0 && question.length < 2; index -= 1) {
    const line = lines[index]
    if (!line) { if (question.length) break; else continue }
    if (OPTION.test(line)) break
    question.unshift(line)
  }

  return {
    question: question.join(" — ").slice(0, 160),
    options: collected.map(({ number, label }) => ({ number, label: label.slice(0, 60) })),
  }
}

/**
 * The last thing the session actually SAID.
 *
 * Not "the last non-empty line": below Claude's answer sit the input box, the
 * spinner's epitaph ("✻ Cogitated for 4m 20s"), the mode footer and the token
 * hint — four lines of furniture, none of which the session said. Showing one of
 * those as the preview under a tab is how every row came to read "⏵⏵ auto mode
 * on (shift+tab to cycle)".
 *
 * The twin of `PaneReader.lastSpokenLine` in Swift; the two must stay in step,
 * or the phone and the Mac describe the same session differently.
 *
 * @param {string[]} rawLines  the pane exactly as tmux painted it
 */
export function lastSpokenLine(rawLines) {
  for (let index = rawLines.length - 1; index >= 0; index -= 1) {
    const raw = rawLines[index]
    const text = stripFrame(raw)
    if (!text || isFurniture(raw, text)) continue
    return text.length > 120 ? `${text.slice(0, 120)}…` : text
  }
  return null
}

/**
 * Is a turn actually in flight?
 *
 * Claude draws "esc to interrupt" for exactly as long as there is something to
 * interrupt, which makes it the one honest witness to green. The hook is not:
 * `Stop` never fires for a session killed mid-turn, so its file says `working`
 * forever and the dot stays green over a conversation that ended hours ago.
 *
 * The twin of `PaneReader.Screen.isWorking`.
 */
export function looksBusy(rawLines) {
  return rawLines.some((line) => line.toLowerCase().includes("esc to interrupt"))
}

const FOOTER = [
  "esc to interrupt", "shift+tab to cycle", "? for shortcuts", "new task?",
  "auto mode on", "bypass permissions", "ctrl+c to exit", "to save ", "for agents",
]

/**
 * The RAW line matters as well as the stripped one: the rule that carries the
 * conversation's title (`──────── fix-openai-batch ──`) is nothing but frame,
 * and stripping the frame off it leaves an ordinary-looking sentence that was
 * never said.
 */
function isFurniture(raw, text) {
  if (/^[─━═╭╮╰╯┌┐└┘├┤]/u.test(raw.trim())) return true
  if (/^[❯›‣>]/u.test(text)) return true
  // The spinner, its epitaph, and the tool-output gutter.
  if (/^[✻✳✶✽✢·*⏵⏸⎿⠂⠄⠈⠐⠠⡀⢀⠁⠉⠙⠹⠸⠼⠴⠦⠧⠇⠏]/u.test(text)) return true
  if (text.startsWith("/") && text.length <= 30) return true
  if (/^[─━═\-·\s]*$/u.test(text)) return true
  const lower = text.toLowerCase()
  return FOOTER.some((hint) => lower.includes(hint))
}

/**
 * The buttons a notification carries.
 *
 * Android allows two (`Notification.maxActions`), and with three options the
 * pair worth having is the first and the LAST: Claude's lists run yes → yes and
 * stop asking → no, so those two are the decision and the middle one is a
 * preference. iOS shows no actions at all and falls through to the tap, which
 * is why the notification must still make sense without them.
 */
export function choiceActions(choices) {
  if (!choices?.options?.length) return []
  const first = choices.options[0]
  const last = choices.options[choices.options.length - 1]
  const picked = first.number === last.number ? [first] : [first, last]
  return picked.map((option) => ({
    action: `key:${option.number}`,
    title: option.label.length > 24 ? `${option.label.slice(0, 23)}…` : option.label,
  }))
}
