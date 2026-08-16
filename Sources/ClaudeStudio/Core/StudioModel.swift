import Foundation
import SwiftUI
import AppKit

/// Bir pencerenin (bir projenin) tüm durumu. Görünümler bunu okur; iş mantığı
/// buradadır, görünüm katmanında değil.
@MainActor
final class StudioModel: ObservableObject {

    enum Pane: String, CaseIterable, Identifiable {
        case sessions, skills, cron, services, terminals
        var id: String { rawValue }

        var title: String {
            switch self {
            case .sessions:  return "oturumlar"
            case .skills:    return "beceriler"
            case .cron:      return "zamanlanmış"
            case .services:  return "servisler"
            case .terminals: return "terminaller"
            }
        }
        var icon: String {
            switch self {
            case .sessions:  return "bubble.left.and.bubble.right"
            case .skills:    return "sparkles"
            case .cron:      return "clock"
            case .services:  return "server.rack"
            case .terminals: return "terminal"
            }
        }
        var help: String {
            switch self {
            case .sessions:  return "Claude oturumları"
            case .skills:    return "Beceriler (.claude/skills)"
            case .cron:      return "Zamanlanmış çalışmalar"
            case .services:  return "Servisler"
            case .terminals: return "Terminaller"
            }
        }
    }

    let project: Project
    let store: ProjectStore
    let skills: SkillStore
    let runs: RunStore
    let engine: TerminalEngine

    @Published var pane: Pane = .sessions
    @Published var tabs: [StudioTab] = []
    @Published var activeTabID: String?
    /// Şu anda tmux'ta yaşayan oturum adları.
    @Published var liveSessions: Set<String> = []
    @Published var sidebarWidth: CGFloat = 260
    /// Skill/cron panelinde seçili çalışma kaydı.
    @Published var selectedRun: [String: String] = [:]

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

    // MARK: - Yaşam döngüsü

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

    /// Pencere kapanırken: terminaller ve servisler kapanır (kullanıcı onları
    /// bu pencerede açtı), Claude oturumları tmux'ta yaşamaya devam eder —
    /// kalıcı olmalarının bütün sebebi bu.
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

    // MARK: - Oturumlar

    /// Kayıtlı oturumlar, yeniden eskiye.
    var sessions: [SessionRecord] {
        store.config.sessions.sorted { $0.lastUsed > $1.lastUsed }
    }

    /// tmux'ta yaşayanlar (kenar çubuğunda listelenenler).
    var openSessions: [SessionRecord] { sessions.filter { liveSessions.contains($0.tmux) } }

    /// Kapatılmış ama geri açılabilecek oturumlar.
    var pastSessions: [SessionRecord] { sessions.filter { !liveSessions.contains($0.tmux) } }

    func attention(of record: SessionRecord) -> Attention {
        engine.attention[record.tabKey] ?? .idle
    }

    var attentionCount: Int {
        openSessions.filter { attention(of: $0) == .waiting }.count
    }

    /// tmux'ta bu projeye ait olup kaydı olmayan oturumları kayda alır —
    /// başka bir makineden/sürümden kalanlar da listede görünür.
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

    /// Canlı oturum kümesini tmux'tan tazeler. tmux tek doğruluk kaynağıdır.
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

    /// Bildirim metinleri motorun elinde olsun.
    private func syncSessionContext() {
        var titles: [String: String] = [:]
        for record in store.config.sessions { titles[record.tabKey] = record.name }
        engine.sessionTitles = titles
    }

