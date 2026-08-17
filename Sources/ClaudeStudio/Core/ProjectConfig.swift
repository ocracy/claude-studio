import Foundation
import SwiftUI

/// The in-memory shape of a project's settings. On disk it is not one file:
/// each section lives in **its own file** under `.cs/`:
///
/// ```
/// .cs/
/// ├── services.json    services
/// ├── scripts.json     one-shot shell commands
/// ├── terminals.json   terminals
/// ├── schedules.json   scheduled runs
/// ├── sessions.json    Claude session records
/// └── settings.json    interface preferences
/// ```
///
/// The split is practical: editing or sharing the service list needs a small,
/// readable file of its own. If interface preferences lived in the same file,
/// every sidebar resize would dirty a file the team shares.
struct ProjectConfig: Codable, Equatable {
    var sessions: [SessionRecord] = []
    var services: [Service] = []
    var scripts: [ProjectScript] = []
    var terminals: [TerminalTab] = []
    var schedules: [Schedule] = []
    var settings = ProjectSettings()

    static let empty = ProjectConfig()

    var sidebarWidth: Double {
        get { settings.sidebarWidth }
        set { settings.sidebarWidth = newValue }
    }
    var lastView: String {
        get { settings.lastView }
        set { settings.lastView = newValue }
    }

    init() {}

    /// Decoding is deliberately tolerant: a missing key falls back to its default.
    /// Swift's synthesized decoder THROWS on a missing key, so this is written by
    /// hand — both the legacy single-file shape (flat `sidebarWidth`, `lastView`)
    /// and the new shape are read by the same code, and a half-edited file does
    /// not take the whole configuration down with it.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        sessions  = value(.sessions, [])
        services  = value(.services, [])
        scripts   = value(.scripts, [])
        terminals = value(.terminals, [])
        schedules = value(.schedules, [])

