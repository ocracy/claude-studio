import Foundation
import SwiftUI
import AppKit
import Combine

/// All state for one window (one project). Views read it; the business logic
/// lives here, not in the view layer.
@MainActor
final class StudioModel: ObservableObject {

    enum Pane: String, CaseIterable, Identifiable {
        case sessions, skills, commands, mcp, cron, services, scripts, terminals
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sessions:  return "sessions"
            case .skills:    return "skills"
            case .mcp:       return "mcp servers"
            case .cron:      return "scheduled"
            case .services:  return "services"
            case .commands:  return "commands"
            case .scripts:   return "scripts"
            case .terminals: return "terminals"
            }
        }
        var icon: String {
            switch self {
            case .sessions:  return "bubble.left.and.bubble.right"
            case .skills:    return "sparkles"
            case .mcp:       return "point.3.connected.trianglepath.dotted"
            case .cron:      return "clock"
            case .services:  return "server.rack"
            case .commands:  return "slash.circle"
            case .scripts:   return "bolt"
            case .terminals: return "terminal"
            }
        }
        var help: String {
            switch self {
            case .sessions:  return "Claude sessions"
            case .skills:    return "Skills (.claude/skills)"
            case .mcp:       return "MCP servers"
            case .cron:      return "Scheduled runs"
            case .services:  return "Services"
            case .commands:  return "Claude commands (.claude/commands)"
            case .scripts:   return "Scripts — one-shot shell commands"
            case .terminals: return "Terminals"
            }
        }
    }

    /// The rail in the user's order: their saved order first, then anything a newer
    /// version added, so nothing can disappear from the sidebar.
    static var orderedPanes: [Pane] {
        let saved = AppSettings.shared.railOrder
            .split(separator: ",")
            .compactMap { Pane(rawValue: String($0)) }
        return saved + Pane.allCases.filter { !saved.contains($0) }
    }

    static func movePane(_ pane: Pane, by offset: Int) {
        var order = orderedPanes
        guard let index = order.firstIndex(of: pane) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        AppSettings.shared.railOrder = order.map(\.rawValue).joined(separator: ",")
    }

    static func movePane(_ pane: Pane, before other: Pane) {
        guard pane != other else { return }
        var order = orderedPanes
        guard let from = order.firstIndex(of: pane) else { return }
        order.remove(at: from)
        guard let to = order.firstIndex(of: other) else { return }
        order.insert(pane, at: to)
        AppSettings.shared.railOrder = order.map(\.rawValue).joined(separator: ",")
    }

    static func resetPaneOrder() { AppSettings.shared.railOrder = "" }

    let project: Project
    let store: ProjectStore
    let skills: SkillStore
    let mcp = MCPStore()
    let claudeCommands = CommandStore()
    let runs: RunStore
    let engine: TerminalEngine

    @Published var pane: Pane = .sessions
    @Published var tabs: [StudioTab] = []
    @Published var activeTabID: String?
    /// Session names currently alive in tmux.
    @Published var liveSessions: Set<String> = []
    @Published var sidebarWidth: CGFloat = 260
    /// Selected run in the skill/cron pane.
    @Published var selectedRun: [String: String] = [:]
    /// ⌘P palette visibility.
    @Published var paletteOpen = false
    /// Appearance sheet visibility. On the model rather than in the view, so the
    /// command palette can open it too.
    @Published var themeSheetOpen = false
    /// This project's appearance. Handed to the interface through `\.studioTheme`
    /// and to the terminals through `engine.theme`.
    @Published private(set) var theme: StudioTheme = .default
    /// What the sessions of this project are running right now, from the hook monitor.
    var liveUsage: [(tab: String, usage: UsageEvent)] {
        UsageMonitor.shared.live
            .filter { key, _ in tabs.contains { $0.terminalKey == key } }
            .map { (tab: $0.key, usage: $0.value) }
            .sorted { $0.usage.at < $1.usage.at }
    }

    /// The capability a given session is running, if any.
    func liveUsage(forTab key: String) -> UsageEvent? { UsageMonitor.shared.live[key] }

    /// Who owns a skill or command by that name: this project, another project we are
    /// linked to, or your global `~/.claude`.
    func owner(of name: String) -> String {
        if skills.skill(named: name)?.scope == .project { return project.name }
        if claudeCommands.command(named: name)?.scope == .project { return project.name }
        for link in links {
            let root = URL(fileURLWithPath: link.path)
            let candidates = [".claude/skills/\(name)/SKILL.md", ".claude/skills/\(name).md",
                              ".claude/commands/\(name).md"]
            if candidates.contains(where: {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
            }) { return link.name }
        }
        return "global"
    }

    /// Which linked projects a session was actually started with, per tab key. A
    /// session cannot gain file access after the fact, so this is what tells us to
    /// offer "reopen" instead of pretending the link already applies.
    @Published private(set) var sessionGrants: [String: Set<String>] = [:]

    private var refreshTimer: Timer?
    private var autoAttachPending = true
    /// `RunStore` is an object of its own, so a view holding only the model would not
    /// redraw when a run starts or ends — the running marker appeared late, whenever
    /// something else happened to publish.
    private var runsObserver: AnyCancellable?

    init(project: Project) {
        self.project = project
        self.store = ProjectStore(project: project)
        self.skills = SkillStore()
        self.runs = RunStore(project: project)
        self.engine = TerminalEngine()
        self.sidebarWidth = CGFloat(store.config.sidebarWidth)
        self.pane = Pane(rawValue: store.config.lastView) ?? .sessions
        self.theme = store.config.settings.theme
        engine.projectName = project.name
        engine.theme = theme
        runsObserver = runs.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Opens the pane that shows a skill's runs — its schedule tab when it has one,
    /// its skill tab otherwise.
    func openCron(skillNamed skill: String) {
        if let schedule = store.schedule(for: skill) {
            openCron(schedule)
        } else if let match = skills.skill(named: skill) {
            open(StudioTab(kind: .skill, ref: match.name, title: match.name))
            runs.refresh(skill: skill)
        }
    }

    // MARK: - Appearance

    /// Picks the project's palette. Written to `.cs/settings.json` and applied to the
    /// live terminals at once — nothing has to be reopened.
    func setTheme(presetID: String, accentHex: String, tintChrome: Bool) {
        store.mutate {
            $0.settings.themeID = presetID
            $0.settings.accentHex = accentHex
            $0.settings.tintChrome = tintChrome
        }
        theme = store.config.settings.theme
        engine.theme = theme
    }

    // MARK: - Lifecycle

    func start() {
        Paths.ensure(Paths.csDir(project))
        adoptOrphanSessions()
        refreshSessions()
        skills.start(project: project) { [weak self] names in
            guard let self else { return }
            self.store.pruneOrphanSchedules(existing: names)
            self.runs.refresh(skills: self.skills.skills.map(\.name))
        }
        runs.startPolling { [weak self] in self?.skills.skills.map(\.name) ?? [] }
        mcp.start(project: project)
        claudeCommands.start(project: project)
        // Links may arrive from version control or another machine; make sure the
        // bridge Claude needs to read them is installed and registered.
        if !store.config.links.isEmpty {
            ProjectBridge.register(project: project, mcp: mcp) { ok, output in
                if !ok, let detail = output.nilIfEmpty {
                    NSLog("[ProjectBridge] registration failed: %@", detail)
                }
            }
        }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in
                self.refreshSessions()
                self.engine.refreshExternalStatuses(self.store.config.services)
                // A session asks to run a linked skill by writing into `.cs`; this is
                // where the app notices and puts the question on screen.
                self.refreshSkillRequests()
            }
        }
        engine.refreshExternalStatuses(store.config.services)

        for service in store.config.services where service.autoStart {
            engine.startService(service, project: project)
        }
    }

    /// On window close: terminals and services shut down (the user opened them in
    /// this window), while Claude sessions keep living in tmux — that persistence
    /// is their entire point.
    func stop() {
        refreshTimer?.invalidate()
        runs.stopPolling()
        store.mutate {
            $0.sidebarWidth = Double(self.sidebarWidth)
            $0.lastView = self.pane.rawValue
        }

        for service in store.config.services {
            engine.discard(service.id.uuidString)
            Tmux.kill(TerminalEngine.serviceSession(service, project: project))
        }
        for terminal in store.config.terminals {
            engine.discard("terminal:\(terminal.id.uuidString)")
            Tmux.kill(tmuxName(for: terminal))
        }
    }

    // MARK: - Sessions

    /// Recorded sessions, newest first.
    var sessions: [SessionRecord] {
        store.config.sessions.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// The ones alive in tmux (listed in the sidebar).
    var openSessions: [SessionRecord] { sessions.filter { liveSessions.contains($0.tmux) } }

    /// Closed sessions that can be reopened.
    var pastSessions: [SessionRecord] { sessions.filter { !liveSessions.contains($0.tmux) } }

    func attention(of record: SessionRecord) -> Attention {
        engine.attention[record.tabKey] ?? .idle
    }

    var attentionCount: Int {
        openSessions.filter { attention(of: $0) == .waiting }.count
    }

    /// Adopts tmux sessions that belong to this project but have no record — so
    /// leftovers from another machine or version still show up in the list.
    private func adoptOrphanSessions() {
        guard Tmux.isAvailable else { return }
        let shortID = project.shortID
        let known = Set(store.config.sessions.map(\.tmux))
        Task.detached(priority: .utility) {
            let found = Tmux.sessions(projectID: shortID)
                .filter { !$0.name.contains("-sh-") && !$0.name.contains("-sv-")
                          && !known.contains($0.name) }
            guard !found.isEmpty else { return }
            await MainActor.run {
                for session in found {
                    let record = SessionRecord(name: session.title ?? "Claude",
                                               tmux: session.name,
                                               claudeSID: session.claudeSID,
                                               lastUsed: session.lastUsed ?? Date())
                    self.store.addSession(record)
                }
                self.refreshSessions()
            }
        }
    }

    /// Refreshes the live session set from tmux, the single source of truth.
    func refreshSessions() {
        guard Tmux.isAvailable else { return }
        let shortID = project.shortID
        Task.detached(priority: .utility) {
            let names = Set(Tmux.sessions(projectID: shortID)
                .filter { !$0.name.contains("-sh-") && !$0.name.contains("-sv-") }
                .map(\.name))
            await MainActor.run {
                self.liveSessions = names
                self.syncSessionContext()
                self.persistClaudeSIDs()
                if self.autoAttachPending, self.tabs.isEmpty,
                   AppSettings.shared.autoAttachLastSession,
                   let latest = self.openSessions.first {
                    self.autoAttachPending = false
                    self.openSession(latest)
                }
            }
        }
    }

    /// Keep notification text available to the engine.
    private func syncSessionContext() {
        var titles: [String: String] = [:]
        for record in store.config.sessions { titles[record.tabKey] = record.name }
        engine.sessionTitles = titles
    }

    /// Persist the Claude session ids captured by the hook, so a closed session
    /// can resume the same conversation with `--resume`.
    private func persistClaudeSIDs() {
        for record in store.config.sessions {
            guard let sid = engine.claudeSIDs[record.tabKey], sid != record.claudeSID else { continue }
            store.touchSession(tmux: record.tmux, claudeSID: sid)
            // Tag the tmux session too, so a session adopted on a later launch (or
            // from another machine) still knows which conversation it belongs to.
            let name = record.tmux
            Task.detached(priority: .utility) { Tmux.setOption(name, "@cs_sid", sid) }
        }
    }

    /// The settings layer that grants a session file access to the writable links,
    /// and the paths it covers (kept for `sessionGrants`, which the UI reads to show
    /// what an open session was started with).
    private func linkAccess() -> (dirs: [String], settings: String?) {
        let links = store.writableLinks
        return (links.map(\.path), LinkAccess.settingsFile(project: project, links: links))
    }

    @discardableResult
    func newSession(name: String? = nil, prompt: String? = nil, autoRun: Bool = false,
                    extraEnv: [String: String] = [:]) -> SessionRecord {
        let title = name ?? nextSessionName()
        let record = SessionRecord.make(projectShortID: project.shortID, name: title)
        store.addSession(record)
        open(StudioTab(kind: .session, ref: record.tmux, title: title))
        let (grants, linkSettings) = linkAccess()
        sessionGrants[record.tabKey] = Set(grants)
        engine.startSession(key: record.tabKey, session: record.tmux, project: project,
                            title: title, initialPrompt: prompt, autoRun: autoRun,
                            extraEnv: extraEnv, linkSettings: linkSettings)
        liveSessions.insert(record.tmux)
        syncSessionContext()
        return record
    }

    private func nextSessionName() -> String {
        var index = store.config.sessions.count + 1
        let existing = Set(store.config.sessions.map(\.name))
        while existing.contains("Claude \(index)") { index += 1 }
        return "Claude \(index)"
    }

    /// Opens a recorded session: attaches if it is alive in tmux, otherwise
    /// resumes the same conversation with `--resume` when the id is known.
    func openSession(_ record: SessionRecord) {
        open(StudioTab(kind: .session, ref: record.tmux, title: record.name))

        // A live session is simply attached. A dead one is resumed only if the
        // transcript is actually on disk; otherwise Claude prints "No session
        // found", exits instantly and leaves a dead terminal behind.
        let alive = liveSessions.contains(record.tmux)
        var resume: String?
        if !alive, let sid = record.claudeSID {
            // The id is kept even when there is no transcript yet: clearing it would
            // permanently forfeit a resume for a conversation that may still be
            // written. The check is one stat call, so it is repeatedevery time.
            if ClaudeTranscripts.exists(projectPath: project.path, sessionID: sid) { resume = sid }
        }

        let (grants, linkSettings) = linkAccess()
        sessionGrants[record.tabKey] = Set(grants)
        engine.startSession(key: record.tabKey, session: record.tmux, project: project,
                            title: record.name, resumeSID: resume,
                            linkSettings: linkSettings)
        store.touchSession(tmux: record.tmux)
        liveSessions.insert(record.tmux)
        syncSessionContext()
    }

    /// Every conversation Claude Code recorded for this project, newest first.
    func claudeTranscripts() -> [ClaudeTranscripts.Transcript] {
        ClaudeTranscripts.list(projectPath: project.path)
    }

    /// Resumes a conversation straight from Claude's own transcript.
    ///
    /// If a record already carries that `session_id` it is simply reopened, so the
    /// same conversation never ends up in two tmux sessions. Otherwise a new
    /// record is created around the existing id — the conversation predates
    /// Claude Studio, or was started outside it.
    func resumeTranscript(_ transcript: ClaudeTranscripts.Transcript) {
        if let existing = sessions.first(where: { $0.claudeSID == transcript.id }) {
            openSession(existing)
            return
        }

        // The title is a whole prompt line; a tab is a few words wide.
        let name = transcript.title.count > 32
            ? String(transcript.title.prefix(32)) + "…"
            : transcript.title
        var record = SessionRecord.make(projectShortID: project.shortID, name: name)
        record.claudeSID = transcript.id
        store.addSession(record)
        open(StudioTab(kind: .session, ref: record.tmux, title: record.name))

        let (grants, linkSettings) = linkAccess()
        sessionGrants[record.tabKey] = Set(grants)
        engine.startSession(key: record.tabKey, session: record.tmux, project: project,
                            title: record.name, resumeSID: transcript.id,
                            linkSettings: linkSettings)
        liveSessions.insert(record.tmux)
        syncSessionContext()
    }

    /// Can a closed session's conversation be brought back?
    func canResume(_ record: SessionRecord) -> Bool {
        guard let sid = record.claudeSID else { return false }
        return ClaudeTranscripts.exists(projectPath: project.path, sessionID: sid)
    }

    func renameSession(_ record: SessionRecord, to name: String) {
        guard let clean = name.nilIfEmpty, clean != record.name else { return }
        store.renameSession(tmux: record.tmux, to: clean)
        if let index = tabs.firstIndex(where: { $0.id == record.tabKey }) {
            tabs[index].title = clean
        }
        Tmux.setOption(record.tmux, "@cs_title", clean)
        syncSessionContext()
    }

    /// Closes a session: tmux is killed and the tab and sidebar entry go away —
    /// the record stays and can be reopened from "previous sessions".
    func closeSession(_ record: SessionRecord) {
        // ORDER MATTERS: release the tab and terminal view first (which kills the
        // tmux client), then kill the session. The other way round the client
        // prints "no server running / exited" on screen.
        closeTab(id: record.tabKey, killSession: false)
        engine.discard(record.tabKey)
        liveSessions.remove(record.tmux)
        store.touchSession(tmux: record.tmux)
        let name = record.tmux
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Tmux.kill(name)
        }
    }

    /// Deletes the record for good (it cannot be reopened).
    func deleteSession(_ record: SessionRecord) {
        closeSession(record)
        store.removeSession(tmux: record.tmux)
    }

    // MARK: - Terminals

    func newTerminal(name: String? = nil) {
        let terminal = TerminalTab(name: name ?? "zsh \(store.config.terminals.count + 1)")
        store.addTerminal(terminal)
        openTerminal(terminal)
    }

    func openTerminal(_ terminal: TerminalTab) {
        let tab = StudioTab(kind: .terminal, ref: terminal.id.uuidString, title: terminal.name)
        open(tab)
        engine.startShell(key: tab.terminalKey, session: tmuxName(for: terminal), project: project,
                          cwd: terminal.resolvedCwd(projectPath: project.path),
                          title: terminal.name)
    }

    func renameTerminal(_ terminal: TerminalTab, to name: String) {
        guard let clean = name.nilIfEmpty else { return }
        store.renameTerminal(terminal.id, to: clean)
        if let index = tabs.firstIndex(where: { $0.ref == terminal.id.uuidString }) {
            tabs[index].title = clean
        }
    }

    func removeTerminal(_ terminal: TerminalTab) {
        let key = "terminal:\(terminal.id.uuidString)"
        closeTab(id: key, killSession: false)
        engine.discard(key)
        store.removeTerminal(terminal.id)
        let name = tmuxName(for: terminal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Tmux.kill(name) }
    }

    private func tmuxName(for terminal: TerminalTab) -> String {
        "cs-\(project.shortID)-sh-\(terminal.id.uuidString.prefix(8).lowercased())"
    }

    // MARK: - Serviceler

    func openService(_ service: Service) {
        open(StudioTab(kind: .service, ref: service.id.uuidString, title: service.name))
    }

    func toggleService(_ service: Service) {
        let status = engine.serviceStatus[service.id] ?? .stopped
        if status.isLive { engine.stopService(service) }
        else { engine.startService(service, project: project) }
    }

    func startAllServices() {
        for service in store.config.services
        where !(engine.serviceStatus[service.id] ?? .stopped).isLive {
            engine.startService(service, project: project)
        }
    }

    func stopAllServices() {
        for service in store.config.services { engine.stopService(service) }
    }

    var runningServiceCount: Int {
        store.config.services.filter { (engine.serviceStatus[$0.id] ?? .stopped).isLive }.count
    }

    // MARK: - Linked projects

    var links: [ProjectLink] { store.config.links }

    /// Links a project and makes sure the bridge is registered with Claude.
    func link(project other: Project, allowEdits: Bool,
              role: String = "", useWhen: String = "",
              completion: ((Bool, String) -> Void)? = nil) {
        guard other.path != project.path else {
            completion?(false, "A project cannot be linked to itself.")
            return
        }
        store.addLink(ProjectLink(project: other, allowEdits: allowEdits,
                                  role: role, useWhen: useWhen))
        ProjectBridge.register(project: project, mcp: mcp) { ok, output in
            self.mcp.scan()
            completion?(ok, output)
        }
    }

    func setLinkEdits(_ link: ProjectLink, allowed: Bool) {
        var updated = link
        updated.allowEdits = allowed
        store.updateLink(updated)
    }

    func unlink(_ link: ProjectLink) { store.removeLink(link.id) }

    // MARK: - Running a linked project's skill

    /// The request the confirmation sheet is showing. Nothing runs while this is set
    /// and unanswered — that is the whole point of the queue.
    @Published var pendingRequest: SkillRequest?

    /// The skills of a linked project, for the sidebar and the palette.
    func skills(of link: ProjectLink) -> [Skill] { LinkedRuns.skills(of: link) }

    /// Asks to run a linked project's skill. Started by a person — the sidebar or the
    /// palette — so it goes straight to the confirmation without touching the queue
    /// file; the button press and the answer are the same gesture.
    func askToRun(skill: String, of link: ProjectLink) {
        pendingRequest = SkillRequest(project: link.asProject, skill: skill)
    }

    /// Picks up a request a session made through the bridge. Only the oldest pending
    /// one is shown: two confirmations at once is a dialog fighting a dialog, and the
    /// rest keep their place in the queue.
    func refreshSkillRequests() {
        guard pendingRequest == nil else { return }
        let pending = LinkedRuns.read(project)
            .filter { $0.status == .pending }
            .sorted { $0.requestedAt < $1.requestedAt }
        guard let next = pending.first else { return }
        // A request naming a project we are no longer linked to is refused here rather
        // than shown: the link is the authorization, and it can be revoked.
        guard links.contains(where: { $0.path == next.projectPath }) else {
            LinkedRuns.update(next.id, in: project) {
                $0.status = .failed
                $0.note = "\(next.projectName) is not linked to \(self.project.name)."
            }
            return
        }
        pendingRequest = next
    }

    func decline(_ request: SkillRequest) {
        LinkedRuns.update(request.id, in: project) {
            $0.status = .declined
            $0.note = "Declined in Claude Studio."
        }
        pendingRequest = nil
    }

    /// Approves a request and runs the skill IN THE PROJECT THAT OWNS IT: the runner
    /// is written for that project and the tab is `cd`'d into its directory, so the
    /// skill sees its own `CLAUDE.md`, its own settings and its own sibling skills.
    /// The tab lives in this window, so it can be watched — and answered, if the
    /// skill asks something — without leaving what you were doing.
    func approve(_ request: SkillRequest) {
        pendingRequest = nil
        let owner = request.project
        guard owner.exists else {
            LinkedRuns.update(request.id, in: project) {
                $0.status = .failed
                $0.note = "\(owner.path) no longer exists on disk."
            }
            return
        }

        Paths.ensure(Paths.runsDir(owner, skill: request.skill))
        // The runner writes `.state.json` when it starts and rewrites it when it ends.
        // Clearing it first is what lets the bridge tell THIS run's completion from
        // the last one's — otherwise a stale `finishedAt` reads as instant success.
        try? FileManager.default.removeItem(at: Paths.runState(owner, skill: request.skill))

        let script = Scheduler.writeRunnerScript(
            project: owner, skill: request.skill,
            prompt: Scheduler.promptFor(project: owner, skill: request.skill,
                                        extra: request.prompt))

        LinkedRuns.update(request.id, in: project) { $0.status = .running }

        let title = "\(owner.name): \(request.skill)"
        let tab = StudioTab(kind: .script, ref: "linked-\(request.id)", title: title)
        open(tab)
        engine.runCommandTab(key: tab.terminalKey, name: title,
                             command: "CS_RUN_MODE=linked /bin/zsh \(Shell.quoted(script.path))",
                             cwd: owner.path)
        watchFinish(of: request, owner: owner)
    }

    /// Polls the runner's own state file until it reports an exit code, then settles
    /// the request. The state file is the runner's, not ours — a scheduled run and a
    /// linked one finish through exactly the same signal.
    private func watchFinish(of request: SkillRequest, owner: Project) {
        let stateURL = Paths.runState(owner, skill: request.skill)
        Task { @MainActor in
            // Long enough for a deploy, and it stops either way: the record is left
            // `running` and the bridge reports the tab is still open.
            for _ in 0..<720 {
                try? await Task.sleep(for: .seconds(5))
                guard let data = try? Data(contentsOf: stateURL),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let code = json["exitCode"] as? Int
                else { continue }
                LinkedRuns.update(request.id, in: self.project) {
                    $0.status = .finished
                    $0.exitCode = code
                    $0.reportFile = json["reportFile"] as? String
                }
                return
            }
        }
    }

    /// Sessions that were started before the current set of writable links, and so
    /// cannot see them yet.
    func sessionNeedsReopen(_ tabKey: String) -> Bool {
        guard let granted = sessionGrants[tabKey] else { return !store.writableLinkPaths.isEmpty }
        return granted != Set(store.writableLinkPaths)
    }

    /// Closes and reopens a session so it picks up the current links. The conversation
    /// is resumed, so nothing is lost.
    func reopenSession(tmux: String) {
        guard let record = store.session(tmux: tmux) else { return }
        closeSession(record)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let fresh = self.store.session(tmux: tmux) else { return }
            self.openSession(fresh)
        }
    }

    // MARK: - MCP servers

    /// Runs an interactive `claude mcp` subcommand in its own tab — sign-in flows
    /// and `get` both print to a terminal, so they belong in one.
    func runMCPCommand(_ subcommand: String, title: String) {
        let tab = StudioTab(kind: .script, ref: "mcp-\(subcommand)", title: title)
        open(tab)
        engine.runCommandTab(key: tab.terminalKey, name: title,
                             command: "claude mcp \(subcommand)", cwd: project.path)
    }

    // MARK: - Scripts (one-shot shell commands)

    /// Opens the script's tab and runs it. Pressing it again re-runs in place.
    func runScript(_ script: ProjectScript) {
        let tab = StudioTab(kind: .script, ref: script.id.uuidString, title: script.name)
        open(tab)
        engine.runCommandTab(key: tab.terminalKey, name: script.name,
                             command: script.command,
                             cwd: script.resolvedCwd(projectPath: project.path))
    }

    func runScriptInBackground(_ script: ProjectScript) {
        engine.runInBackground(name: script.name, command: script.command,
                               cwd: script.resolvedCwd(projectPath: project.path))
    }

    func removeScript(_ script: ProjectScript) {
        let key = "script:\(script.id.uuidString)"
        closeTab(id: key, killSession: false)
        engine.discard(key)
        store.removeScript(script.id)
    }

    // MARK: - Claude commands (.claude/commands)

    func openClaudeCommand(_ command: ClaudeCommand) {
        open(StudioTab(kind: .command, ref: command.name, title: command.invocation))
    }

    /// Runs the slash command in a fresh Claude session. Commands that take an
    /// argument are typed in but not sent, so the argument can be filled in first.
    func runClaudeCommand(_ command: ClaudeCommand) {
        let takesArgument = command.argumentHint != nil
        newSession(name: command.invocation,
                   prompt: command.invocation,
                   autoRun: !takesArgument)
    }

    /// Opens a session that writes a new slash command, the way the skills pane
    /// creates a skill.
    func createCommandWithClaude() {
        newSession(name: "new command", prompt: Self.createCommandPrompt, autoRun: true)
    }

    static let createCommandPrompt = """
    Create a new Claude Code slash command for this project at \
    `.claude/commands/<name>.md`.

    Ask me what the command should do first. Give it frontmatter with a one-line \
    `description` (and `argument-hint` if it takes an argument), then write the body \
    as instructions to follow when the command runs. Use `$ARGUMENTS` where the \
    argument belongs.
    """

    // MARK: - Services and scripts, written by Claude

    /// Opens a Claude session that writes `.cs/services.json` itself.
    ///
    /// The app does not parse an answer back: Claude edits the file, the `.cs`
    /// watcher notices and the list updates. That is also why the same entry
    /// point serves "add some" and "change this one" — it is one conversation
    /// about one file, and the user can keep talking to it.
    func createServicesWithClaude(request: String, focus: Service? = nil) {
        newSession(name: focus == nil ? "services" : "service: \(focus!.name)",
                   prompt: Self.servicesPrompt(project: project, request: request, focus: focus),
                   autoRun: true)
    }

    func createScriptsWithClaude(request: String, focus: ProjectScript? = nil) {
        newSession(name: focus == nil ? "scripts" : "script: \(focus!.name)",
                   prompt: Self.scriptsPrompt(project: project, request: request, focus: focus),
                   autoRun: true)
    }

    static func servicesPrompt(project: Project, request: String, focus: Service? = nil) -> String {
        var prompt = """
        YOUR TASK: work out which long-running development processes this project \
        actually has, then write them to `\(Paths.services(project).path)`. Claude Studio \
        reads that file live — save it and the services appear in the sidebar, no restart.

        HOW TO SCAN:
        - Walk the root AND subdirectories, including monorepo layouts like backend/, \
        frontend/, api/, apps/*, packages/*.
        - Sources: package.json "scripts" (dev/start/watch/serve), composer.json, artisan \
        commands (serve, horizon, queue:work, reverb:start, schedule:work), Makefile targets, \
        docker-compose services, Procfile, README setup sections.
        - Derive ports from the real configuration (vite.config, next.config, .env PORT/APP_URL). \
        Defaults if nothing says otherwise: Vite 5173, Next/Nuxt 3000, Astro 4321, \
        Laravel serve 8000, Reverb 8080, Storybook 6006.

        WHAT BELONGS HERE: processes that KEEP RUNNING — dev servers, queue workers, \
        websocket servers, `docker compose up`, watchers. A task that finishes on its own \
        (build, migrate, test) is a SCRIPT and belongs in `\(Paths.scripts(project).path)` \
        instead; do not put it in this file.

        FORMAT — a JSON array. No comments, no trailing commas:
        [
          { "name": "Frontend", "command": "npm run dev", "cwd": "frontend", "port": 5173, "autoStart": true },
          { "name": "Queue", "command": "php artisan queue:work" },
          { "name": "Reverb", "command": "php artisan reverb:start", "port": 8080 }
        ]

        THE FIELDS:
        - `name` — what the sidebar shows. Required.
        - `command` — run through `zsh -l -i -c` inside tmux. Required.
        - `cwd` — optional; relative to the project root, or absolute. Omit it for the root itself.
        - `port` — optional; how the app decides the service is up, and what it offers to free.
        - `autoStart` — optional; true means it starts when the project window opens.

        RULES:
        - KEEP the existing entries and their `id` fields exactly as they are — an id is \
        what ties a service to its running process. New entries need no id; the app fills it in.
        - `cwd` must be a directory that exists. Check with `ls` before writing it.
        - Only `autoStart` the ones that genuinely start every day.
        - Be lean: no service you cannot point at a file for. A wrong command is worse than \
        a missing one.
        - Write the file yourself (Write/Edit), keep it valid JSON, then summarise what you \
        added or changed in one line each.
        """
        if let focus {
            prompt += """


            FOCUS ON THIS EXISTING SERVICE: "\(focus.name)" — command `\(focus.command)`\
            \(focus.port.map { ", port \($0)" } ?? ""). Change that entry; leave the others alone \
            unless I say otherwise.
            """
        }
        return prompt + userRequestBlock(request)
    }

    static func scriptsPrompt(project: Project, request: String, focus: ProjectScript? = nil) -> String {
        var prompt = """
        YOUR TASK: work out which one-shot commands this project is actually run with, then \
        write them to `\(Paths.scripts(project).path)`. Claude Studio reads that file live — \
        save it and the scripts appear in the sidebar, no restart.

        HOW TO SCAN:
        - Walk the root AND subdirectories, including monorepo layouts like backend/, \
        frontend/, api/, apps/*, packages/*.
        - Sources: package.json "scripts" (build/test/lint/typecheck/migrate/seed), composer.json, \
        artisan commands (migrate, optimize, cache:clear, test), Makefile targets, \
        CI workflow files (what does the pipeline actually run?), README.

        WHAT BELONGS HERE: commands that RUN ONCE AND FINISH — build, test, lint, typecheck, \
        migrate, seed, install, deploy, cache clearing. A process that keeps running \
        (dev server, worker, docker compose up) is a SERVICE and belongs in \
        `\(Paths.services(project).path)` instead; do not put it in this file.

        FORMAT — a JSON array. No comments, no trailing commas:
        [
          { "name": "Build", "command": "npm run build", "cwd": "frontend" },
          { "name": "Test", "command": "npm test" },
          { "name": "Migrate", "command": "php artisan migrate" }
        ]

        THE FIELDS:
        - `name` — what the sidebar shows. Required.
        - `command` — run through `zsh -l -i -c` in its own tab, exit code shown in place. Required.
        - `cwd` — optional; relative to the project root, or absolute. Omit it for the root itself.

        RULES:
        - KEEP the existing entries and their `id` fields exactly as they are. New entries \
        need no id; the app fills it in.
        - `cwd` must be a directory that exists. Check with `ls` before writing it.
        - Nothing destructive without it being obvious from the name: a script that drops a \
        database must say so.
        - Be lean: no script you cannot point at a file for.
        - Write the file yourself (Write/Edit), keep it valid JSON, then summarise what you \
        added or changed in one line each.
        """
        if let focus {
            prompt += """


            FOCUS ON THIS EXISTING SCRIPT: "\(focus.name)" — command `\(focus.command)`. \
            Change that entry; leave the others alone unless I say otherwise.
            """
        }
        return prompt + userRequestBlock(request)
    }

    /// The user's own words, last and clearly marked — everything above is context
    /// for carrying them out.
    private static func userRequestBlock(_ request: String) -> String {
        guard let clean = request.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return "\n\nI have not asked for anything specific: scan the project and propose "
                 + "what makes sense. Tell me what you are about to write before you write it."
        }
        return "\n\nWHAT I ASKED FOR (this comes first):\n\(clean)"
    }

    // MARK: - Skills

    func openSkill(_ skill: Skill) {
        open(StudioTab(kind: .skill, ref: skill.name, title: skill.name))
        runs.refresh(skill: skill.name)
    }

    /// Opens a session that creates a new skill. The prompt names Anthropic's own
    /// `skill-development` skill, which Claude loads by itself when the plugin is
    /// installed; without it Claude still writes a plain SKILL.md.
    func createSkillWithClaude() {
        newSession(name: "new skill", prompt: Self.createSkillPrompt, autoRun: true)
    }

    static let createSkillPrompt = """
    Create a new Claude Code skill for this project at `.claude/skills/<name>/SKILL.md`.

    Use the skill-development skill for the structure and description conventions if \
    it is available. Ask me what the skill should do and when it should trigger, then \
    write the file with `name` and `description` in its frontmatter and keep the body \
    focused on instructions rather than prose.
    """

    /// Runs the skill in a visible Claude session.
    func runSkillVisible(_ skill: Skill) {
        Paths.ensure(Paths.runsDir(project, skill: skill.name))
        let env = Runs.environment(project: project, skill: skill.name, mode: "manual")
        newSession(name: "skill: \(skill.name)",
                   prompt: Scheduler.promptFor(project: project, skill: skill.name),
                   autoRun: true, extraEnv: env)
    }

    func runSkillBackground(_ skill: Skill) {
        runs.runInBackground(skill: skill.name)
    }

    /// Runs the skill's scheduled runner in a visible tab.
    ///
    /// The same script launchd runs, so a manual run and a scheduled one produce the
    /// same report — but in a terminal, because "it is running somewhere" with nothing
    /// on screen is not a state worth showing.
    func runSkillNow(_ skill: String) {
        Paths.ensure(Paths.runsDir(project, skill: skill))
        let script = Scheduler.writeRunnerScript(
            project: project, skill: skill,
            prompt: Scheduler.promptFor(project: project, skill: skill))
        runs.markRunning(skill)

        let tab = StudioTab(kind: .script, ref: "run-\(skill)", title: "run: \(skill)")
        open(tab)
        engine.runCommandTab(key: tab.terminalKey, name: "run: \(skill)",
                             command: "CS_RUN_MODE=manual /bin/zsh \(Shell.quoted(script.path))",
                             cwd: project.path)
        // The runner writes its report and state file at the end; the poll would find
        // them within twenty seconds, but the pane should not lag that far behind.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.runs.refresh(skill: skill)
        }
    }

    /// Is the conversation behind this report still resumable?
    ///
    /// The sidecar alone is not enough: a run that died before Claude wrote anything
    /// leaves an id with no transcript, and `--resume` on that prints "No session
    /// found" and exits — the dead terminal `openSession` guards against as well.
    func canContinue(_ run: SkillRun) -> Bool {
        guard let sid = run.sessionID else { return false }
        return ClaudeTranscripts.exists(projectPath: project.path, sessionID: sid)
    }

    /// Picks the report's own conversation back up in a session tab.
    ///
    /// A report says what was found; the answer to it — "now fix that" — belongs to
    /// the conversation that found it, which still holds everything it read. So this
    /// resumes that very `session_id` rather than starting a session that would have
    /// to rediscover the problem from the report's summary.
    ///
    /// The follow-up is TYPED, not sent: a scheduled run is unattended by definition,
    /// and the first thing its conversation does when it comes back should be the
    /// user's decision, not a message that was already on its way.
    func continueRun(skill: String, run: SkillRun, prompt: String) {
        guard let sid = run.sessionID else { return }
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        // One conversation, one tmux session: continuing the same report twice
        // returns to the tab it opened the first time.
        let record: SessionRecord
        if let existing = sessions.first(where: { $0.claudeSID == sid }) {
            record = existing
        } else {
            var made = SessionRecord.make(
                projectShortID: project.shortID,
                name: "\(skill) · \(run.startedAt?.shortStamp ?? run.fileStem)")
            made.claudeSID = sid
            store.addSession(made)
            record = made
        }

        open(StudioTab(kind: .session, ref: record.tmux, title: record.name))

        // Already attached and running: `startSession` would bail out at its own
        // guard and the message would be typed into nothing.
        if engine.isLive(record.tabKey) {
            if !message.isEmpty { engine.send(key: record.tabKey, text: message) }
            return
        }

        let (grants, linkSettings) = linkAccess()
        sessionGrants[record.tabKey] = Set(grants)
        engine.startSession(key: record.tabKey, session: record.tmux, project: project,
                            title: record.name, resumeSID: sid,
                            initialPrompt: message.nilIfEmpty,
                            linkSettings: linkSettings)
        store.touchSession(tmux: record.tmux)
        liveSessions.insert(record.tmux)
        syncSessionContext()
    }

    func openCron(_ schedule: Schedule) {
        open(StudioTab(kind: .cron, ref: schedule.skill, title: schedule.skill))
        runs.refresh(skill: schedule.skill)
    }

    // MARK: - Tabs

    func open(_ tab: StudioTab) {
        if !tabs.contains(where: { $0.id == tab.id }) { tabs.append(tab) }
        activeTabID = tab.id
    }

    /// Closes a tab. For Claude tabs the tmux session ends too — leaving it alive
    /// in the background after the user pressed "close" would be surprising.
    func closeTab(id: String, killSession: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]

        if killSession, tab.kind == .session, let record = store.session(tmux: tab.ref) {
            closeSession(record)
            return
        }
        // Closing a terminal from its tab closes it completely — no ghost row is
        // left in the sidebar.
        if killSession, tab.kind == .terminal, let id = UUID(uuidString: tab.ref),
           let terminal = store.terminal(id) {
            removeTerminal(terminal)
            return
        }

        tabs.remove(at: index)
        if tab.kind == .service || tab.kind == .script { engine.discard(tab.terminalKey) }
        if activeTabID == id {
            activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    var activeTab: StudioTab? { tabs.first { $0.id == activeTabID } }

    /// ⌘1…⌘9 — jumps to the nth tab if it exists.
    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    func selectNextTab(_ offset: Int) {
        guard !tabs.isEmpty, let current = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        activeTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    /// ⌘T is context sensitive: a new Claude session while on a Claude tab,
    /// a new terminal otherwise.
    func newTabForContext() {
        if activeTab?.kind == .session || (activeTab == nil && pane == .sessions) {
            newSession()
        } else {
            newTerminal()
        }
    }
}
