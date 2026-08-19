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
│   ├── ProjectLinks.swift     # links to other projects + bridge install/registration
│   ├── LinkAccess.swift       # writable links → permissions.additionalDirectories
│   ├── LinkedRuns.swift       # the queue + confirmation behind running a linked skill
│   ├── Usage.swift            # hook event spool → usage records + live state
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

Sources/StudioBridge/       # second executable: the MCP server the app registers with
                            # Claude. No SwiftTerm, no SwiftUI. It duplicates a trimmed
                            # copy of the file formats on purpose — sharing would mean
                            # extracting a library, since Models.swift imports SwiftUI.
                            # `ProjectReader.shortID` MUST match `Project.shortID`.

Bridge/                     # cs-bridge: phone access over Netbird. A launchd agent,
                            # NOT part of the app — sessions stay reachable while the
                            # app is closed. Dependency-free Node + ttyd; it reads the
                            # same files the app writes and drives the same tmux socket.
                            # `lib/shortid.mjs` MUST match `Project.shortID` too.
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
- **Services run in tmux**, like sessions and terminals, so anything outside the app can
  read their output. `remain-on-exit` is set FROM INSIDE the pane before the command
  runs: setting it from outside a moment later is a race a fast-failing service wins,
  and its output dies with the session. Status comes from `#{pane_dead}` +
  `#{pane_dead_status}` in the 1.5 s poll, not from `processTerminated`.
- **Project links**: `.cs/links.json`. A writable link grants file access through
  `permissions.additionalDirectories` in a generated `--settings` layer (`LinkAccess`),
  read at session start only, hence the reopen hint. **Never `--add-dir`**: it grants
  the same files but ALSO loads the linked project's skills into this session's skill
  list, and a `Skill` tool call carries only a name (`{"skill":"deploy"}`), never a
  path — so with two projects defining `deploy`, nothing downstream can tell which one
  ran: not the permission dialog, not a hook, not the transcript. `permissions.deny`
  does not help; a denied skill is still listed. `additionalDirectories` grants read
  AND write and loads no skills, which makes the guarantee structural rather than a
  rule the model has to follow. `--settings` is MERGED, so the project's own
  `.claude/settings.json` survives. Running a linked project's skill on purpose is
  Claude Studio's job — see the next rule. The bridge's `project_capabilities` was
  never the leak and still reports file paths for read-only links.
- **Running a linked project's skill**: `run_skill` + `wait_for_skill_run` on the
  bridge, `LinkedRuns` in the app. The project is a REQUIRED argument — there is no
  default and no nearest match, so the ambiguity that made the skill list dangerous
  cannot come back through the tool. A request lands in the CALLING project's
  `.cs/skill-requests.json` as `pending` and **nothing runs until the user presses a
  button**; the sheet names the project, not just the skill. On approval the skill runs
  in the project that OWNS it, through the very runner `Scheduler` writes for a
  scheduled run — same script, same report, same `.state.json`, which is exactly what
  makes completion detectable. The state file is DELETED before launching: the runner
  writes it at start and rewrites it at exit, so a leftover `finishedAt` from the last
  run would otherwise read as instant success. The tab opens in the calling window so a
  skill that asks a question can be answered; `wait_for_skill_run` returns "still
  running" on timeout rather than blocking. Two processes share the queue file, so both
  sides re-read immediately before writing — the `sessions.json` discipline.
- **When to reach across a link**: `ProjectLink.role` and `.useWhen`, asked in the link
  sheet and delivered in the bridge's MCP `instructions` — which arrive on connect,
  with no tool call. The tools alone were never enough: a session can LIST a linked
  project's skills, but a skill's own description says when it fires inside its own
  project, not whether crossing a link is right here, and nothing on disk answers that.
  A capability nobody knows the occasion for is never used, or used at the wrong
  moment. Empty `useWhen` falls back to "only when the user asks for this project by
  name" — the safe half of the ambiguity. `ProjectLink` decodes BY HAND for the usual
  reason, and here it is load-bearing: the synthesized decoder ignores property
  defaults and throws on a missing key, so shipping these two fields without it would
  have failed the whole array and silently unlinked every project on upgrade.
