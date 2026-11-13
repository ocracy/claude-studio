import Foundation

struct SessionDetails: Equatable {

    enum Mode: String {
        case standard, acceptEdits, plan, auto, bypass

        var label: String {
            switch self {
            case .standard:    return "Default"
            case .acceptEdits: return "Accept edits"
            case .plan:        return "Plan"
            case .auto:        return "Auto"
            case .bypass:      return "Bypass"
            }
        }
    }

    struct Todo: Equatable, Identifiable {
        enum Status: String { case pending, inProgress = "in_progress", completed }
        var id: Int
        var content: String
        var status: Status
    }

    var model: String?
    var modelID: String?
    var contextTokens: Int?
    var mode: Mode?
    var todos: [Todo]?
    var plan: String?
    var transcriptStamp: String?

    var contextLimit: Int {
        let id = modelID ?? ""
        if id.contains("[1m]") || (contextTokens ?? 0) > 200_000 { return 1_000_000 }
        return id.contains("haiku") ? 200_000 : 1_000_000
    }

    var contextFraction: Double? {
        guard let tokens = contextTokens, tokens > 0 else { return nil }
        return min(1, Double(tokens) / Double(contextLimit))
    }

    var contextLabel: String? {
        guard let tokens = contextTokens, tokens > 0, let fraction = contextFraction else { return nil }
        let amount = tokens >= 1_000_000 ? String(format: "%.1fM", Double(tokens) / 1_000_000)
            : tokens >= 1_000 ? "\(tokens / 1_000)k" : "\(tokens)"
        return "\(Int((fraction * 100).rounded()))% · \(amount)"
    }

    var todoProgress: String? {
        guard let todos, !todos.isEmpty else { return nil }
        return "\(todos.filter { $0.status == .completed }.count)/\(todos.count)"
    }

    static func read(projectPath: String, sessionID: String?, tmux: String?,
                     previous: SessionDetails?) -> SessionDetails {
        var details = SessionDetails()
        if let sessionID, !sessionID.isEmpty,
           let url = transcriptURL(projectPath: projectPath, sessionID: sessionID) {
            let stamp = self.stamp(of: url)
            if let previous, stamp != nil, previous.transcriptStamp == stamp {
                details = previous
                details.mode = nil
            } else {
                transcriptTail(url, into: &details)
                details.transcriptStamp = stamp
            }
        }
        if let tmux, let lines = Tmux.capturePanes([tmux])[tmux] {
            details.mode = mode(in: lines, previous: previous?.mode)
        }
        return details
    }

    static func mode(in lines: [String], previous: Mode?) -> Mode? {
        for line in lines.suffix(8).reversed() {
            let lower = line.lowercased()
            if lower.contains("plan mode on") { return .plan }
            if lower.contains("accept edits on") { return .acceptEdits }
            if lower.contains("bypass permissions on") { return .bypass }
            if lower.contains("auto mode on") { return .auto }
        }
        if PaneReader.read(lines).isAsking { return previous }
        return .standard
    }

    static func displayName(ofModel id: String) -> String {
        var name = id.hasPrefix("claude-") ? String(id.dropFirst("claude-".count)) : id
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        var parts = name.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first, family.first?.isLetter == true else { return id }
        let version = parts.dropFirst().filter { Int($0) != nil }.joined(separator: ".")
        let title = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? title : "\(title) \(version)"
    }

    private static func transcriptURL(projectPath: String, sessionID: String) -> URL? {
        ClaudeTranscripts.directories(for: projectPath)
            .map { $0.appendingPathComponent("\(sessionID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func stamp(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        return "\(size)-\(modified.timeIntervalSince1970)"
    }

    private static func transcriptTail(_ url: URL, into details: inout SessionDetails) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 2 * 1024 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return }
        parseTail(String(decoding: data, as: UTF8.self), into: &details)
    }

    static func parseTail(_ text: String, into details: inout SessionDetails) {
        var foundUsage = false
        var foundTasks = false
        for line in text.split(separator: "\n").reversed() {
            if foundUsage && foundTasks { break }
            let usageLine = !foundUsage && line.contains("\"usage\"")
            let taskLine = !foundTasks
                && (line.contains("\"name\":\"TodoWrite\"") || line.contains("\"name\":\"ExitPlanMode\""))
            guard usageLine || taskLine,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any]
            else { continue }

            if usageLine, let model = message["model"] as? String, !model.hasPrefix("<"),
               let usage = message["usage"] as? [String: Any] {
                details.modelID = model
                details.model = displayName(ofModel: model)
                details.contextTokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
                foundUsage = true
            }
            if taskLine, let content = message["content"] as? [[String: Any]] {
                for item in content.reversed() where item["type"] as? String == "tool_use" {
                    let input = item["input"] as? [String: Any]
                    if item["name"] as? String == "TodoWrite",
                       let todos = input?["todos"] as? [[String: Any]] {
                        details.todos = todos.enumerated().compactMap { index, todo in
                            guard let text = todo["content"] as? String else { return nil }
                            let status = Todo.Status(rawValue: todo["status"] as? String ?? "") ?? .pending
                            return Todo(id: index, content: text, status: status)
                        }
                        foundTasks = true
                        break
                    }
                    if item["name"] as? String == "ExitPlanMode",
                       let plan = (input?["plan"] as? String)?.nilIfEmpty {
                        details.plan = plan
                        foundTasks = true
                        break
                    }
                }
            }
        }
    }
}
