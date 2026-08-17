import Foundation
import SwiftUI

// MARK: - Project

/// An open workspace. Its identity is the path on disk; the `.cs/` folder lives
/// underneath it, so settings travel and version with the project.
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

    /// Display path shortened with `~`.
    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Short identifier used for tmux session names and launchd labels.
    ///
    /// CRITICAL: never use `hashValue` — Swift seeds it randomly per process, so
    /// every launch would produce a different identifier and yesterday's sessions
    /// and launchd jobs would be orphaned. FNV-1a is deterministic.
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

// MARK: - Tabs

/// A tab in the main area. Its id is stable: the terminal view cache and the
/// tmux session are both keyed on it.
struct StudioTab: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case session, terminal, service, script, command, skill, cron }

    var id: String
    var kind: Kind
    var title: String
    /// Identifier of the underlying resource: session name, service id, skill name…
    var ref: String

    init(kind: Kind, ref: String, title: String, id: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.title = title
        self.id = id ?? "\(kind.rawValue):\(ref)"
    }

    /// Key into the terminal view cache.
    var terminalKey: String { id }
}

// MARK: - Claude session

/// The durable record of a Claude Code session, stored in `.cs/sessions.json`.
///
/// The record outlives the tmux session: reopening it by the same name resumes
/// the conversation via `claude --resume`.
struct SessionRecord: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    /// tmux session name, derived from the id; renaming does not change it.
    var tmux: String
    /// Claude's own session id (for `claude --resume`).
    var claudeSID: String?
    var lastUsed: Date = Date()

    /// Tab and hook identifier (`CS_TAB_ID`).
    var tabKey: String { "session:\(tmux)" }

    static func make(projectShortID: String, name: String) -> SessionRecord {
        let id = UUID()
        return SessionRecord(id: id, name: name,
                             tmux: "cs-\(projectShortID)-\(id.uuidString.prefix(8).lowercased())")
    }
}

/// Claude's live state, reported by the hook bridge.
enum Attention: String, Codable {
    case idle, working, waiting

    var label: String {
        switch self {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle:    return "ready"
        }
    }
}

// MARK: - Skill

/// A Claude Code skill, in the project or global.
struct Skill: Identifiable, Hashable {
    var name: String
    var description: String?
    var url: URL
    var scope: Scope

    var id: String { "\(scope.rawValue):\(name)" }

    enum Scope: String { case project, global
        var label: String { self == .project ? "project" : "global" }
    }
}

// MARK: - Claude command

/// A Claude Code slash command, read from Claude's own layout:
///
///   .claude/commands/<name>.md          → /name
///   .claude/commands/<dir>/<name>.md    → /dir:name
///
/// Project commands shadow global ones of the same name, matching Claude.
struct ClaudeCommand: Identifiable, Hashable {
    var name: String
    var description: String?
    var argumentHint: String?
    var url: URL
    var scope: Skill.Scope

    var id: String { "\(scope.rawValue):\(name)" }

    /// How Claude is invoked: `/name` — with the hint when the command takes one.
    var invocation: String { "/\(name)" }
}

// MARK: - Schedule

/// A scheduled run of a skill, stored in `.cs/schedules.json`.
struct Schedule: Identifiable, Hashable, Codable {
    enum Frequency: String, Codable, CaseIterable {
        case hourly, daily, weekly
        var label: String {
            switch self {
            case .hourly: return "hourly"
            case .daily:  return "daily"
            case .weekly: return "weekly"
            }
        }
    }

    var id: UUID = UUID()
    var skill: String
    var frequency: Frequency = .daily
    var hour: Int = 9
    var minute: Int = 0
    var weekday: Int = 1          // 0 = Sunday (launchd convention)
    var enabled: Bool = true
    /// Extra instruction for the skill (empty means the skill's own definition suffices).
    var prompt: String = ""

