import Foundation
import Combine
import Darwin
import AppKit
import SwiftTerm

/// tmux-backed terminals are tagged: the scroll wheel is routed into tmux
/// copy-mode, because the scrollback lives in tmux — SwiftTerm only ever sees the
/// single screen tmux draws.
final class StudioTerminalView: LocalProcessTerminalView {
    var tmuxSession: String?
}

/// The app's runtime core: terminal view cache, process lifecycle, tmux sessions
/// and Claude attention indicators.
///
/// Terminal views **live here**, not in the view layer. Switching tabs only picks
/// which NSView gets attached; the process, scroll position and buffer are left
/// untouched — which is why switching is instant.
@MainActor
final class TerminalEngine: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {

    /// Service id → status.
    @Published var serviceStatus: [UUID: ServiceStatus] = [:]
    /// Session key → Claude's live state (from the hook bridge).
    @Published var attention: [String: Attention] = [:]
    /// tmux session name → the live title Claude sets.
    @Published var paneTitles: [String: String] = [:]
    /// Tab key → Claude's own session id (for `--resume`).
    @Published var claudeSIDs: [String: String] = [:]

    private var views: [String: StudioTerminalView] = [:]
    /// Spawn was requested but the process is not `running` yet — guards against
    /// double spawns.
    private var starting: Set<String> = []
    /// Commands running invisibly (they announce themselves when done).
    private var backgroundKeys: [String: String] = [:]
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var lastScrollSend = Date.distantPast
    private var pollTimer: Timer?

    private lazy var baseEnvironment: [String] = Self.buildEnvironment()
    /// Context for notification text; filled in by `StudioModel`.
    var projectName = ""
    var sessionTitles: [String: String] = [:]

    override init() {
        super.init()
        Tmux.ensureConfig()
        HookBridge.installIfNeeded()
        installScrollMonitor()
        installKeyMonitor()
        startPolling()
    }

    // MARK: - View cache

