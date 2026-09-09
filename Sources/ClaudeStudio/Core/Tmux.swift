import Foundation

/// Session persistence is provided by tmux: sessions outlive the app, so
/// reopening a project reattaches exactly where you left off.
///
/// CRITICAL: always use a fixed `-S <socket>`, never `-L` — the GUI process and
/// a login shell see different `TMUX_TMPDIR` values, so `-L` would end up with
/// two separate servers. A fixed socket path is identical for every caller.
enum Tmux {

    static let socketPath = "/tmp/claude-studio-\(getuid()).sock"

    static var path: String? { cachedPath }

    private static let cachedPath: String? = Shell.findExecutable([
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
        "/opt/local/bin/tmux", "/usr/bin/tmux",
    ]) ?? Shell.which("tmux")

    static var isAvailable: Bool { path != nil }

    /// Minimal config. `mouse off` is required: if tmux grabs the mouse, text
    /// selection breaks — the app routes scrolling into copy-mode itself.
    ///
    /// `window-size latest` lets the Mac and a phone stay attached to the same
    /// session at once: the window follows whichever client was used last
    /// instead of shrinking to fit both. It is today's tmux default, written
    /// out so a future change of default cannot silently break phone access.
    static func ensureConfig() {
        let body = """
        set -g status off
        set -sg escape-time 0
        set -g default-terminal "screen-256color"
        set -as terminal-features ",*:RGB"
        set -g history-limit 50000
        set -g destroy-unattached off
        set -g mouse off
        set -g focus-events off
        set -g set-clipboard off
        set -g aggressive-resize off
        set -g window-size latest
        """
        try? body.write(to: Paths.tmuxConfig, atomically: true, encoding: .utf8)
        if run(["list-sessions"]).status == 0 {
            _ = run(["source-file", Paths.tmuxConfig.path])
        }
    }

    // MARK: - Sessions

    struct Session {
        let name: String
        let projectID: String
        let title: String?
        let claudeSID: String?
        let attached: Bool
        let lastUsed: Date?
    }

