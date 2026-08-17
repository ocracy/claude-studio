import Foundation

/// Claude Code transcripts: `~/.claude/projects/<encoded path>/<sid>.jsonl`.
///
/// Checked BEFORE reopening a closed session with `claude --resume <sid>`. If the
/// transcript is not actually on disk, Claude prints "No session found" and exits
/// immediately, leaving the user staring at a dead terminal.
enum ClaudeTranscripts {

    private static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects", isDirectory: true)

    /// Path encoding: `/Users/ann/dev/app` → `-Users-ann-dev-app`.
    /// For paths containing dots the exact scheme is uncertain, so both
    /// candidates are probed — checking two paths is cheaper than silently
    /// losing a resumable conversation to a wrong guess.
    static func directories(for projectPath: String) -> [URL] {
        let slashOnly = projectPath.replacingOccurrences(of: "/", with: "-")
        let slashAndDot = slashOnly.replacingOccurrences(of: ".", with: "-")
        return Set([slashOnly, slashAndDot]).map {
            root.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// One conversation on disk, as Claude Code itself would resume it.
    struct Transcript: Identifiable, Hashable {
        /// Claude's `session_id` — the file name without `.jsonl`.
        var id: String
        var url: URL
        var modified: Date
        /// First line of the opening user message (or Claude's own summary).
        var title: String
    }

    /// Every conversation Claude Code has recorded for this project, newest first.
    ///
    /// This is the raw truth on disk: it includes conversations started outside
    /// Claude Studio, which have no `SessionRecord`.
    static func list(projectPath: String, limit: Int = 60) -> [Transcript] {
        let fm = FileManager.default
        var found: [String: Transcript] = [:]
        for directory in directories(for: projectPath) {
            let files = (try? fm.contentsOfDirectory(at: directory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey,
                                                                                  .fileSizeKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                // Empty file = no messages written; `--resume` would fail on it.
                guard (values?.fileSize ?? 0) > 0 else { continue }
                let sid = file.deletingPathExtension().lastPathComponent
                let modified = values?.contentModificationDate ?? .distantPast
                if let existing = found[sid], existing.modified >= modified { continue }
                found[sid] = Transcript(id: sid, url: file, modified: modified, title: "")
            }
        }
        return found.values
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { var t = $0; t.title = title(of: t.url) ?? "conversation"; return t }
    }

    /// Reads only the head of the file: the summary and the opening user message
    /// are both at the top, and a long conversation is megabytes we do not want.
    private static func title(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
        guard let text = String(data: head, encoding: .utf8) else { return nil }

        var firstUserText: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let summary = object["summary"] as? String, let clean = clean(summary) { return clean }
            guard firstUserText == nil,
                  object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any],
                  object["isMeta"] as? Bool != true
            else { continue }
            if let content = message["content"] as? String {
                firstUserText = clean(content)
            } else if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "text" {
                    if let value = block["text"] as? String, let clean = clean(value) {
                        firstUserText = clean
                        break
                    }
                }
            }
        }
        return firstUserText
    }

    /// A prompt is often multi-line and pasted; one tidy line is what fits a row.
    private static func clean(_ raw: String) -> String? {
        // Command expansions arrive wrapped in XML the user never typed.
        var text = raw
        if let range = text.range(of: "<command-name>"),
           let end = text.range(of: "</command-name>") {
            text = String(text[range.upperBound..<end.lowerBound])
        }
        let line = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("<") else { return nil }
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
    }

    /// Is there a resumable conversation for this project?
    static func exists(projectPath: String, sessionID: String) -> Bool {
        guard !sessionID.isEmpty else { return false }
        for directory in directories(for: projectPath) {
            let file = directory.appendingPathComponent("\(sessionID).jsonl")
            let size = (try? FileManager.default
                .attributesOfItem(atPath: file.path))?[.size] as? NSNumber
            // Empty file = no messages written; resume would still fail.
            if let size, size.intValue > 0 { return true }
        }
        return false
    }
}