- **Continuing a run**: a report says what was found, and the next sentence is almost
  always "now fix it" — which only means something to the conversation that did the
  looking. So the runner **chooses** the conversation id instead of reading it back:
  `claude -p` reveals its `session_id` only under `--output-format json`, and that
  stream has to stay the readable thing the tab shows. `uuidgen` → `--session-id` →
  a `<stamp>.session` sidecar beside `<stamp>.md`, which `Runs.parse` picks up and
  `StudioModel.continueRun` resumes. The sidecar is the runner's, never the skill's:
  a report written by hand has none and the button simply does not appear, rather
  than resuming the wrong conversation. `ClaudeTranscripts.exists` is still checked —
  a run that died before Claude wrote anything leaves an id with no transcript. The
  follow-up is TYPED into the box and left unsent (`initialPrompt` now also applies
  to a resume, at 3 s rather than 1.6 — replaying a transcript is slower than a cold
  start): the run was unattended, so what it does on waking up is a decision worth
  one look. An already-attached tab is fed the text directly — `startSession` bails
  at its own "process is running" guard and the message would go nowhere. Runner
  scripts are regenerated on project open (`ProjectConfig.refreshRunners`), or a
  schedule set before this shipped would keep running the old script forever.
- **Reading what is running**: `project_runtime` and `read_output` answer for THIS
  project as well as the linked ones — deliberately asymmetric with `read_file`, which
  stays link-only because a session already has Read and Grep over its own tree. It has
  nothing for processes: a service or a `tail -f` lives in a tmux pane, and its own
  project's panes are exactly as invisible as a linked project's. Omitted `project`
  means this one. Two `lsof` traps in `listeningPorts`: **`-a` is mandatory** — lsof
  ORs its selection criteria, so `-p <pid> -iTCP -sTCP:LISTEN` without it reports every
  listening socket on the machine and credits a `sleep` with thirty ports — and the
  pane's pid is the SHELL, so the process tree has to be walked with `pgrep -P` to
  reach the server the shell started.
- **The bridge binary** is copied from the bundle to `Paths.binDir` and registered from
  THERE: the updater replaces the whole bundle and the user can move the app, while an
  MCP entry stores an absolute path. `MCPStore.add` quotes the command — our path
  contains "Application Support".
- **Usage tracking**: skills and commands both arrive as the `Skill` tool
  (`tool_input.skill`, `tool_response.commandName`, `duration_ms`); a slash command the
  user types arrives as `UserPromptExpansion` instead. The hook spools the RAW event as
  one file per event and Swift parses it — shell JSON parsing is where hooks go to die.
  `UsageMonitor` is app-wide: per-window consumers would race over the same spool.
- **Naming**: a **command** is Claude's own slash command (`.claude/commands`); a
  **script** is a one-shot shell command we store in `.cs/scripts.json`. Do not mix
  the two — `commands.json` was the old name for scripts and is migrated on load.
- **Services and scripts written by Claude**: the "with Claude" button hands over a
  prompt (`StudioModel.servicesPrompt` / `scriptsPrompt`) and Claude edits
  `.cs/services.json` / `.cs/scripts.json` itself — the app never parses an answer
  back. Two things make that work: the `.cs` watcher re-reads both files, not only
  `sessions.json`, and `Service`/`ProjectScript` decode by hand, so an entry written
  without an `id` gets one instead of taking the whole list down. The prompt keeps the
  JSON example comment-free; a `//` in the sample comes back as a `//` in the file.
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
- **Phone bridge**: `Bridge/cs-attach.sh` attaches WITHOUT `-D`, so the Mac's client is
  not dropped — `window-size latest` (written into `tmux.conf`) sizes the window from
  the most recent client instead of shrinking to the smallest. It passes `-e CS_TAB_ID`
  so the hook reports state and captures `session_id`, and it applies the same
  `--resume` rule as the app: only when the transcript exists AND is non-empty. Flags
  are built as an ARRAY — `${conf:+-f "$conf"}` hands tmux `-f <path>` as one argument
  and it fails on the whole string as a filename. The bridge re-reads
  `.cs/sessions.json` before every write and the app watches `.cs` (not the file:
  atomic writes replace the inode), so neither side erases the other's records.