        if let nested: ProjectSettings = (try? box.decodeIfPresent(ProjectSettings.self, forKey: .settings)) ?? nil {
            settings = nested
        } else {
            settings = ProjectSettings(sidebarWidth: value(.sidebarWidth, 260.0),
                                       lastView: value(.lastView, "sessions"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(sessions, forKey: .sessions)
        try box.encode(services, forKey: .services)
        try box.encode(scripts, forKey: .scripts)
        try box.encode(terminals, forKey: .terminals)
        try box.encode(schedules, forKey: .schedules)
        try box.encode(settings, forKey: .settings)
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, services, scripts, commands, terminals, schedules, settings, sidebarWidth, lastView
    }
}

/// `.cs/settings.json` — interface preferences for this project only.
struct ProjectSettings: Codable, Equatable {
    var sidebarWidth: Double = 260
    var lastView: String = "sessions"
}

/// Loads the configuration, writes back only the section that changed and keeps
/// launchd jobs in sync with the schedules.
@MainActor
final class ProjectStore: ObservableObject {
    let project: Project
    @Published private(set) var config: ProjectConfig

    init(project: Project) {
        self.project = project
        self.config = Self.load(project)
    }

    // MARK: - Queries

    func session(tmux: String) -> SessionRecord? { config.sessions.first { $0.tmux == tmux } }
    func service(_ id: UUID) -> Service? { config.services.first { $0.id == id } }
    func script(_ id: UUID) -> ProjectScript? { config.scripts.first { $0.id == id } }
    func terminal(_ id: UUID) -> TerminalTab? { config.terminals.first { $0.id == id } }
    func schedule(for skill: String) -> Schedule? { config.schedules.first { $0.skill == skill } }

    var activeSchedules: [Schedule] { config.schedules.filter(\.enabled) }

    /// The next scheduled run (status bar).
    var nextRun: (skill: String, date: Date)? {
        config.schedules
            .compactMap { s in s.nextFire.map { (s.skill, $0) } }
            .min { $0.1 < $1.1 }
    }

    // MARK: - Mutation

    /// The single write path. Only the section that actually changed is written.
    func mutate(_ change: (inout ProjectConfig) -> Void) {
        let before = config
        var copy = config
        change(&copy)
        guard copy != before else { return }
        config = copy
        save(changed: before)
    }

    // Sessions

    func addSession(_ record: SessionRecord) { mutate { $0.sessions.append(record) } }

    func updateSession(_ record: SessionRecord) {
        mutate {
            guard let i = $0.sessions.firstIndex(where: { $0.id == record.id }) else { return }
            $0.sessions[i] = record
        }
    }

    func renameSession(tmux: String, to name: String) {
        mutate {
            guard let i = $0.sessions.firstIndex(where: { $0.tmux == tmux }) else { return }
            $0.sessions[i].name = name
        }
    }

    func touchSession(tmux: String, claudeSID: String? = nil) {
        mutate {
            guard let i = $0.sessions.firstIndex(where: { $0.tmux == tmux }) else { return }
            $0.sessions[i].lastUsed = Date()
            if let claudeSID, !claudeSID.isEmpty { $0.sessions[i].claudeSID = claudeSID }
        }
    }

    func removeSession(tmux: String) { mutate { $0.sessions.removeAll { $0.tmux == tmux } } }

    // Services

    func addService(_ service: Service) { mutate { $0.services.append(service) } }

    func updateService(_ service: Service) {
        mutate {
            guard let i = $0.services.firstIndex(where: { $0.id == service.id }) else { return }
            $0.services[i] = service
        }
    }

    func removeService(_ id: UUID) { mutate { $0.services.removeAll { $0.id == id } } }

    // Scripts

    func addScript(_ script: ProjectScript) { mutate { $0.scripts.append(script) } }

    func updateScript(_ script: ProjectScript) {
        mutate {
            guard let i = $0.scripts.firstIndex(where: { $0.id == script.id }) else { return }
            $0.scripts[i] = script
        }
    }

    func removeScript(_ id: UUID) { mutate { $0.scripts.removeAll { $0.id == id } } }

    // Terminals

    func addTerminal(_ terminal: TerminalTab) { mutate { $0.terminals.append(terminal) } }

    func renameTerminal(_ id: UUID, to name: String) {
        mutate {
            guard let i = $0.terminals.firstIndex(where: { $0.id == id }) else { return }
            $0.terminals[i].name = name
        }
    }

    func removeTerminal(_ id: UUID) { mutate { $0.terminals.removeAll { $0.id == id } } }

    // Schedules — JSON and launchd are updated together.

    func setSchedule(_ schedule: Schedule) {
        mutate {
            if let i = $0.schedules.firstIndex(where: { $0.skill == schedule.skill }) {
                $0.schedules[i] = schedule
            } else {
                $0.schedules.append(schedule)
            }
        }
        let snapshot = project
        Task.detached(priority: .utility) {
            Scheduler.install(project: snapshot, schedule: schedule)
        }
    }

    func removeSchedule(skill: String) {
        mutate { $0.schedules.removeAll { $0.skill == skill } }
        let snapshot = project
        Task.detached(priority: .utility) {
            Scheduler.uninstall(project: snapshot, skill: skill)
        }
    }

    /// Removes orphaned launchd jobs for skills that no longer exist on disk.
    func pruneOrphanSchedules(existing: Set<String>) {
        let orphans = config.schedules.map(\.skill).filter { !existing.contains($0) }
        guard !orphans.isEmpty else { return }
        mutate { $0.schedules.removeAll { orphans.contains($0.skill) } }
        let snapshot = project
        Task.detached(priority: .utility) {
            for skill in orphans { Scheduler.uninstall(project: snapshot, skill: skill) }
        }
    }

    // MARK: - IO

    private static func load(_ project: Project) -> ProjectConfig {
        var config = ProjectConfig.empty
        config.services  = read([Service].self,        from: Paths.services(project))  ?? []
        config.scripts   = read([ProjectScript].self,  from: Paths.scripts(project))   ?? []
        // `commands.json` was this file's name before Claude's own slash commands got
        // a section of their own; read it once so nothing is lost.
        if config.scripts.isEmpty,
           let legacy = read([ProjectScript].self, from: Paths.legacyCommands(project)),
           !legacy.isEmpty {
            config.scripts = legacy
            write(legacy, to: Paths.scripts(project))
            try? FileManager.default.removeItem(at: Paths.legacyCommands(project))
        }
        config.terminals = read([TerminalTab].self,   from: Paths.terminals(project)) ?? []
        config.schedules = read([Schedule].self,      from: Paths.schedules(project)) ?? []
        config.sessions  = read([SessionRecord].self, from: Paths.sessions(project))  ?? []
        config.settings  = read(ProjectSettings.self, from: Paths.settings(project))  ?? ProjectSettings()

        // Migration from the legacy single-file format: read once, written to the
        // split files, then removed.
        let legacy = Paths.legacyConfig(project)
        if FileManager.default.fileExists(atPath: legacy.path),
           let old = read(ProjectConfig.self, from: legacy) {
            if config.services.isEmpty  { config.services  = old.services }
            if config.scripts.isEmpty   { config.scripts   = old.scripts }
            if config.terminals.isEmpty { config.terminals = old.terminals }
            if config.schedules.isEmpty { config.schedules = old.schedules }
            if config.sessions.isEmpty  { config.sessions  = old.sessions }
            config.settings = old.settings
            writeAll(config, project: project)
            try? FileManager.default.removeItem(at: legacy)
        }
        return config
    }

    private static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        Paths.writeAtomically(data, to: url)
    }

    private static func writeAll(_ config: ProjectConfig, project: Project) {
        Paths.ensure(Paths.csDir(project))
        write(config.services,  to: Paths.services(project))
        write(config.scripts,   to: Paths.scripts(project))
        write(config.terminals, to: Paths.terminals(project))
        write(config.schedules, to: Paths.schedules(project))
        write(config.sessions,  to: Paths.sessions(project))
        write(config.settings,  to: Paths.settings(project))
    }

    /// Writes only the section that changed, so resizing the sidebar does not
    /// touch the services file.
    private func save(changed previous: ProjectConfig) {
        Paths.ensure(Paths.csDir(project))
        if config.services  != previous.services  { Self.write(config.services,  to: Paths.services(project)) }
        if config.scripts   != previous.scripts   { Self.write(config.scripts,   to: Paths.scripts(project)) }
        if config.terminals != previous.terminals { Self.write(config.terminals, to: Paths.terminals(project)) }
        if config.schedules != previous.schedules { Self.write(config.schedules, to: Paths.schedules(project)) }
        if config.sessions  != previous.sessions  { Self.write(config.sessions,  to: Paths.sessions(project)) }
        if config.settings  != previous.settings  { Self.write(config.settings,  to: Paths.settings(project)) }
        ensureGitIgnore()
    }

    /// `.cs/.gitignore` — keep run output and machine-specific state out of
    /// version control while services and schedules stay in.
    private func ensureGitIgnore() {
        let url = Paths.csDir(project).appendingPathComponent(".gitignore")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let body = """
        # Claude Studio — machine-specific files are not versioned.
        runs/
        sessions.json
        settings.json
        *.log
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}
