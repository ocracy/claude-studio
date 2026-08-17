import Foundation
import SwiftUI

/// One use of a skill or a slash command by a Claude session.
///
/// Recorded from Claude's own hooks, so it reflects what actually happened rather than
/// what the app asked for: a skill the model chose by itself counts, and so does a
/// command you typed.
struct UsageEvent: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case skill, command }
    enum Source: String, Codable {
        case model, user
        var label: String { self == .user ? "typed" : "chosen by Claude" }
    }

    var at: Date
    var kind: Kind
    var name: String
    var args: String?
    var source: Source
    /// Our tab key (`CS_TAB_ID`) and the session's display name.
    var session: String?
    var sessionName: String?
    var durationMs: Int?
    var projectPath: String?

    var id: String { "\(at.timeIntervalSince1970)-\(name)-\(session ?? "")" }

    var duration: String? {
        guard let durationMs else { return nil }
        return durationMs < 1000 ? "\(durationMs)ms"
            : String(format: "%.1fs", Double(durationMs) / 1000)
    }

    /// How the command or skill is written when talking about it.
    var display: String { kind == .command ? "/\(name)" : name }
}

/// Turns spooled hook events into usage records, and keeps track of what is running
/// right now.
///
/// App-wide on purpose. Every window has its own `TerminalEngine`, and two of them
/// consuming the same spool would race each other for the files; and a session in one
/// project can use a skill that belongs to another, so the writer cannot be tied to a
/// single project either.
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    /// Tab key → what that session is running at this moment.
    @Published private(set) var live: [String: UsageEvent] = [:]

    private var timer: Timer?
    private let decoder = JSONDecoder()

    private init() {}

    func start() {
        guard timer == nil else { return }
        drain()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in self.drain() }
        }
    }

    /// Reads every spooled event, records it and deletes the file. Sorted by name,
    /// which is `<epoch>-<pid>-<random>` — close enough to arrival order that a start
    /// is never applied after its own finish.
    func drain() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Paths.eventsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }

        let ordered = files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !ordered.isEmpty else { return }

        for file in ordered {
            defer { try? fm.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            apply(event)
        }
    }

    // MARK: - Interpreting an event

    private func apply(_ event: [String: Any]) {
        let hook = event["hook_event_name"] as? String ?? ""
        let tab = event["cs_tab"] as? String
        let projectPath = (event["cs_project_path"] as? String)?.nilIfEmpty
            ?? (event["cwd"] as? String)?.nilIfEmpty
        let at = (event["cs_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()

        switch hook {
        case "UserPromptExpansion":
            // A slash command the user typed. It has no duration: the event fires when
            // the command expands, not when the work it triggers is done.
            guard let name = (event["command_name"] as? String)?.nilIfEmpty else { return }
            let usage = UsageEvent(at: at, kind: .command, name: name,
                                   args: (event["command_args"] as? String)?.nilIfEmpty,
                                   source: .user, session: tab,
                                   sessionName: event["cs_tab_name"] as? String,
                                   durationMs: nil, projectPath: projectPath)
            record(usage)

        case "PreToolUse":
            guard let name = skillName(from: event) else { return }
            guard let tab else { return }
            live[tab] = UsageEvent(at: at, kind: kind(of: name, in: projectPath), name: name,
                                   args: arguments(from: event), source: .model, session: tab,
                                   sessionName: event["cs_tab_name"] as? String,
                                   durationMs: nil, projectPath: projectPath)

        case "PostToolUse":
            guard let name = skillName(from: event) else { return }
            if let tab { live.removeValue(forKey: tab) }
            let usage = UsageEvent(at: at, kind: kind(of: name, in: projectPath), name: name,
                                   args: arguments(from: event), source: .model, session: tab,
                                   sessionName: event["cs_tab_name"] as? String,
                                   durationMs: event["duration_ms"] as? Int,
                                   projectPath: projectPath)
            record(usage)

        default:
            break
        }
    }

    /// `tool_response.commandName` is the name Claude resolved; `tool_input.skill` is
    /// what the model asked for and may carry a leading slash.
    private func skillName(from event: [String: Any]) -> String? {
        guard (event["tool_name"] as? String) == "Skill" else { return nil }
        if let response = event["tool_response"] as? [String: Any],
           let resolved = (response["commandName"] as? String)?.nilIfEmpty {
            return resolved
        }
        guard let input = event["tool_input"] as? [String: Any],
              let asked = (input["skill"] as? String)?.nilIfEmpty else { return nil }
        return asked.hasPrefix("/") ? String(asked.dropFirst()) : asked
    }

    private func arguments(from event: [String: Any]) -> String? {
        guard let input = event["tool_input"] as? [String: Any] else { return nil }
        return (input["args"] as? String)?.nilIfEmpty
    }

    /// Skills and commands share one namespace in Claude, so the file layout decides
    /// which one this was.
    private func kind(of name: String, in projectPath: String?) -> UsageEvent.Kind {
        guard let projectPath else { return .skill }
        let root = URL(fileURLWithPath: projectPath)
        let asCommand = root.appendingPathComponent(
            ".claude/commands/\(name.replacingOccurrences(of: ":", with: "/")).md")
        if FileManager.default.fileExists(atPath: asCommand.path) { return .command }
        let global = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/commands/\(name).md")
        return FileManager.default.fileExists(atPath: global.path) ? .command : .skill
    }

    // MARK: - Writing

    /// Appends to `<project>/.cs/runs/<name>/usage.jsonl`, keeping the tail bounded.
    private func record(_ usage: UsageEvent) {
        guard let projectPath = usage.projectPath else { return }
        let project = Project(path: projectPath)
        let file = Paths.usageFile(project, skill: usage.name)
        Paths.ensure(file.deletingLastPathComponent())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(usage),
              let line = String(data: data, encoding: .utf8) else { return }

        var lines = (try? String(contentsOf: file, encoding: .utf8))?
            .components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
        lines.append(line)
        if lines.count > 300 { lines = Array(lines.suffix(300)) }
        Paths.writeAtomically(Data((lines.joined(separator: "\n") + "\n").utf8), to: file)
    }
}

extension Runs {
    /// Recorded uses of a skill or command, newest first.
    static func usage(project: Project, skill: String) -> [UsageEvent] {
        let file = Paths.usageFile(project, skill: skill)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.components(separatedBy: .newlines)
            .compactMap { line -> UsageEvent? in
                guard let data = line.nilIfEmpty?.data(using: .utf8) else { return nil }
                return try? decoder.decode(UsageEvent.self, from: data)
            }
            .sorted { $0.at > $1.at }
    }
}