- **Updating the phone**: installed to the Home Screen there is no address bar and no
  reload button, so a change on the Mac can stay invisible indefinitely. `/api/state`
  carries a `buildId` derived from the mtimes and sizes of `Bridge/web/`; when it differs
  from the one the page loaded with, a banner offers to update. Updating clears the Cache
  Storage and calls `registration.update()` — NEVER `unregister()`, which takes the push
  subscription with it and stops notifications silently.
- **The phone's back gesture**: installed on the Home Screen there is no address bar
  and no back button, so Android's edge swipe is the only "back" — and with a single
  history entry the browser leaves the app, which mid-session reads as a crash. While
  anything is open over the session list, `app.js` keeps ONE sentinel `pushState` entry
  armed; `popstate` closes the topmost layer and re-arms if another is still open. The
  state is read off the DOM every time and never counted: a depth counter drifts the
  moment something closes itself (a sheet that submits, a tab killed from the actions
  menu) and then silently swallows the gesture. Disarming is deferred to a microtask —
  "close the menu, then open settings" runs both in one turn, and an immediate
  `history.back()` would pop the entry the new layer just pushed. Set an iframe's `src`
  BEFORE inserting it (`openSession` does): assigning it afterwards adds a history entry
  and back would then step inside the terminal instead of leaving it.
- **Phone terminal layout**: the key row goes ABOVE the terminal — the on-screen keyboard
  covers the bottom of the screen, so keys placed under it are unreachable exactly when
  they are needed. There is no message box either: the terminal already owns the keyboard,
  and a second place to type competes with it. Session rows are a `div` holding two
  buttons (open, and `⋯` for actions) — a button nested in a button is invalid and the
  inner one stops receiving taps.
- **Phone scrolling**: the scrollback is tmux's, and Claude's TUI runs on the alternate
  screen, so the emulator has nothing of its own to scroll. `POST /scroll` enters
  copy-mode (`-e`, which exits by itself at the bottom) exactly as the Mac does with the
  wheel; ANY input calls `leaveCopyMode` first, or the keystrokes go to copy-mode's key
  table instead of Claude. Never navigate the terminal iframe away (`src=about:blank`) —
  ttyd registers `beforeunload` and the browser then asks "Leave site?"; remove the
  element instead.
- **TLS is not optional for the phone**: service workers, Web Push and "install as
  app" all require a secure context, so over plain HTTP the phone gets a terminal and
  nothing else. `Bridge/make-cert.sh` issues a root ONCE (never regenerate it — every
  device that trusted it would break) and reissues the leaf whenever the Netbird address
  changes; the name must be in `subjectAltName` (the common name is ignored) and the leaf
  stays under the 825-day ceiling browsers enforce. HTTP keeps serving `/ca.crt`
  (deliberately unauthenticated — it is the public root, and it cannot sit behind the
  HTTPS it bootstraps) and `/setup`, which is where the QR code points.
- **Installability**: `manifest.json` and the icons are served BEFORE the token check
  (`PUBLIC` in `server.mjs`) — Chrome fetches the manifest outside the page's credential
  context, and a 401 there reads as "no manifest": it then offers a bookmark that reopens
  in a tab instead of installing an app. It also needs a raster icon of at least 192px,
  so `Bridge/make-icons.mjs` rasterises `web/icon.svg` into PNGs (dependency-free, Node's
  zlib plus a hand-written encoder); re-run it after changing the artwork. iOS ignores SVG
  for `apple-touch-icon`, and only Safari can create a standalone app there.
