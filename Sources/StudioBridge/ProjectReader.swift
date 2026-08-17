import Foundation

/// Reads everything the bridge can tell another project about a Claude project:
/// what it can do (skills, commands, scripts, services) and what it is doing right
/// now (tmux sessions, terminals, services, their output).
///
/// This duplicates a trimmed copy of the app's file formats on purpose. The app target
/// pulls in SwiftUI (its models carry `Color`), and sharing would mean extracting a
/// library and touching every file for the sake of ~150 lines. The formats it reads —
/// `.cs/*.json`, `.claude/skills`, `.claude/commands` — are documented in the app's
/// README and CLAUDE.md; if they change, this file changes with them.
struct ProjectReader {
    let path: String

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The same identifier the app derives, so tmux sessions can be matched.
    ///
    /// CRITICAL: must stay byte-identical to `Project.shortID` in the app — FNV-1a of
    /// the absolute path, plus a slug of the folder name. A different hash here would
    /// silently find no sessions at all.
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

    var claudeMarkdown: String? {
        let file = url.appendingPathComponent("CLAUDE.md")
        return FileManager.default.fileExists(atPath: file.path) ? file.path : nil
    }

    // MARK: - Capabilities

    struct Capability {
        let name: String
        let description: String?
        let argumentHint: String?
        let file: String
        let scope: String

        var json: [String: Any] {
            var out: [String: Any] = ["name": name, "file": file, "scope": scope]
            if let description { out["description"] = description }
            if let argumentHint { out["argument_hint"] = argumentHint }
            return out
        }
    }

    /// Skills: `.claude/skills/<name>/SKILL.md` or `.claude/skills/<name>.md`.
    func skills() -> [Capability] {
        let root = url.appendingPathComponent(".claude/skills", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var found: [Capability] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory {
                let file = entry.appendingPathComponent("SKILL.md")
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                found.append(capability(at: file, name: entry.lastPathComponent))
            } else if entry.pathExtension.lowercased() == "md",
                      entry.deletingPathExtension().lastPathComponent.lowercased() != "readme" {
                found.append(capability(at: entry,
                                        name: entry.deletingPathExtension().lastPathComponent))
            }
        }
        return found.sorted { $0.name < $1.name }
    }

    /// Slash commands: `.claude/commands/<name>.md`, one level of namespacing.
    func commands() -> [Capability] {
        let root = url.appendingPathComponent(".claude/commands", isDirectory: true)
        return commands(in: root, namespace: nil).sorted { $0.name < $1.name }
    }

