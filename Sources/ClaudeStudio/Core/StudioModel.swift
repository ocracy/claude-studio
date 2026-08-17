import Foundation
import SwiftUI
import AppKit

/// All state for one window (one project). Views read it; the business logic
/// lives here, not in the view layer.
@MainActor
final class StudioModel: ObservableObject {

    enum Pane: String, CaseIterable, Identifiable {
        case sessions, skills, mcp, cron, services, commands, terminals
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sessions:  return "sessions"
            case .skills:    return "skills"
            case .mcp:       return "mcp servers"
            case .cron:      return "scheduled"
            case .services:  return "services"
            case .commands:  return "commands"
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
            case .commands:  return "bolt"
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
            case .commands:  return "Commands"
            case .terminals: return "Terminals"
            }
        }
    }

    let project: Project
    let store: ProjectStore
    let skills: SkillStore
    let mcp = MCPStore()
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

    private var refreshTimer: Timer?
    private var autoAttachPending = true

    init(project: Project) {
        self.project = project
        self.store = ProjectStore(project: project)
        self.skills = SkillStore()
        self.runs = RunStore(project: project)
        self.engine = TerminalEngine()
        self.sidebarWidth = CGFloat(store.config.sidebarWidth)
        self.pane = Pane(rawValue: store.config.lastView) ?? .sessions
        engine.projectName = project.name
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

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in
                self.refreshSessions()
                self.engine.refreshExternalStatuses(self.store.config.services)
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

        for service in store.config.services { engine.stopService(service) }
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
                .filter { !$0.name.contains("-sh-") && !known.contains($0.name) }
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
                .filter { !$0.name.contains("-sh-") }
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

    @discardableResult
    func newSession(name: String? = nil, prompt: String? = nil, autoRun: Bool = false,
                    extraEnv: [String: String] = [:]) -> SessionRecord {
        let title = name ?? nextSessionName()
        let record = SessionRecord.make(projectShortID: project.shortID, name: title)
        store.addSession(record)
        open(StudioTab(kind: .session, ref: record.tmux, title: title))
        engine.startSession(key: record.tabKey, session: record.tmux, project: project,
                            title: title, initialPrompt: prompt, autoRun: autoRun,
                            extraEnv: extraEnv)
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

        engine.startSession(key: record.tabKey, session: record.tmux, project: project,
                            title: record.name, resumeSID: resume)
        store.touchSession(tmux: record.tmux)
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

    // MARK: - MCP servers

    /// Runs an interactive `claude mcp` subcommand in its own tab — sign-in flows
    /// and `get` both print to a terminal, so they belong in one.
    func runMCPCommand(_ subcommand: String, title: String) {
        let tab = StudioTab(kind: .command, ref: "mcp-\(subcommand)", title: title)
        open(tab)
        engine.runCommandTab(key: tab.terminalKey, name: title,
                             command: "claude mcp \(subcommand)", cwd: project.path)
    }

    // MARK: - Commands

    /// Opens the command's tab and runs it. Pressing it again re-runs in place.
    func runCommand(_ command: ProjectCommand) {
        let tab = StudioTab(kind: .command, ref: command.id.uuidString, title: command.name)
        open(tab)
        engine.runCommandTab(key: tab.terminalKey, name: command.name,
                             command: command.command,
                             cwd: command.resolvedCwd(projectPath: project.path))
    }

    func runCommandInBackground(_ command: ProjectCommand) {
        engine.runInBackground(name: command.name, command: command.command,
                               cwd: command.resolvedCwd(projectPath: project.path))
    }

    func removeCommand(_ command: ProjectCommand) {
        let key = "command:\(command.id.uuidString)"
        closeTab(id: key, killSession: false)
        engine.discard(key)
        store.removeCommand(command.id)
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
        if tab.kind == .service || tab.kind == .command { engine.discard(tab.terminalKey) }
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