- **Web Push**: implemented directly (RFC 8291 encryption + RFC 8292 VAPID) in
  `Bridge/lib/push.mjs`, no dependency — Node's crypto has P-256 ECDH, HKDF and
  `dsaEncoding: "ieee-p1363"` for JOSE signatures. The VAPID key pair is generated once
  and MUST NOT be regenerated: every existing subscription is bound to it. Notify on the
  TRANSITION `working` → `waiting`, never on the state, or it fires every poll. iOS
  delivers push only to a PWA added to the Home Screen; Android delivers to a browser tab
  too. Always reach the subscription through `await navigator.serviceWorker.ready` — the
  variable `register()` fills in is still empty on a fresh load, and reading it directly
  reports a subscribed device as unsubscribed (this is what made "no device is registered"
  unfixable from the phone). The browser can hold a subscription the Mac never stored, so
  the settings screen re-registers whenever the Mac does not recognise the endpoint. The
  phone has no inspectable console: failures go to `POST /api/log` and land in the bridge
  log — reach for that before guessing.
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
- **Private network**: the bridge binds to a Netbird OR Tailscale address and to
  nothing else routable — never 0.0.0.0. Both are read the same way (`MeshStatus`
  in Swift, `mesh_ip` in the runner), and Tailscale's App Store build keeps its CLI
  inside the bundle, so the app path has to be tried, not just PATH. A Netbird
  session expires after about a day: a phone that "suddenly stopped working" has
  almost always hit that, which is why Settings → Phone can sign in again and
  restart the agent instead of leaving it to a 30-second launchd throttle.
- **Skill runs**: the runner script is the SAME for launchd, "run in background" and
  "Run now" — only "Run now" puts it in a tmux tab so it can be watched. Its `claude`
  call needs `--verbose` and `| tee -a .run.log`: print mode says nothing until the
  end, and a plain redirect leaves the tab looking dead for minutes. `$CODE` then has
  to come from `${pipestatus[1]}`, since `$?` after a pipe is tee's. The status shown
  in the run list is NOT measured — it is the `status:` field the skill wrote into its
  own report; only the "Run failed (exit N)" notification comes from the exit code.
  `RunStore` is a separate `ObservableObject`, so `StudioModel` forwards its
  `objectWillChange` — without that a view holding only the model redraws late.
- **Project themes**: a project's palette (`ThemePreset` + a custom accent) lives in
  `.cs/settings.json` and reaches the interface through the `\.studioTheme`
  environment value — NEVER a mutable `Theme.accent`, because one process shows
  several projects at once and a global would paint every window the same. Inside a
  project window read `theme.surface` / `theme.text` / `theme.separator` and never
  `Theme.bg` and friends — a palette owns the whole window, and every surface is
  derived from the two colors it already declares. A palette with no colors of its
  own resolves to exactly `Theme`'s semantic values, which is what keeps the default
  native in light and dark; the welcome screen and Settings belong to no project and
  stay on `Theme`. `ProjectSettings` decodes by hand for the same reason
  `ProjectConfig` does: the synthesized decoder throws on the keys older files lack.
  Switching back to the default palette must actively restore SwiftTerm's own values
  (`Color.terminalAppColors`, `selectedControlColor`) — "install nothing" leaves the
  previous theme's colors in the running session.

## Design

Restrained and native. Colors are macOS semantic colors, so light and dark appearance
come for free; the status colors are fixed and the accent is the project's own
(Claude orange until one is picked). No decoration: system font in the UI, SF Mono in
the terminal. New colors or metrics go in `Theme.swift` and nowhere else — including
the palettes, which is why `ThemePreset.all` lives there.
