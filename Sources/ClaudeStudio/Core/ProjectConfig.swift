import Foundation
import SwiftUI

/// Projeye ait ayarların bellekteki hâli. Diskte tek dosya değil, `.cs/`
/// altında **her biri kendi dosyasında** durur:
///
/// ```
/// .cs/
/// ├── services.json    servisler
/// ├── terminals.json   terminaller
/// ├── schedules.json   zamanlanmış çalışmalar
/// ├── sessions.json    Claude oturum kayıtları
/// └── settings.json    arayüz tercihleri
/// ```
///
/// Ayrı dosya olmasının sebebi pratik: servis listesini elle düzenlemek ya da
/// ekiple paylaşmak isteyince tek başına duran, okunur bir dosya gerekir;
/// arayüz tercihleri onunla aynı dosyada olsaydı her pencere boyutu değişimi
/// paylaşılan dosyayı kirletirdi.
struct ProjectConfig: Codable, Equatable {
    var sessions: [SessionRecord] = []
    var services: [Service] = []
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

    /// Çözümleme kasten toleranslıdır: eksik anahtar varsayılana düşer.
    /// Swift'in ürettiği çözümleyici eksik anahtarda HATA verir — bu yüzden
    /// elle yazıldı; hem eski tek dosyalı biçim (`sidebarWidth`, `lastView`
    /// düz alanlar) hem yeni biçim aynı koddan okunur ve elle düzenlenmiş,
    /// yarım bir dosya bütün yapılandırmayı düşürmez.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        sessions  = value(.sessions, [])
        services  = value(.services, [])
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
        try box.encode(terminals, forKey: .terminals)
        try box.encode(schedules, forKey: .schedules)
        try box.encode(settings, forKey: .settings)
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, services, terminals, schedules, settings, sidebarWidth, lastView
    }
}

/// `.cs/settings.json` — yalnız bu projeye ait arayüz tercihleri.
struct ProjectSettings: Codable, Equatable {
    var sidebarWidth: Double = 260
    var lastView: String = "sessions"
}

/// Yapılandırmayı yükler, değişen bölümü diske yazar ve launchd job'larını
/// zamanlamalarla eşitler.
@MainActor
final class ProjectStore: ObservableObject {
    let project: Project
    @Published private(set) var config: ProjectConfig

    init(project: Project) {
        self.project = project
        self.config = Self.load(project)
    }

    // MARK: - Sorgular

    func session(tmux: String) -> SessionRecord? { config.sessions.first { $0.tmux == tmux } }
    func service(_ id: UUID) -> Service? { config.services.first { $0.id == id } }
    func terminal(_ id: UUID) -> TerminalTab? { config.terminals.first { $0.id == id } }
    func schedule(for skill: String) -> Schedule? { config.schedules.first { $0.skill == skill } }

    var activeSchedules: [Schedule] { config.schedules.filter(\.enabled) }

    /// Bir sonraki zamanlanmış çalışma (durum çubuğu).
    var nextRun: (skill: String, date: Date)? {
        config.schedules
            .compactMap { s in s.nextFire.map { (s.skill, $0) } }
            .min { $0.1 < $1.1 }
    }

    // MARK: - Mutasyon

    /// Tek yazma yolu. Yalnız gerçekten değişen bölümün dosyası yazılır.
    func mutate(_ change: (inout ProjectConfig) -> Void) {
        let before = config
        var copy = config
        change(&copy)
        guard copy != before else { return }
        config = copy
        save(changed: before)
    }

    // Oturumlar

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

    // Servisler

    func addService(_ service: Service) { mutate { $0.services.append(service) } }

    func updateService(_ service: Service) {
        mutate {
            guard let i = $0.services.firstIndex(where: { $0.id == service.id }) else { return }
            $0.services[i] = service
        }
    }

    func removeService(_ id: UUID) { mutate { $0.services.removeAll { $0.id == id } } }

    // Terminaller

    func addTerminal(_ terminal: TerminalTab) { mutate { $0.terminals.append(terminal) } }

    func renameTerminal(_ id: UUID, to name: String) {
        mutate {
            guard let i = $0.terminals.firstIndex(where: { $0.id == id }) else { return }
            $0.terminals[i].name = name
        }
    }

    func removeTerminal(_ id: UUID) { mutate { $0.terminals.removeAll { $0.id == id } } }

    // Zamanlamalar — JSON ve launchd birlikte güncellenir.

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

    /// Diskten silinmiş becerilerin yetim launchd job'larını temizler.
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
        config.services  = read([Service].self,       from: Paths.services(project))  ?? []
        config.terminals = read([TerminalTab].self,   from: Paths.terminals(project)) ?? []
        config.schedules = read([Schedule].self,      from: Paths.schedules(project)) ?? []
        config.sessions  = read([SessionRecord].self, from: Paths.sessions(project))  ?? []
        config.settings  = read(ProjectSettings.self, from: Paths.settings(project))  ?? ProjectSettings()

        // Tek dosyalı eski biçimden geçiş: bir kez okunur, bölünmüş dosyalara
        // yazılır, eski dosya kaldırılır.
        let legacy = Paths.legacyConfig(project)
        if FileManager.default.fileExists(atPath: legacy.path),
           let old = read(ProjectConfig.self, from: legacy) {
            if config.services.isEmpty  { config.services  = old.services }
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
        write(config.terminals, to: Paths.terminals(project))
        write(config.schedules, to: Paths.schedules(project))
        write(config.sessions,  to: Paths.sessions(project))
        write(config.settings,  to: Paths.settings(project))
    }

    /// Yalnız değişen bölümü yazar — tek bir pencere boyutu değişimi servis
    /// dosyasının tarihini değiştirmesin.
    private func save(changed previous: ProjectConfig) {
        Paths.ensure(Paths.csDir(project))
        if config.services  != previous.services  { Self.write(config.services,  to: Paths.services(project)) }
        if config.terminals != previous.terminals { Self.write(config.terminals, to: Paths.terminals(project)) }
        if config.schedules != previous.schedules { Self.write(config.schedules, to: Paths.schedules(project)) }
        if config.sessions  != previous.sessions  { Self.write(config.sessions,  to: Paths.sessions(project)) }
        if config.settings  != previous.settings  { Self.write(config.settings,  to: Paths.settings(project)) }
        ensureGitIgnore()
    }

    /// `.cs/.gitignore` — çalışma çıktıları ve makineye özel durum dosyaları
    /// versiyonlanmasın; servisler ve zamanlamalar versiyonlansın.
    private func ensureGitIgnore() {
        let url = Paths.csDir(project).appendingPathComponent(".gitignore")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let body = """
        # Claude Studio — makineye özel olanlar versiyonlanmaz.
        runs/
        sessions.json
        settings.json
        *.log
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}