    /// All sessions owned by Claude Studio (those tagged with `@cs_project`).
    static func sessions(projectID: String? = nil) -> [Session] {
        let fmt = "#{session_name}\t#{@cs_project}\t#{@cs_title}\t#{@cs_sid}\t#{session_attached}\t#{@cs_used}"
        let r = run(["list-sessions", "-F", fmt])
        guard r.status == 0 else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5, !f[1].isEmpty else { return nil }
            if let projectID, f[1] != projectID { return nil }
            let used = f.count > 5 ? TimeInterval(f[5]) : nil
            return Session(name: f[0],
                           projectID: f[1],
                           title: f[2].nilIfEmpty,
                           claudeSID: f[3].nilIfEmpty,
                           attached: f[4] != "0",
                           lastUsed: used.map { Date(timeIntervalSince1970: $0) })
        }
    }

    static func exists(_ name: String) -> Bool {
        run(["has-session", "-t", name]).status == 0
    }

    static func kill(_ name: String) {
        _ = run(["kill-session", "-t", name])
    }

    static func setOption(_ session: String, _ key: String, _ value: String) {
        _ = run(["set-option", "-t", session, key, value])
    }

    /// Several options in ONE tmux invocation.
    ///
    /// Every `run` is a fork, an exec and a wait on a server that may be busy, and
    /// these were called in groups of three or four in a row — on the main thread, at
    /// the exact moment a tab was being opened. tmux chains commands with `;`, so the
    /// whole group costs one process instead of four.
    static func setOptions(_ session: String, _ options: [String: String]) {
        guard !options.isEmpty else { return }
        var args: [String] = []
        for (key, value) in options.sorted(by: { $0.key < $1.key }) {
            if !args.isEmpty { args.append(";") }
            args += ["set-option", "-t", session, key, value]
        }
        _ = run(args)
    }

    /// Kills sessions off the main thread. Closing a window killed one session per
    /// service and per terminal, each a synchronous process, one after another.
    static func killDetached(_ names: [String]) {
        let targets = names.filter { !$0.isEmpty }
        guard !targets.isEmpty, isAvailable else { return }
        Task.detached(priority: .utility) {
            for name in targets { kill(name) }
        }
    }

    static func touch(_ session: String) {
        setOption(session, "@cs_used", String(Int(Date().timeIntervalSince1970)))
    }

    /// Pane titles — Claude sets its own title over OSC; read to keep session
    /// labels live.
    static func paneTitles() -> [String: String] {
        let r = run(["list-panes", "-a", "-F", "#{session_name}\t#{pane_title}"])
        guard r.status == 0 else { return [:] }
        var out: [String: String] = [:]
        for line in r.out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2 else { continue }
            out[f[0]] = f[1]
        }
        return out
    }

    /// Liveness of a service pane: `nil` when the session is gone, otherwise whether
    /// the pane is dead and, if it is, the command's exit status.
    struct PaneState {
        let dead: Bool
        let exitCode: Int?
    }

    /// Every session's pane state in ONE call.
    ///
    /// `paneState` per service forks a `tmux` each; a window running six services
    /// forked six every 1.5 s, and `list-panes -a` already has to walk the same list
    /// to answer any one of them. A session missing from the result is a session that
    /// no longer exists — the same thing `paneState` reports as `nil`.
    static func paneStates() -> [String: PaneState] {
        let r = run(["list-panes", "-a", "-F",
                     "#{session_name}\t#{pane_dead}\t#{pane_dead_status}"])
        guard r.status == 0 else { return [:] }
        var out: [String: PaneState] = [:]
        for line in r.out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2, !f[0].isEmpty else { continue }
            let dead = f[1] != "0"
            let code = f.count > 2 ? Int(f[2]) : nil
            out[f[0]] = PaneState(dead: dead, exitCode: dead ? code : nil)
        }
        return out
    }

    static func paneState(_ session: String) -> PaneState? {
        let r = run(["display-message", "-p", "-t", session,
                     "#{pane_dead}\t#{pane_dead_status}"])
        guard r.status == 0 else { return nil }
        let fields = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t")
        guard let first = fields.first, !first.isEmpty else { return nil }
        let dead = first != "0"
        let code = fields.count > 1 ? Int(fields[1]) : nil
        return PaneState(dead: dead, exitCode: dead ? code : nil)
    }

    /// Sends Ctrl-C to the pane — the polite way to stop a service.
    static func interrupt(_ session: String) {
        _ = run(["send-keys", "-t", session, "C-c"])
    }

    /// The last `lines` lines of a pane, history included, wrapped lines joined.
    static func capture(_ session: String, lines: Int = 400) -> String {
        let r = run(["capture-pane", "-p", "-J", "-S", "-\(max(1, lines))", "-t", session])
        return r.status == 0 ? r.out : ""
    }

    /// The visible screen of several sessions, in ONE tmux call.
    ///
    /// What a session is waiting FOR lives nowhere but its screen: Claude draws
    /// the prompt into the TUI and blocks on a keypress — there is no hook payload
    /// for it, no file and no API. So the screens have to be read, and reading
    /// them one `capture-pane` at a time would be a fork per waiting session every
    /// poll, which on a busy machine is exactly the per-window cost `SessionStates`
    /// exists to avoid.
    ///
    /// Deliberately WITHOUT `-J`: joining wrapped lines also erases the frame the
    /// selection caret sits in, and that caret is the one mark that tells a prompt
    /// apart from a numbered list Claude happened to print in an answer.
    ///
    /// Sessions are marked off with a `\u{1}` line, which no terminal draws.
    static func capturePanes(_ sessions: [String]) -> [String: [String]] {
        guard !sessions.isEmpty, isAvailable else { return [:] }
        var args: [String] = []
        for session in sessions {
            if !args.isEmpty { args.append(";") }
            args += ["display-message", "-p", "-t", session, "\u{1}\(session)",
                     ";", "capture-pane", "-p", "-t", session]
        }
        let r = run(args)
        guard !r.out.isEmpty else { return [:] }

        var out: [String: [String]] = [:]
        for block in r.out.components(separatedBy: "\u{1}") where !block.isEmpty {
            var lines = block.components(separatedBy: "\n")
            let name = lines.removeFirst()
            guard !name.isEmpty else { continue }
            out[name] = lines
        }
        return out
    }

    /// Pins every client of the session to an exact size, then repaints. Called
    /// once the terminal view has settled, so tmux and the view agree to the column.
    static func setClientSize(_ session: String, cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let r = run(["list-clients", "-t", session, "-F", "#{client_name}"])
        guard r.status == 0 else { return }
        for client in r.out.split(separator: "\n") where !client.isEmpty {
            _ = run(["refresh-client", "-t", String(client), "-C", "\(cols)x\(rows)"])
        }
    }

    /// Forces every client attached to the session to repaint. tmux only redraws
    /// on its own when something changes, so a client that attached mid-frame can
    /// otherwise sit on a partially drawn screen.
    static func refreshClients(of session: String) {
        let r = run(["list-clients", "-t", session, "-F", "#{client_name}"])
        guard r.status == 0 else { return }
        for client in r.out.split(separator: "\n") where !client.isEmpty {
            _ = run(["refresh-client", "-t", String(client)])
        }
    }

    /// Scrollback navigation: `copy-mode -e` exits by itself at the bottom.
    static func scroll(_ session: String, lines: Int, up: Bool) {
        guard lines > 0 else { return }
        if up {
            _ = run(["copy-mode", "-e", "-t", session, ";",
                     "send-keys", "-t", session, "-X", "-N", "\(lines)", "scroll-up"])
        } else {
            _ = run(["send-keys", "-t", session, "-X", "-N", "\(lines)", "scroll-down"])
        }
    }

    // MARK: - Attach command

    /// `-A -D`: attach to the session if it exists (detaching the old client),
    /// otherwise create it running `inner`. One call means both "resume" and
    /// "start".
    ///
    /// Deliberately WITHOUT `-x/-y`: the size is left to the attaching client's
    /// pty. Passing a size here meant tmux drew one frame at that geometry before
    /// the client corrected it, and a TUI painted during that frame stayed garbled
    /// until something resized it.
    static func attachCommand(session: String, env: [String: String], inner: String?) -> String {
        var parts = [
            "exec", Shell.quoted(path ?? "tmux"),
            "-S", Shell.quoted(socketPath),
            "-f", Shell.quoted(Paths.tmuxConfig.path),
            "new-session", "-A", "-D",
            "-s", Shell.quoted(session),
        ]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            parts.append("-e")
            parts.append("\(k)=\(Shell.quoted(v))")
        }
        if let inner { parts.append(Shell.quoted(inner)) }
        return parts.joined(separator: " ")
    }

    // MARK: - Private

    @discardableResult
    private static func run(_ args: [String]) -> (status: Int32, out: String) {
        guard let tmux = path else { return (-1, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-S", socketPath] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        // Never `waitUntilExit()`: it pumps the run loop, and `Tmux.exists` is
        // deliberately called on the main thread — a wait that lays out SwiftUI
        // underneath its caller is how a lazy global crashed the app in
        // `PhoneInstaller`. See `Shell.barrier`.
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        done.wait()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