    /// Human-readable summary such as "daily 09:00".
    var summary: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch frequency {
        case .hourly: return "hourly at :\(String(format: "%02d", minute))"
        case .daily:  return "daily \(time)"
        case .weekly: return "\(Self.weekdayNames[weekday % 7]) \(time)"
        }
    }

    static let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    /// Next fire date (used by the status bar and the list).
    var nextFire: Date? {
        guard enabled else { return nil }
        var comps = DateComponents()
        comps.minute = minute
        if frequency != .hourly { comps.hour = hour }
        if frequency == .weekly { comps.weekday = weekday + 1 }  // Calendar: 1 = Sunday
        return Calendar.current.nextDate(after: Date(), matching: comps,
                                         matchingPolicy: .nextTime)
    }
}

// MARK: - Service

/// A long-running development process (`npm run dev`, `php artisan serve`…).
struct Service: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var command: String
    /// Empty means the project root.
    var cwd: String = ""
    var port: Int?
    var autoStart: Bool = false

    init(id: UUID = UUID(), name: String, command: String,
         cwd: String = "", port: Int? = nil, autoStart: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
        self.port = port
        self.autoStart = autoStart
    }

    /// Written by hand because `services.json` is edited by hand — and by Claude.
    /// The synthesized decoder throws on a missing key even where there is a
    /// default, so one entry without an `id` would take the whole service list
    /// down with it. Only `name` and `command` are actually required.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        name = value(.name, "")
        command = value(.command, "")
        cwd = value(.cwd, "")
        port = (try? box.decodeIfPresent(Int.self, forKey: .port)) ?? nil
        autoStart = value(.autoStart, false)
    }

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
        case .stopped:  return "stopped"
        case .starting: return "starting"
        case .running:  return "running"
        case .stopping: return "stopping"
        case .crashed:  return "crashed"
        case .external: return "external"
        }
    }

    var color: Color {
        switch self {
        case .running:             return Theme.running
        case .starting, .stopping: return Theme.warning
        case .crashed:             return Theme.danger
        // Something is already answering on the port: the service IS up, the app
        // just did not start it. The light says up; the label says who started it.
        case .external:            return Theme.running
        case .stopped:             return Theme.idle
        }
    }

    var isLive: Bool { self == .running || self == .starting || self == .external }
}

// MARK: - Project script

/// A one-shot shell command bound to the project (`npm run build`,
/// `php artisan optimize`). Unlike a service it owns no port and never auto-starts:
/// pressing it runs the command in its own tab and shows the exit code in place.
///
/// Named "script" to keep it apart from a **Claude command**, which is a slash
/// command in `.claude/commands` — a different thing entirely.
struct ProjectScript: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var command: String
    /// Empty means the project root.
    var cwd: String = ""

    init(id: UUID = UUID(), name: String, command: String, cwd: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.cwd = cwd
    }

    /// Tolerant for the same reason as `Service`: `scripts.json` is edited by
    /// hand and by Claude, and a missing `id` must not cost the whole list.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id = value(.id, UUID())
        name = value(.name, "")
        command = value(.command, "")
        cwd = value(.cwd, "")
    }

    func resolvedCwd(projectPath: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return projectPath }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return (trimmed as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: projectPath).appendingPathComponent(trimmed).path
    }
}

// MARK: - Manually opened terminal

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

// MARK: - Run record

/// The output of a scheduled (or manually triggered) skill run.
/// Source: `.cs/runs/<skill>/<timestamp>.md` — the file itself is the state.
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
            case .ok:      return "ok"
            case .warning: return "warning"
            case .failed:  return "failed"
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

/// Live state written by the runner script (`.cs/runs/<skill>/.state.json`).
struct RunState: Codable {
    var startedAt: Date?
    var finishedAt: Date?
    var exitCode: Int?
    var reportFile: String?

    var isRunning: Bool { startedAt != nil && finishedAt == nil }
}

// MARK: - Small helpers

extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

extension Date {
    /// "2h ago" — used in list subtitles.
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }

    var shortStamp: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: self)
    }
}
