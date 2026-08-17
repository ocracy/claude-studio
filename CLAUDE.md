# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

**Claude Studio** — a multi-project development workspace for macOS
(Swift 6 + SwiftUI + SwiftTerm). Open a folder and the window becomes that project's
studio: Claude Code sessions (persistent through tmux), `.claude/skills`, scheduled
runs (launchd), dev services and terminals.

The app's language is **English** — user-facing strings, code and comments alike.

## Commands

```bash
swift build      # fast compile check
./build.sh       # release build + "Claude Studio.app" bundle
./install.sh     # build + install into /Applications + launch
./dist.sh        # release artifact: ClaudeStudio.zip (asset name the updater expects)
```

Release flow: bump `VERSION` → `./dist.sh` → commit and push →
`gh release create v<VERSION> ClaudeStudio.zip --title "Claude Studio v<VERSION>" --notes "…"`.
`VERSION` is the single source of truth; `build.sh` and `dist.sh` both read it, and
`Updater` compares the installed `CFBundleShortVersionString` against the release tag.

## Layout

```
Sources/ClaudeStudio/
├── main.swift             # entry point (NSApplication; WindowGroup is NOT used)
├── ClaudeStudioApp.swift  # AppDelegate + main menu
├── Theme.swift            # single design source: color, typography, shared controls
├── Models/Models.swift    # Project, StudioTab, SessionRecord, Skill, Schedule, Service,
│                          # ClaudeCommand, ProjectScript, SkillRun
├── Core/
│   ├── Paths.swift            # ~/Library/.../Claude Studio  +  <project>/.cs
│   ├── Shell.swift            # PATH snapshot, process helpers, port probes
│   ├── Tmux.swift             # session persistence
│   ├── TerminalEngine.swift   # SwiftTerm view cache, spawning, service status, attention
│   ├── ProjectConfig.swift    # .cs/*.json + launchd sync
│   ├── Skills.swift           # .claude/skills scanner + frontmatter + directory watcher
│   ├── MCP.swift              # MCP servers: reads Claude's config, mutates via claude mcp
│   ├── ClaudeCommands.swift   # .claude/commands scanner (slash commands)
│   ├── Runs.swift             # run reports (the reports are the state)
│   ├── Scheduler.swift        # runner script + launchd plist
│   ├── HookBridge.swift       # Claude Code hooks → session state
│   ├── ClaudeTranscripts.swift# resume availability check
│   ├── Settings.swift         # user preferences (sound, notifications, terminal)
│   ├── Updater.swift          # GitHub release self-updater
│   ├── Recents.swift          # recent projects + folder picker
│   └── StudioModel.swift      # all state for one window
└── Views/                 # Windows, RootView, WelcomeView, StudioView, Sidebar, Detail,
                           # Sheets, SettingsWindow, CommandPalette, Markdown, TerminalHost
```

## Hard-won rules

- **Windows**: do NOT use `WindowGroup`. The AppKit `WindowManager` keeps the number
  and identity of windows deterministic; SwiftUI's implicit window creation produced
  duplicates when opening a folder.
- **tmux**: always the fixed socket `-S /tmp/claude-studio-<uid>.sock`; never `-L`
  (the GUI and a login shell see different `TMUX_TMPDIR`). `mouse off` is required in
  the config or text selection breaks.
- **`Project.shortID`**: never `hashValue` — Swift seeds it per process, which would
  orphan every tmux session and launchd job on the next launch. FNV-1a is used.
- **Spawning**: always `/bin/zsh -l -i -c`; `-i` is mandatory (PATH lives in
  `.zshrc`), and `Shell.userPath` is injected. Services and scripts may prefix
  `stty cols C rows R`; interactive TUIs must NOT (see terminal geometry).
- **launchd**: the PATH is EMBEDDED in the runner script; `#!/bin/zsh -l` cannot be
  trusted to read `.zshrc`. `setopt NULL_GLOB` is required — on the first run
  `*.md` matches nothing and zsh errors out.
- **Naming**: a **command** is Claude's own slash command (`.claude/commands`); a
  **script** is a one-shot shell command we store in `.cs/scripts.json`. Do not mix
  the two — `commands.json` was the old name for scripts and is migrated on load.
- **Terminal geometry**: a terminal is spawned only after its container's size has
  stopped changing (`TerminalContainer.armPendingStart`), and `attachCommand` passes
  NO `-x/-y` — tmux takes its size from the attaching client's pty. Passing a size
  made tmux paint one frame at the wrong geometry, which left the TUI garbled until
  a resize. Without tmux, never stamp `stty cols/rows` either — SwiftTerm's column
  count is stale at spawn, and that is exactly what made the drawing wrong on
  machines with no tmux. `settleGeometry` then moves the size by one column and back,
  because a TUI only re-lays-out on SIGWINCH.
- **Multi-line input**: `/terminal-setup` cannot run inside tmux. Shift+Enter → `\`+CR
  and Option+Enter → ESC+CR are mapped in `TerminalEngine.installKeyMonitor`.
- **Scrolling**: in tmux-backed terminals the wheel event is translated into
  copy-mode and SWALLOWED (`return nil`). Letting SwiftTerm scroll its empty buffer
  makes the screen jitter.
- **MCP**: never write MCP config ourselves. Listing reads `~/.claude.json`
  (`mcpServers` for user scope, `projects[<path>].mcpServers` for local) and the
  project's `.mcp.json` (project scope); changes go through `claude mcp add|remove`.
  `claude mcp list` connects to every server, so it runs only on demand. Health lines
  are matched against known server names — a plugin server is `plugin:a:b` and urls
  contain colons, so splitting on punctuation gets the name wrong.
- **Sessions**: `SessionRecord` lives in `.cs/sessions.json` and outlives tmux.
  Claude's `session_id` is captured from the hook, and reopening only passes
  `--resume` when `ClaudeTranscripts.exists` confirms the transcript — otherwise
  Claude prints "No session found" and exits.
- **Closing order**: release the tab and terminal view first, then kill the tmux
  session. The reverse order prints "no server running / exited" on screen.
- **SwiftTerm**: terminal views belong to `TerminalEngine`; the view layer only hosts
  them. Never remount the container (it resets scrolling). Use `softReset()`, not
  `reset()` (which erases scrollback). Debounce resizes by 80 ms.
- **Notifications**: use `osascript display notification`;
  `UNUserNotificationCenter` does not work in an ad-hoc signed app. Keep a strong
  reference to `NSSound` or nothing plays.
- **Writes**: all JSON is written atomically (`Paths.writeAtomically`). Never touch a
  `~/.claude/settings.json` that fails to parse.
- **Concurrency**: values accumulated inside `Task.detached` are handed to
  `MainActor.run` as immutable copies (an error in the Swift 6 language mode).

## Design

Restrained and native. Colors are macOS semantic colors, so light and dark appearance
come for free; only the accent (Claude orange) and status colors are fixed. No
decoration: system font in the UI, SF Mono in the terminal. New colors or metrics go
in `Theme.swift` and nowhere else.
