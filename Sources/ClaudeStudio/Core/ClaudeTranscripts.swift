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
