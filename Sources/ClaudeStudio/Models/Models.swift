import Foundation
import SwiftUI

// MARK: - Proje

/// Açık bir çalışma alanı. Kimlik diskteki yoldur; `.cs/` klasörü bu yolun
/// altında yaşar, böylece ayarlar projeyle birlikte taşınır/versiyonlanır.
struct Project: Identifiable, Hashable, Codable {
    var path: String
    var name: String
    var lastOpened: Date

    var id: String { path }

    init(path: String, name: String? = nil, lastOpened: Date = Date()) {
        let expanded = (path as NSString).expandingTildeInPath
        self.path = expanded
        self.name = name ?? URL(fileURLWithPath: expanded).lastPathComponent
        self.lastOpened = lastOpened
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// `~` ile kısaltılmış görüntüleme yolu.
    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// tmux oturum adları ve launchd etiketleri için kısa kimlik.
    ///
    /// KRİTİK: `hashValue` KULLANILMAZ — Swift onu süreç başına rastgele
    /// tohumlar, yani uygulama her açılışta farklı bir kimlik üretir ve dünkü
    /// oturumlar ile launchd job'ları öksüz kalırdı. FNV-1a deterministiktir.
    var shortID: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .prefix(16)
        return "\(String(slug))-\(String(hash, radix: 36).prefix(6))"
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

// MARK: - Sekmeler

/// Ana alandaki bir sekme. Kimlik kalıcıdır: terminal görünümü önbelleği ve
/// tmux oturumu bu kimliğe bağlıdır.
struct StudioTab: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case session, terminal, service, skill, cron }

    var id: String
    var kind: Kind
    var title: String
    /// Kaynağın kimliği: oturum adı, servis id'si, skill adı…
    var ref: String

    init(kind: Kind, ref: String, title: String, id: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.title = title
        self.id = id ?? "\(kind.rawValue):\(ref)"
    }

    /// Terminal görünümü önbelleğinin anahtarı.
    var terminalKey: String { id }
}

// MARK: - Claude oturumu

/// Bir Claude Code oturumunun kalıcı kaydı — `.cs/config.json`'da durur.
///
/// tmux oturumu ölse bile kayıt kalır: kullanıcı aynı isimle geri açtığında
/// `claude --resume` ile konuşma kaldığı yerden sürer.
struct SessionRecord: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    /// tmux oturum adı. Kimlikten türer; yeniden adlandırma bunu değiştirmez.
    var tmux: String
    /// Claude'un kendi oturum kimliği (`claude --resume` için).
    var claudeSID: String?
    var lastUsed: Date = Date()

    /// Sekme ve hook kimliği (`CS_TAB_ID`).
    var tabKey: String { "session:\(tmux)" }

    static func make(projectShortID: String, name: String) -> SessionRecord {
        let id = UUID()
        return SessionRecord(id: id, name: name,
                             tmux: "cs-\(projectShortID)-\(id.uuidString.prefix(8).lowercased())")
    }
}

/// Claude'un anlık durumu — hook köprüsünden gelir.
enum Attention: String, Codable {
    case idle, working, waiting

    var label: String {
        switch self {
        case .working: return "çalışıyor"
        case .waiting: return "bekliyor"
        case .idle:    return "hazır"
        }
    }
}

// MARK: - Skill

/// Projedeki (ya da global) bir Claude Code skill'i.
struct Skill: Identifiable, Hashable {
    var name: String
    var description: String?
    var url: URL
    var scope: Scope

    var id: String { "\(scope.rawValue):\(name)" }

    enum Scope: String { case project, global
        var label: String { self == .project ? "proje" : "genel" }
    }
}

// MARK: - Zamanlama

/// Bir skill'in zamanlanmış çalışması. `.cs/config.json` içinde saklanır.
struct Schedule: Identifiable, Hashable, Codable {
    enum Frequency: String, Codable, CaseIterable {
        case hourly, daily, weekly
        var label: String {
            switch self {
            case .hourly: return "saatlik"
            case .daily:  return "günlük"
            case .weekly: return "haftalık"
            }
        }
    }