    func view(for key: String) -> StudioTerminalView {
        if let existing = views[key] { return existing }
        // Generous initial frame: SwiftTerm derives the PTY size from it on the
        // first spawn, so it must not be 0×0 before layout.
        let v = StudioTerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
        v.processDelegate = self
        v.font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(AppSettings.shared.terminalFontSize), weight: .regular)
        v.nativeBackgroundColor = Theme.nsTermBG
        v.nativeForegroundColor = Theme.nsTermFG
        v.getTerminal().changeScrollback(10_000)
        views[key] = v
        return v
    }

    func isLive(_ key: String) -> Bool { views[key]?.process?.running == true }

    func hasView(_ key: String) -> Bool { views[key] != nil }

    /// Releases the view and its process entirely (when a tab is closed).
    func discard(_ key: String) {
        guard let v = views.removeValue(forKey: key) else { return }
        if v.process?.running == true { kill(v.process.shellPid, SIGTERM) }
        v.removeFromSuperview()
        HookBridge.clearState(key)
    }

    // MARK: - Claude session (persistent via tmux)

    /// Attaches to the session, creating it if needed. Thanks to `-A -D` a single
    /// call means both "pick up where you left off" and "start fresh".
    func startSession(key: String, session: String, project: Project,
                      title: String, resumeSID: String? = nil,
                      initialPrompt: String? = nil, autoRun: Bool = false,
                      extraEnv: [String: String] = [:]) {
        guard !starting.contains(key) else { return }
        let v = view(for: key)
        if v.process?.running == true { return }
        starting.insert(key)

        let cols = max(80, v.getTerminal().cols)
        let rows = max(24, v.getTerminal().rows)

        // The hook environment is passed to the PTY and to the tmux session, so
        // the context survives even if the session is recreated.
        var hookEnv = ["CS_TAB_ID": key, "CS_TAB_NAME": title, "CS_PROJECT": project.name]
        for (k, v) in extraEnv { hookEnv[k] = v }

        var env = baseEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")
        for (k, value) in hookEnv { env.append("\(k)=\(value)") }

        let trimmed = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeCommand: String
        if let sid = resumeSID {
            claudeCommand = "claude --resume \(Shell.quoted(sid))"
        } else if let prompt = trimmed, !prompt.isEmpty, autoRun {
            claudeCommand = "claude \(Shell.quoted(prompt))"
        } else {
            claudeCommand = "claude"
        }
        let inner = "cd \(Shell.quoted(project.path)) && exec \(claudeCommand)"

        let wrapped: String
        if Tmux.isAvailable {
            v.tmuxSession = session
            wrapped = Tmux.attachCommand(session: session, cols: cols, rows: rows,
                                         env: hookEnv, inner: inner)
        } else {
            // Without tmux, a plain non-persistent spawn — the app still works.
            wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; \(inner)"
        }

        v.startProcess(executable: "/bin/zsh", args: ["-l", "-i", "-c", wrapped],
                       environment: env, execName: nil)
        after(1.0) { [weak self] in self?.starting.remove(key) }

        if Tmux.isAvailable {
            after(0.6) {
                Tmux.setOption(session, "@cs_project", project.shortID)
                Tmux.setOption(session, "@cs_title", title)
                Tmux.touch(session)
            }
        }

        // With auto-run off the prompt is typed into the box but not sent — the
        // user reviews and submits it.
        if resumeSID == nil, !autoRun, let prompt = trimmed, !prompt.isEmpty {
            after(1.6) { [weak self] in self?.send(key: key, text: prompt) }
        }
    }

    /// A manually opened shell. With tmux it is persistent too — reopening the
    /// app brings it back in the same directory with the same history.
    func startShell(key: String, session: String, project: Project, cwd: String, title: String) {
        guard !starting.contains(key) else { return }
        let v = view(for: key)
        if v.process?.running == true { return }
        starting.insert(key)

        let expanded = (cwd as NSString).expandingTildeInPath
        let cols = max(80, v.getTerminal().cols)
        let rows = max(24, v.getTerminal().rows)
        var env = baseEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")

        let inner = "cd \(Shell.quoted(expanded)) && exec /bin/zsh -l -i"
        let wrapped: String
        if Tmux.isAvailable {
            v.tmuxSession = session
            wrapped = Tmux.attachCommand(session: session, cols: cols, rows: rows,
                                         env: [:], inner: inner)
        } else {
            wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; \(inner)"
        }
        v.startProcess(executable: "/bin/zsh", args: ["-l", "-i", "-c", wrapped],
                       environment: env, execName: nil)
        after(1.0) { [weak self] in self?.starting.remove(key) }
        if Tmux.isAvailable {
            after(0.6) {
                Tmux.setOption(session, "@cs_project", project.shortID)
                Tmux.setOption(session, "@cs_title", title)
                Tmux.setOption(session, "@cs_kind", "shell")
            }
        }
    }

    // MARK: - Services (direct PTY)

    func startService(_ service: Service, project: Project) {
        let key = service.id.uuidString
        let v = view(for: key)
        if v.process?.running == true { return }

        serviceStatus[service.id] = .starting
        let cwd = service.resolvedCwd(projectPath: project.path)
        feed(key: key, "\r\n\u{1B}[2m— starting: \(service.command)  (\(cwd)) —\u{1B}[0m\r\n")

        let cols = max(80, v.getTerminal().cols)
        let rows = max(24, v.getTerminal().rows)
        // stty stamps the PTY size from the inside on first spawn; SwiftTerm's
        // post-layout TIOCSWINSZ still wins afterwards.
        let wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; "
            + "cd \(Shell.quoted(cwd)) && \(service.command)"

        var env = baseEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")
        v.startProcess(executable: "/bin/zsh", args: ["-l", "-i", "-c", wrapped],
                       environment: env, execName: nil)

        if let port = service.port {
            checkReadiness(service.id, port: port, attempt: 0)
        } else {
            after(1.2) { [weak self] in
                guard let self, self.serviceStatus[service.id] == .starting else { return }
                self.serviceStatus[service.id] = self.isLive(key) ? .running : .crashed
            }
        }
    }

    /// Graceful stop: Ctrl-C to the PTY → 3 s → SIGTERM → 3 s → SIGKILL.
    func stopService(_ service: Service) {
        let key = service.id.uuidString
        if let v = views[key], v.process?.running == true {
            serviceStatus[service.id] = .stopping
            let pid = v.process.shellPid
            v.process.send(data: ArraySlice([0x03]))
            after(3) { [weak self] in
                guard let self, self.views[key]?.process?.running == true else { return }
                kill(pid, SIGTERM)
                self.after(3) { [weak self] in
                    guard let self, self.views[key]?.process?.running == true else { return }
                    kill(pid, SIGKILL)
                }
            }
            return
        }
        // Externally started service: free the port.
        if serviceStatus[service.id] == .external, let port = service.port {
            serviceStatus[service.id] = .stopping
            Shell.killPort(port)
            after(1.5) { [weak self] in self?.refreshExternalStatuses([service]) }
        }
    }

    func restartService(_ service: Service, project: Project) {
        stopService(service)
        after(1.0) { [weak self] in self?.startService(service, project: project) }
    }

    /// Flags services listening on their port that the app did not start.
    func refreshExternalStatuses(_ services: [Service]) {
        let probes = services.compactMap { s -> (UUID, Int)? in
            guard let port = s.port else { return nil }
            let status = serviceStatus[s.id] ?? .stopped
            return (status == .stopped || status == .external || status == .stopping)
                ? (s.id, port) : nil
        }
        guard !probes.isEmpty else { return }
        Task.detached(priority: .utility) {
            var live: [UUID: Bool] = [:]
            for (id, port) in probes { live[id] = Shell.portIsListening(port) }
            let result = live
            await MainActor.run {
                for (id, listening) in result {
                    let current = self.serviceStatus[id] ?? .stopped
                    guard current == .stopped || current == .external || current == .stopping
                    else { continue }
                    self.serviceStatus[id] = listening ? .external : .stopped
                }
            }
        }
    }

    private func checkReadiness(_ id: UUID, port: Int, attempt: Int) {
        guard attempt < 40 else { return }
        after(0.5) { [weak self] in
            guard let self, self.serviceStatus[id] == .starting else { return }
            Task.detached(priority: .utility) {
                let up = Shell.portIsListening(port)
                await MainActor.run {
                    guard self.serviceStatus[id] == .starting else { return }
                    if up { self.serviceStatus[id] = .running }
                    else { self.checkReadiness(id, port: port, attempt: attempt + 1) }
                }
            }
        }
    }

    // MARK: - One-shot command

    /// Runs a command in an invisible PTY and announces the result.
    func runInBackground(name: String, command: String, cwd: String) {
        let key = "bg:\(UUID().uuidString)"
        backgroundKeys[key] = name
        let v = view(for: key)
        let expanded = (cwd as NSString).expandingTildeInPath
        var env = baseEnvironment
        env.append("COLUMNS=120")
        env.append("LINES=40")
        v.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-i", "-c", "cd \(Shell.quoted(expanded)) && \(command)"],
                       environment: env, execName: nil)
    }

    // MARK: - Input

    func send(key: String, text: String, enter: Bool = false) {
        guard let v = views[key], v.process?.running == true else { return }
        var bytes = Array(text.utf8)
        if enter { bytes.append(0x0D) }
        v.process.send(data: ArraySlice(bytes))
    }

    func feed(key: String, _ ansi: String) {
        view(for: key).getTerminal().feed(text: ansi)
    }

    /// Clears the screen but keeps the scrollback (`reset()` would erase it).
    func clear(key: String) {
        guard let v = views[key] else { return }
        v.getTerminal().softReset()
        v.getTerminal().feed(text: "\u{1B}[2J\u{1B}[H")
        v.needsDisplay = true
    }

    // MARK: - Monitoring

    /// Polls hook state files and tmux titles at a low frequency. Polling rather
    /// than watching: launchd and tmux write independently of the app, and a 1.5 s
    /// loop is both cheap and live enough.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in self.poll() }
        }
    }

    private func poll() {
        let states = HookBridge.readAll()
        var next: [String: Attention] = [:]
        var sids: [String: String] = [:]
        for (key, state) in states {
            switch state.state {
            case "working": next[key] = .working
            case "waiting": next[key] = .waiting
            default:        next[key] = .idle
            }
            if let sid = state.sid, !sid.isEmpty { sids[key] = sid }
        }

        // Announce on the TRANSITION into waiting — not on every poll.
        for (key, value) in next where value == .waiting && attention[key] != .waiting {
            if attention[key] != nil {
                AppSettings.shared.announceWaiting(session: sessionTitles[key] ?? "Claude",
                                                  project: projectName)
            }
        }
        attention = next
        claudeSIDs.merge(sids) { _, new in new }

        if AppSettings.shared.badgeEnabled {
            Notify.badge(next.values.filter { $0 == .waiting }.count)
        }

        guard Tmux.isAvailable else { return }
        Task.detached(priority: .utility) {
            let titles = Tmux.paneTitles()
            await MainActor.run { self.paneTitles = titles }
        }
    }

    /// Scroll wheel: in tmux-backed terminals the scrollback lives in tmux, so the
    /// event is translated into copy-mode and SWALLOWED — letting SwiftTerm run its
    /// own (empty) scroll makes the screen jitter in place.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      event.scrollingDeltaY != 0,
                      let hit = event.window?.contentView?.hitTest(event.locationInWindow),
                      let terminal = Self.enclosingTerminal(hit),
                      let session = terminal.tmuxSession
                else { return false }

                let now = Date()
                if now.timeIntervalSince(self.lastScrollSend) >= 0.03 {
                    self.lastScrollSend = now
                    let up = event.scrollingDeltaY > 0
                    DispatchQueue.global(qos: .userInteractive).async {
                        Tmux.scroll(session, lines: 3, up: up)
                    }
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    /// Multi-line input in Claude Code: Shift+Enter → `\` + CR, Option+Enter →
    /// ESC + CR. `/terminal-setup` cannot run inside tmux, so the mapping is done
    /// by the app itself.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let view = NSApp.keyWindow?.firstResponder as? LocalProcessTerminalView,
                      event.keyCode == 36 || event.keyCode == 76,   // Return / Enter
                      view.process?.running == true
                else { return false }

                if event.modifierFlags.contains(.shift) {
                    view.process.send(data: ArraySlice([0x5C, 0x0D]))
                    return true
                }
                if event.modifierFlags.contains(.option) {
                    view.process.send(data: ArraySlice([0x1B, 0x0D]))
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    /// The first terminal view walking up from the given view.
    private static func enclosingTerminal(_ view: NSView) -> StudioTerminalView? {
        var node: NSView? = view
        while let current = node {
            if let terminal = current as? StudioTerminalView { return terminal }
            node = current.superview
        }
        return nil
    }

    // MARK: - Delegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // LocalProcessTerminalView applies TIOCSWINSZ itself.
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard let view = source as? StudioTerminalView,
                  let key = self.views.first(where: { $0.value === view })?.key else { return }

            if let name = self.backgroundKeys.removeValue(forKey: key) {
                let ok = (exitCode ?? 0) == 0
                AppSettings.shared.announceFinished(
                    title: name,
                    detail: ok ? "Finished." : "Failed (exit \(exitCode ?? -1)).",
                    ok: ok)
                self.views.removeValue(forKey: key)
                return
            }

            if let id = UUID(uuidString: key) {
                let previous = self.serviceStatus[id] ?? .stopped
                let code = exitCode ?? 0
                if previous == .stopping || code == 0 {
                    self.serviceStatus[id] = .stopped
                } else {
                    self.serviceStatus[id] = .crashed
                    self.feed(key: key, "\r\n\u{1B}[31m— process exited with code \(code) —\u{1B}[0m\r\n")
                    AppSettings.shared.announceFinished(title: "Service stopped",
                                                        detail: "Exit code \(code).", ok: false)
                }
            }
        }
    }

    // MARK: - Helpers

    private func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(block) }
    }

    /// Environment for spawned processes: the user's real PATH plus terminal
    /// capability declarations.
    private static func buildEnvironment() -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        env.removeAll { $0.hasPrefix("PATH=") }
        env.append("PATH=\(Shell.userPath)")
        env.append("TERM_PROGRAM=ClaudeStudio")
        env.append("COLORTERM=truecolor")
        // Flag that disables Claude Code's redraw flicker.
        env.append("CLAUDE_CODE_NO_FLICKER=0")
        if let lang = ProcessInfo.processInfo.environment["LANG"] {
            env.removeAll { $0.hasPrefix("LANG=") }
            env.append("LANG=\(lang)")
        } else {
            env.append("LANG=en_US.UTF-8")
        }
        return env
    }
}