    private func commands(in root: URL, namespace: String?) -> [Capability] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var found: [Capability] = []
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory {
                found += commands(in: entry, namespace: entry.lastPathComponent)
            } else if entry.pathExtension.lowercased() == "md" {
                let bare = entry.deletingPathExtension().lastPathComponent
                let full = namespace.map { "\($0):\(bare)" } ?? bare
                found.append(capability(at: entry, name: full))
            }
        }
        return found
    }

    private func capability(at file: URL, name: String) -> Capability {
        let head = (try? String(contentsOf: file, encoding: .utf8))?.prefix(8 * 1024) ?? ""
        let (fields, body) = Frontmatter.split(String(head))
        var description = fields?["description"]
        if description == nil {
            description = body.components(separatedBy: .newlines).first {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return !line.isEmpty && !line.hasPrefix("#")
            }?.trimmingCharacters(in: .whitespaces)
        }
        return Capability(name: name, description: description,
                          argumentHint: fields?["argument-hint"],
                          file: file.path, scope: "project")
    }

    // MARK: - `.cs` definitions

    private func csArray(_ file: String) -> [[String: Any]] {
        let url = self.url.appendingPathComponent(".cs/\(file)")
        guard let data = try? Data(contentsOf: url),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        return array
    }

    func services() -> [[String: Any]] {
        csArray("services.json").map { entry in
            var out: [String: Any] = ["name": entry.string("name") ?? "",
                                      "command": entry.string("command") ?? ""]
            let cwd = entry.string("cwd") ?? ""
            out["cwd"] = cwd.isEmpty ? path : cwd
            if let port = entry.int("port") { out["port"] = port }
            if let auto = entry["autoStart"] as? Bool { out["auto_start"] = auto }
            return out
        }
    }

    func scripts() -> [[String: Any]] {
        csArray("scripts.json").map { entry in
            ["name": entry.string("name") ?? "", "command": entry.string("command") ?? ""]
        }
    }

    func terminals() -> [[String: Any]] {
        csArray("terminals.json").map { entry in
            ["name": entry.string("name") ?? ""]
        }
    }

    // MARK: - Runtime (tmux)

    struct Pane {
        let session: String
        let title: String
        let kind: String        // "session" | "terminal" | "service"
        let dead: Bool
        let exitCode: Int?
        let cwd: String
        let pid: Int?
    }

    /// Live panes belonging to this project, from the app's tmux server.
    func panes() -> [Pane] {
        let format = [
            "#{session_name}", "#{@cs_title}", "#{@cs_kind}",
            "#{pane_dead}", "#{pane_dead_status}", "#{pane_current_path}", "#{pane_pid}",
        ].joined(separator: "\t")

        let output = Tmux.run(["list-panes", "-a",
                               "-f", "#{==:#{@cs_project},\(shortID)}",
                               "-F", format])
        return output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 7, !fields[0].isEmpty else { return nil }
            let session = fields[0]
            // The name encodes the kind for sessions started by older builds that did
            // not tag `@cs_kind`.
            let kind = fields[2].isEmpty
                ? (session.contains("-sv-") ? "service"
                   : session.contains("-sh-") ? "terminal" : "session")
                : fields[2]
            let dead = fields[3] != "0"
            return Pane(session: session,
                        title: fields[1].isEmpty ? session : fields[1],
                        kind: kind == "shell" ? "terminal" : kind,
                        dead: dead,
                        exitCode: dead ? Int(fields[4]) : nil,
                        cwd: fields[5],
                        pid: Int(fields[6]))
        }
    }

    /// Ports a pane's process tree is listening on — tmux knows the pid, `lsof` the rest.
    func listeningPorts(pid: Int) -> [Int] {
        let output = Shell.capture("/usr/sbin/lsof",
                                   ["-nP", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN"])
        var ports: Set<Int> = []
        for line in output.components(separatedBy: .newlines) {
            guard let range = line.range(of: ":", options: .backwards) else { continue }
            let tail = line[range.upperBound...].prefix { $0.isNumber }
            if let port = Int(tail) { ports.insert(port) }
        }
        return ports.sorted()
    }

    // MARK: - Files

    /// Reads a file inside the project. The path is resolved and checked so a link can
    /// never be used to walk out of the project it points at.
    func readFile(_ relative: String, from: Int?, lines: Int?) throws -> String {
        let target = relative.hasPrefix("/")
            ? URL(fileURLWithPath: relative)
            : url.appendingPathComponent(relative)
        let resolved = target.standardizedFileURL.resolvingSymlinksInPath().path
        let root = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved == root || resolved.hasPrefix(root + "/") else {
            throw MCPServer.ToolError("Refused: \(relative) is outside \(name).")
        }
        guard let text = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            throw MCPServer.ToolError("Could not read \(resolved) as text.")
        }
        guard from != nil || lines != nil else { return text }

        let all = text.components(separatedBy: .newlines)
        let start = max(0, (from ?? 1) - 1)
        guard start < all.count else { return "" }
        let end = min(all.count, start + (lines ?? 200))
        return all[start..<end].enumerated()
            .map { "\(start + $0.offset + 1)\t\($0.element)" }
            .joined(separator: "\n")
    }

    func search(_ pattern: String, limit: Int) -> String {
        let output = Shell.capture("/usr/bin/grep",
                                   ["-rn", "--binary-files=without-match",
                                    "--exclude-dir=.git", "--exclude-dir=node_modules",
                                    "--exclude-dir=vendor", "--exclude-dir=.build",
                                    pattern, "."],
                                   cwd: path)
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if lines.count > limit {
            return (lines.prefix(limit) + ["… \(lines.count - limit) more matches"])
                .joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Frontmatter (trimmed copy of the app's reader)

enum Frontmatter {
    static func split(_ text: String) -> (fields: [String: String]?, body: String) {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return (nil, text) }

        var fields: [String: String] = [:]
        for raw in lines[1..<end] {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { fields[key] = value }
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }
}

// MARK: - Process helpers

enum Shell {
    @discardableResult
    static func capture(_ launchPath: String, _ args: [String], cwd: String? = nil) -> String {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum Tmux {
    /// The app's fixed socket. Same reasoning as the app: a fixed `-S` path is the
    /// only handle every process agrees on.
    static let socket = "/tmp/claude-studio-\(getuid()).sock"

    static let path: String? = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
                                "/opt/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func run(_ args: [String]) -> String {
        guard let path else { return "" }
        return Shell.capture(path, ["-S", socket] + args)
    }

    /// The last `lines` lines of a pane, history included, wrapped lines joined.
    static func capture(_ session: String, lines: Int) -> String {
        run(["capture-pane", "-p", "-J", "-S", "-\(max(1, lines))", "-t", session])
    }
}