    /// Hook'un yakaladığı Claude oturum kimliklerini kayda geçir — kapatılan bir
    /// oturum `--resume` ile aynı konuşmadan devam edebilsin.
    private func persistClaudeSIDs() {
        for record in store.config.sessions {
            guard let sid = engine.claudeSIDs[record.tabKey], sid != record.claudeSID else { continue }
            store.touchSession(tmux: record.tmux, claudeSID: sid)
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

    /// Kayıtlı bir oturumu açar. tmux'ta yaşıyorsa bağlanır; ölmüşse Claude
    /// oturum kimliği biliniyorsa `--resume` ile aynı konuşmadan devam eder.
    func openSession(_ record: SessionRecord) {
        open(StudioTab(kind: .session, ref: record.tmux, title: record.name))

        // Oturum tmux'ta yaşıyorsa yalnız bağlanılır. Ölmüşse ancak konuşma
        // diskte duruyorsa `--resume` denenir; yoksa Claude "No session found"
        // deyip anında çıkar ve elde ölü bir terminal kalırdı.
        let alive = liveSessions.contains(record.tmux)
        var resume: String?
        if !alive, let sid = record.claudeSID {
            if ClaudeTranscripts.exists(projectPath: project.path, sessionID: sid) {
                resume = sid
            } else {
                // Kayıt bayat: bir daha denenmesin.
                store.updateSession({ var copy = record; copy.claudeSID = nil; return copy }())
            }
        }

        engine.startSession(key: record.tabKey, session: record.tmux, project: project,
                            title: record.name, resumeSID: resume)
        store.touchSession(tmux: record.tmux)
        liveSessions.insert(record.tmux)
        syncSessionContext()
    }

    /// Kapatılmış bir oturumun konuşması geri getirilebilir mi?
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

    /// Oturumu kapatır: tmux öldürülür, sekme ve kenar çubuğundan düşer —
    /// kayıt kalır, "önceki oturumlar" altından geri açılabilir.
    func closeSession(_ record: SessionRecord) {
        // SIRA ÖNEMLİ: önce sekme ve terminal görünümü bırakılır (tmux istemcisi
        // ölür), sonra oturum öldürülür. Ters sırada istemci ekrana
        // "no server running / exited" basardı.
        closeTab(id: record.tabKey, killSession: false)
        engine.discard(record.tabKey)
        liveSessions.remove(record.tmux)
        store.touchSession(tmux: record.tmux)
        let name = record.tmux
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            Tmux.kill(name)
        }
    }

    /// Kaydı tamamen siler (geri açılamaz).
    func deleteSession(_ record: SessionRecord) {
        closeSession(record)
        store.removeSession(tmux: record.tmux)
    }

    // MARK: - Terminaller

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

    // MARK: - Servisler

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

    // MARK: - Beceriler

    func openSkill(_ skill: Skill) {
        open(StudioTab(kind: .skill, ref: skill.name, title: skill.name))
        runs.refresh(skill: skill.name)
    }

    /// Beceriyi görünür bir Claude oturumunda çalıştırır.
    func runSkillVisible(_ skill: Skill) {
        Paths.ensure(Paths.runsDir(project, skill: skill.name))
        let env = Runs.environment(project: project, skill: skill.name, mode: "manual")
        newSession(name: "beceri: \(skill.name)",
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

    // MARK: - Sekmeler

    func open(_ tab: StudioTab) {
        if !tabs.contains(where: { $0.id == tab.id }) { tabs.append(tab) }
        activeTabID = tab.id
    }

    /// Sekmeyi kapatır. Claude sekmelerinde tmux oturumu da sonlanır — kullanıcı
    /// "kapat" dediğinde oturumun arkada yaşamaya devam etmesi şaşırtıcı olurdu.
    func closeTab(id: String, killSession: Bool = true) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]

        if killSession, tab.kind == .session, let record = store.session(tmux: tab.ref) {
            closeSession(record)
            return
        }
        // Terminali sekmeden kapatmak onu tamamen kapatır — kenar çubuğunda
        // hayalet bir satır bırakmaz.
        if killSession, tab.kind == .terminal, let id = UUID(uuidString: tab.ref),
           let terminal = store.terminal(id) {
            removeTerminal(terminal)
            return
        }

        tabs.remove(at: index)
        if tab.kind == .service { engine.discard(tab.terminalKey) }
        if activeTabID == id {
            activeTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    var activeTab: StudioTab? { tabs.first { $0.id == activeTabID } }

    func selectNextTab(_ offset: Int) {
        guard !tabs.isEmpty, let current = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        activeTabID = tabs[(index + offset + tabs.count) % tabs.count].id
    }

    /// ⌘T bağlama duyarlıdır: Claude sekmesindeysen yeni Claude oturumu,
    /// değilsen yeni terminal açar.
    func newTabForContext() {
        if activeTab?.kind == .session || (activeTab == nil && pane == .sessions) {
            newSession()
        } else {
            newTerminal()
        }
    }
}