    var id: UUID = UUID()
    var skill: String
    var frequency: Frequency = .daily
    var hour: Int = 9
    var minute: Int = 0
    var weekday: Int = 1          // 0 = Pazar (launchd sözleşmesi)
    var enabled: Bool = true
    /// Skill'e verilecek ek yönerge (boşsa skill'in kendi tanımı yeter).
    var prompt: String = ""

    /// "her gün 09:00" gibi insan okunur özet.
    var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch frequency {
        case .hourly: return "her saat :\(String(format: "%02d", minute))"
        case .daily:  return "her gün \(time)"
        case .weekly: return "\(Self.weekdayNames[weekday % 7]) \(time)"
        }
    }

    static let weekdayNames = ["paz", "pzt", "sal", "çar", "per", "cum", "cmt"]

    /// Bir sonraki tetikleme zamanı (durum çubuğu ve liste için).
    var nextFire: Date? {
        guard enabled else { return nil }
        var comps = DateComponents()
        comps.minute = minute
        if frequency != .hourly { comps.hour = hour }
        if frequency == .weekly { comps.weekday = weekday + 1 }  // Calendar: 1 = Pazar
        return Calendar.current.nextDate(after: Date(), matching: comps,
                                         matchingPolicy: .nextTime)
    }
}

// MARK: - Servis

/// Uzun süre çalışan bir geliştirme süreci (`npm run dev`, `php artisan serve`…).
struct Service: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var command: String
    /// Boşsa proje kökü.
    var cwd: String = ""
    var port: Int?
    var autoStart: Bool = false

    func resolvedCwd(projectPath: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return projectPath }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: projectPath).appendingPathComponent(trimmed).path
    }
}

enum ServiceStatus: String, Codable {
    case stopped, starting, running, stopping, crashed, external

    var label: String {
        switch self {
        case .stopped:  return "durdu"
        case .starting: return "başlıyor"
        case .running:  return "çalışıyor"
        case .stopping: return "durduruluyor"
        case .crashed:  return "hata"
        case .external: return "dışarıdan"
        }
    }

    var color: Color {
        switch self {
        case .running:             return Theme.running
        case .starting, .stopping: return Theme.warning
        case .crashed:             return Theme.danger
        case .external:            return Theme.warning
        case .stopped:             return Theme.idle
        }
    }

    var isLive: Bool { self == .running || self == .starting || self == .external }
}

// MARK: - Elle açılan terminal

struct TerminalTab: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var cwd: String = ""

    func resolvedCwd(projectPath: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return projectPath }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: projectPath).appendingPathComponent(trimmed).path
    }
}

// MARK: - Çalışma kaydı

/// Zamanlanmış (ya da elle tetiklenmiş) bir skill çalışmasının çıktısı.
/// Kaynak: `.cs/runs/<skill>/<zaman>.md` — dosyanın kendisi state'tir.
struct SkillRun: Identifiable, Hashable {
    var url: URL
    var startedAt: Date?
    var status: Status = .unknown
    var summary: String?
    var durationSec: Double?
    var body: String = ""
    var trigger: String?

    var id: String { url.path }
    var fileStem: String { url.deletingPathExtension().lastPathComponent }

    enum Status: String {
        case ok, warning, failed, unknown

        init(raw: String?) {
            switch raw?.lowercased() {
            case "ok", "success", "passed", "clean": self = .ok
            case "warn", "warning", "degraded":      self = .warning
            case "fail", "failed", "error":          self = .failed
            default:                                  self = .unknown
            }
        }

        var label: String {
            switch self {
            case .ok:      return "tamam"
            case .warning: return "uyarı"
            case .failed:  return "hata"
            case .unknown: return "—"
            }
        }

        var color: Color {
            switch self {
            case .ok:      return Theme.running
            case .warning: return Theme.warning
            case .failed:  return Theme.danger
            case .unknown: return Theme.idle
            }
        }
    }
}

/// Runner script'inin yazdığı anlık durum (`.cs/runs/<skill>/.state.json`).
struct RunState: Codable {
    var startedAt: Date?
    var finishedAt: Date?
    var exitCode: Int?
    var reportFile: String?

    var isRunning: Bool { startedAt != nil && finishedAt == nil }
}

// MARK: - Küçük yardımcılar

extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension Date {
    /// "2 sa önce" — liste altyazılarında.
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }

    var shortStamp: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "tr_TR")
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: self)
    }
}
