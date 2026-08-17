<h1 align="center">Claude Studio</h1>

<p align="center">
  <b>One screen for every project — persistent Claude Code sessions, skills, scheduled runs, dev services and terminals.</b><br>
  Open a folder the way you would in an IDE; everything else lives in the same window.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-6-orange" alt="Swift 6">
  <img src="https://img.shields.io/badge/UI-SwiftUI-purple" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
</p>

---

Claude Studio is a native macOS workspace for people who run several Claude Code
sessions across several projects all day. Instead of a graveyard of terminal tabs,
each project gets one window: its sessions, its skills, its scheduled runs, its dev
services and its shells — all one keystroke away.

No Electron, no telemetry, no background service. One small native app on your own
machine.

## Features

### Persistent Claude Code sessions
Sessions run inside a dedicated **tmux** server, so they outlive the app. Quit, come
back tomorrow, and the conversation is exactly where you left it. Name a session by
double-clicking its title; close it and the record stays, so reopening it resumes the
same conversation through `claude --resume`. A session manager lists everything the
project owns — alive, resumable or disposable.

### Attention that reaches you
Claude Studio installs Claude Code hooks, so the app knows when a session is working
and when it is waiting for you: a dot lights up on the exact session, one soft tone
plays, the Dock icon gets a badge. All of it is configurable, including which system
sound.

### Skills, read the way Claude writes them
The sidebar lists the project's `.claude/skills` — plus your global ones, shadowed by
project skills exactly as Claude resolves them — with their frontmatter description.
Skill bodies render as markdown. Run one in a visible session to watch it work, or in
the background to stay out of its way. The "+" opens a session that writes a new
skill, leaning on Anthropic's own `skill-development` skill when it is installed.

### Scheduled runs that survive a quit
Any skill can be scheduled hourly, daily or weekly. Schedules are bound to
**launchd**, so they fire whether or not the app is running. Each run writes a
markdown report into `.cs/runs/<skill>/`, and the app shows the history with status,
timestamp and produced output side by side. There is no database: the reports *are*
the state, so a run that happened while the app was closed simply appears.

### MCP servers, from Claude's own configuration
The MCP section lists every server Claude Code will load for this project, read
straight from the three places Claude keeps them — `~/.claude.json` (global), the
project's `.mcp.json` (shared with the team) and the project's local entry (private
to this machine) — with a badge saying which. Adding and removing goes through
`claude mcp add|remove`, so Claude's own validation and scope rules stay in charge.
"Check connections" runs `claude mcp list` and marks each server connected, needing
authentication or failed; HTTP servers can be signed in to from the list.

### One-shot commands
`npm run build`, `php artisan optimize`, a deploy script — commands live in their own
sidebar section, own no port and never auto-start. Press one and it runs in its own
tab, in the project directory, with the exit code shown in place; press again to
re-run. Or run it in the background and get told when it finishes.

### Dev services
`npm run dev`, `php artisan serve`, workers, queues — start, stop and restart them
with port-aware status, auto-start on open, crash detection, and detection of
services already started outside the app.

### Terminals that remember
Manually opened shells are tmux-backed too: same directory, same history, next time.
Drop a file, folder or image onto a terminal and its path is typed in — which is how
Claude Code reads images and files.

### Fast by construction
Terminal views live in the runtime, not in the view tree. Switching tabs only chooses
which `NSView` is attached — the process, the scroll position and the buffer are
never touched. Switching stays instant no matter how much scrollback you have.

## Install

