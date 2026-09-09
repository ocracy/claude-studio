// Ready-made phrases for the phone's key row.
//
// A phone is bad at exactly one thing, and it is the thing a Claude session is
// made of: typing. What you actually want to say from one is short, repeated and
// always the same — "push what you did and deploy it" — so it is worth saying
// once and pressing thereafter.
//
// Stored on the MAC, not in the browser: the same list then reaches every phone
// pointed at this machine, and it survives clearing the site data, which an
// installed web app gives you no way to undo.

import { readFileSync } from "node:fs"
import { randomUUID } from "node:crypto"
import { snippets as file, writeAtomically } from "./paths.mjs"

const MAX = 40

export function readSnippets() {
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8"))
    if (!Array.isArray(parsed)) return []
    return parsed.filter((entry) => entry?.id && entry?.text)
  } catch {
    return []
  }
}

function write(list) {
  writeAtomically(file, JSON.stringify(list, null, 2))
}

/**
 * @param {string} name  what the button says
 * @param {string} text  what gets typed
 * @param {boolean} send  press Enter afterwards
 */
export function addSnippet({ name, text, send }) {
  const clean = String(text ?? "").trim()
  if (!clean) return null
  const entry = {
    id: randomUUID(),
    // The name is what fits on a button; the text is what it means. An unnamed
    // one falls back to its own first words rather than being refused — the
    // point of this list is to be quicker than typing, including to add to.
    name: String(name ?? "").trim().slice(0, 32) || clean.slice(0, 24),
    text: clean.slice(0, 2000),
    send: send !== false,
  }
  const list = readSnippets().filter((existing) => existing.id !== entry.id)
  list.push(entry)
  write(list.slice(-MAX))
  return entry
}

export function removeSnippet(id) {
  const list = readSnippets()
  const next = list.filter((entry) => entry.id !== id)
  if (next.length === list.length) return false
  write(next)
  return true
}
