import Foundation

enum GitChanges {

    struct Summary: Equatable {
        var files: Int
        var added: Int
        var removed: Int
    }

    struct FileChange: Identifiable, Equatable {
        var path: String
        var added: Int
        var removed: Int
        var untracked: Bool
        var patch: [String]

        var id: String { path }
    }

    struct Line: Equatable {
        var text: String
        var old: Int?
        var new: Int?
        var commentable: Bool
    }

    static func numbered(_ patch: [String], untracked: Bool) -> [Line] {
        if untracked {
            return patch.enumerated().map { index, text in
                let content = text.hasPrefix("+")
                return Line(text: text, old: nil, new: content ? index + 1 : nil, commentable: content)
            }
        }
        var old = 0, new = 0
        var out: [Line] = []
        for text in patch {
            if text.hasPrefix("@@") {
                let parts = text.split(separator: " ")
                if parts.count > 2 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                out.append(Line(text: text, old: nil, new: nil, commentable: false))
            } else if text.hasPrefix("+") {
                out.append(Line(text: text, old: nil, new: new, commentable: true))
                new += 1
            } else if text.hasPrefix("-") {
                out.append(Line(text: text, old: old, new: nil, commentable: true))
                old += 1
            } else if text.hasPrefix(" ") {
                out.append(Line(text: text, old: old, new: new, commentable: true))
                old += 1
                new += 1
            } else {
                out.append(Line(text: text, old: nil, new: nil, commentable: false))
            }
        }
        return out
    }

    private static let git: String? = Shell.findExecutable(["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"])
    private static let untrackedLineLimit = 400
    private static let untrackedByteLimit = 2 * 1024 * 1024
    private static let summaryLineCountLimit = 200
    private static let summaryByteLimit = 256 * 1024

    static func summary(at path: String) -> Summary? {
        guard let numstat = run(["diff", "HEAD", "--relative", "--no-renames", "--numstat"], at: path) else { return nil }
        var summary = Summary(files: 0, added: 0, removed: 0)
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            summary.files += 1
            summary.added += Int(fields[0]) ?? 0
            summary.removed += Int(fields[1]) ?? 0
        }
        for (index, file) in untracked(at: path).enumerated() {
            summary.files += 1
            if index < summaryLineCountLimit {
                summary.added += lines(of: file, in: path, byteLimit: summaryByteLimit)?.count ?? 0
            }
        }
        return summary
    }

    static func files(at path: String) -> [FileChange] {
        guard let numstat = run(["diff", "HEAD", "--relative", "--no-renames", "--numstat"], at: path) else { return [] }
        let patch = run(["diff", "HEAD", "--relative", "--no-renames", "--no-color", "--no-ext-diff"], at: path) ?? ""
        let patches = splitPatch(patch)

        var out: [FileChange] = []
        for line in numstat.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 2)
            guard fields.count == 3 else { continue }
            let file = String(fields[2])
            out.append(FileChange(path: file,
                                  added: Int(fields[0]) ?? 0,
                                  removed: Int(fields[1]) ?? 0,
                                  untracked: false,
                                  patch: patches[file] ?? ["Binary file"]))
        }
        for file in untracked(at: path) {
            let content = lines(of: file, in: path)
            var patch = (content ?? ["Binary or large file"]).prefix(untrackedLineLimit).map { "+" + $0 }
            if let content, content.count > untrackedLineLimit {
                patch.append("… \(content.count - untrackedLineLimit) more lines")
            }
            out.append(FileChange(path: file, added: content?.count ?? 0, removed: 0,
                                  untracked: true, patch: patch))
        }
        return out.sorted { $0.path < $1.path }
    }

    private static func untracked(at path: String) -> [String] {
        guard let output = run(["ls-files", "--others", "--exclude-standard"], at: path) else { return [] }
        return output.split(separator: "\n").map(String.init)
    }

    private static func lines(of file: String, in root: String,
                              byteLimit: Int = untrackedByteLimit) -> [String]? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(file)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= byteLimit,
              let data = try? Data(contentsOf: url),
              !data.contains(0),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func splitPatch(_ patch: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: String?
        var body: [String] = []
        func flush() {
            if let current { out[current] = body }
            body = []
        }
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                flush()
                current = line.range(of: " b/").map { String(line[$0.upperBound...]) }
                continue
            }
            if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode") {
                continue
            }
            body.append(line)
        }
        flush()
        return out
    }

    private static func run(_ args: [String], at path: String) -> String? {
        guard let git else { return nil }
        let result = Shell.run(git, ["-C", path] + args, env: ["GIT_OPTIONAL_LOCKS": "0"])
        return result.status == 0 ? result.output : nil
    }
}
