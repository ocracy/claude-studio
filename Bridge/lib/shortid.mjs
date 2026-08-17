// Mirror of Project.shortID in Sources/ClaudeStudio/Models/Models.swift.
//
// This value names every tmux session and launchd job belonging to a project,
// so it MUST be stable across processes and machines-in-time. Swift's
// `hashValue` is seeded per process and would orphan yesterday's sessions on
// the next launch, which is why the app uses FNV-1a over the project path —
// and why this file reimplements FNV-1a rather than reaching for any
// convenient JS hash.

const MASK = 0xffffffffffffffffn
const OFFSET_BASIS = 0xcbf29ce484222325n
const PRIME = 0x100000001b3n

/** FNV-1a over the UTF-8 bytes of the project path, wrapped to 64 bits. */
function fnv1a(text) {
  let hash = OFFSET_BASIS
  for (const byte of Buffer.from(text, "utf8")) {
    hash = (hash ^ BigInt(byte)) & MASK
    hash = (hash * PRIME) & MASK
  }
  return hash
}

/**
 * `<slug>-<hash>` — e.g. `claude-studio-rz3sp6`.
 * The slug comes from the display name (letters and digits kept, everything
 * else folded to `-`, capped at 16), the suffix from the path hash in base 36.
 */
export function shortID(projectPath, name) {
  const slug = [...name.toLowerCase()]
    .map((c) => (/[\p{L}\p{N}]/u.test(c) ? c : "-"))
    .slice(0, 16)
    .join("")
  return `${slug}-${fnv1a(projectPath).toString(36).slice(0, 6)}`
}

/**
 * Mirror of SessionRecord.make: `cs-<shortID>-<first 8 of the record's UUID>`.
 * Returns both halves because the caller has to persist the same UUID as the
 * record's `id`.
 */
export function newSessionName(projectShortID) {
  const id = crypto.randomUUID().toUpperCase()
  return { id, tmux: `cs-${projectShortID}-${id.slice(0, 8).toLowerCase()}` }
}

/**
 * Fail-fast guard, run at startup.
 *
 * If this drifts from the Swift implementation the bridge would happily create
 * sessions under a shortID the app does not recognise — the app filters tmux
 * sessions by `@cs_project`, so those tabs would simply never appear on the
 * Mac. Better to refuse to start than to quietly split the workspace in two.
 */
export function assertMatchesSwift() {
  const cases = [
    ["/Users/kerembekman/www/claude-studio", "claude-studio", "claude-studio-rz3sp6"],
    ["/Users/kerembekman/www/blockgain/maatrics", "maatrics", "maatrics-2ciw68"],
  ]
  for (const [path, name, expected] of cases) {
    const actual = shortID(path, name)
    if (actual !== expected) {
      throw new Error(
        `shortID drifted from Project.shortID: ${path} produced "${actual}", expected "${expected}"`,
      )
    }
  }
}