Download the latest build from [Releases](https://github.com/ocracy/claude-studio/releases),
move `Claude Studio.app` into `/Applications`, then clear the quarantine flag (the app
is ad-hoc signed):

```bash
xattr -cr "/Applications/Claude Studio.app" && open -a "Claude Studio"
```

Or build from source:

```bash
brew install tmux          # required for persistent sessions
git clone https://github.com/ocracy/claude-studio && cd claude-studio
./install.sh               # builds and installs into /Applications
```

Open a project straight from the shell, or drop a folder on the app icon:

```bash
open -a "Claude Studio" ~/dev/my-project
```

### Updating

The app checks GitHub for a newer release at launch. When one exists an **Update**
badge appears in the top bar; **Settings → About** downloads it, replaces the bundle
and restarts the app.

## Project settings: `.cs/`

Like an IDE's project folder, everything Claude Studio knows about a project lives
inside the project:

```
<project>/
├── .claude/skills/…        # skills (Claude Code's own layout; untouched)
├── .mcp.json               # MCP servers (Claude Code's own file; untouched)
└── .cs/
    ├── services.json       # services            ← share with your team
    ├── commands.json       # one-shot commands   ← share with your team
    ├── schedules.json      # scheduled runs      ← share with your team
    ├── terminals.json      # terminals           ← share with your team
    ├── sessions.json       # session records     (machine specific)
    ├── settings.json       # interface prefs     (machine specific)
    └── runs/<skill>/       # run reports (.md) + .state.json
```

Each section is its own file, so resizing your sidebar never dirties a file your team
shares. Every file is plain, readable JSON you can edit by hand.

```json
// .cs/services.json
[
  { "name": "frontend", "command": "npm run dev", "port": 5173, "autoStart": true }
]
```

```json
// .cs/schedules.json
[
  { "skill": "release-notes", "frequency": "daily", "hour": 2, "minute": 0, "enabled": true }
]
```

## Skills and run reports

Skills are read in Claude Code's own format — nothing is converted:

```
.claude/skills/<name>/SKILL.md     or     .claude/skills/<name>.md
```

A skill run receives this environment:

| Variable | Meaning |
|---|---|
| `CS_REPORT_FILE` | Where to write the report |
| `CS_RUN_DIR` | This skill's report directory |
| `CS_RUN_MODE` | `manual` \| `scheduled` |
| `CS_LAST_REPORT`, `CS_LAST_STATUS`, `CS_LAST_SUMMARY` | Context from the previous run |

A report starts with frontmatter, which is what the app builds its table from:

```markdown
---
run_at: 2026-08-17T02:00:00Z
status: ok          # ok | warning | failed
summary: 12 pull requests summarised, no warnings
duration_sec: 8
---
```

## Keyboard

| | |
|---|---|
| ⌘O | Open folder |
| ⇧⌘N | New window |
| ⌘N | New Claude session |
| ⌘T | New tab (a session on a Claude tab, a terminal otherwise) |
| ⇧⌘T | New terminal |
| ⌘, | Settings |
| ⌘P | Command palette (sessions, skills, commands, services, MCP, workspaces) |
| ⌘1…⌘9 | Go to tab |
| ⌘W | Close tab |
| ⇧⌘] / ⇧⌘[ | Next / previous tab |

**Multi-line input:** `/terminal-setup` cannot run inside tmux, so the mapping is
built into the app — **Shift+Enter** and **Option+Enter** insert a newline.

## Architecture

- **Swift 6 · SwiftUI · [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) · tmux · launchd**
- `Core/` holds the logic (`TerminalEngine`, `Tmux`, `Scheduler`, `SkillStore`,
  `ProjectStore`, `Updater`); `Views/` is presentation only.
- Which sessions are **alive** comes from tmux, the single source of truth; a
  session's **name and conversation id** live in `.cs/sessions.json`, which is how a
  closed session comes back under the same name.
- Windows are managed in AppKit rather than through SwiftUI's `WindowGroup`, so the
  number and identity of windows stay exact.
- Notifications go through `osascript`: `UNUserNotificationCenter` is not reliable in
  an ad-hoc signed app.

## Claude Code hooks

To show whether a session is working or waiting, one hook is merged into
`~/.claude/settings.json` — idempotently, leaving your existing hooks alone. The
script is a no-op outside Claude Studio: without `CS_TAB_ID` it exits immediately, so
it has zero effect on your other Claude sessions.

## License

MIT
