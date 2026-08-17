import Foundation
import SwiftUI

/// MCP servers, read from Claude Code's own configuration — no separate registry.
///
/// Claude keeps them in three places, and the place decides the scope:
///
/// - **user**    `~/.claude.json` → `mcpServers`                       (every project)
/// - **local**   `~/.claude.json` → `projects[<path>].mcpServers`      (this project, private)
/// - **project** `<project>/.mcp.json` → `mcpServers`                  (this project, shared)
///
/// Listing reads those files directly, so the sidebar fills instantly. Changes go
/// through `claude mcp add|remove`, which keeps Claude's own validation and scope
/// rules in charge instead of us reimplementing them.
struct MCPServer: Identifiable, Hashable {
    enum Scope: String, CaseIterable, Codable {
        case user, project, local

        /// What the file layout means, in the user's words.
        var label: String {
            switch self {
            case .user:    return "global"
            case .project: return "project"
            case .local:   return "local"
            }
        }

        var help: String {
            switch self {
            case .user:    return "Available in every project (~/.claude.json)"
            case .project: return "Shared with the team (.mcp.json in the project)"
            case .local:   return "Only this project, only this machine"
            }
        }
    }

    enum Transport: String, CaseIterable, Codable {
        case stdio, http, sse
    }

    enum Health: String {
        case unknown, connected, needsAuth, failed

        var label: String {
            switch self {
            case .unknown:   return "not checked"
            case .connected: return "connected"
            case .needsAuth: return "needs authentication"
            case .failed:    return "failed"
            }
        }

        var color: Color {
            switch self {
            case .connected: return Theme.running
            case .needsAuth: return Theme.warning
            case .failed:    return Theme.danger
            case .unknown:   return Theme.idle
            }
        }
    }

    var name: String
    var scope: Scope
    var transport: Transport
    /// stdio only.
    var command: String = ""
    var args: [String] = []
    /// http and sse only.
    var url: String = ""
    var env: [String: String] = [:]
    var headers: [String: String] = [:]
    var health: Health = .unknown

    var id: String { "\(scope.rawValue):\(name)" }

    /// One line describing what it actually runs or talks to.
    var detail: String {
        switch transport {
        case .stdio: return ([command] + args).joined(separator: " ")
        case .http, .sse: return url
        }
    }
}

@MainActor
final class MCPStore: ObservableObject {
    @Published private(set) var servers: [MCPServer] = []
    @Published private(set) var checkingHealth = false

    private var project: Project?

    func start(project: Project) {
        self.project = project
        scan()
    }

    /// Reads the three configuration files. Cheap enough to call on every pane
    /// visit, so the list never lies about what Claude will load.
    func scan() {
        guard let project else { return }
        let previous = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0.health) })
        Task.detached(priority: .utility) {
            var found = Self.read(project: project)
            // Keep health from the previous check; rescanning must not blank it.
            for index in found.indices {
                found[index].health = previous[found[index].id] ?? .unknown
            }
            let result = found
            await MainActor.run { self.servers = result }
        }
    }

    /// `claude mcp list` connects to each server, so it is slow and explicit —
    /// never part of a plain scan.
    func checkHealth() {
        guard let project, !checkingHealth else { return }
        checkingHealth = true
        let names = servers.map(\.name)
        Task.detached(priority: .utility) {
            let output = Shell.run("/bin/zsh",
                                   ["-l", "-i", "-c",
                                    "cd \(Shell.quoted(project.path)) && claude mcp list"]).output
            let states = Self.parseHealth(output, names: names)
            await MainActor.run {
                for index in self.servers.indices {
                    if let state = states[self.servers[index].name] {
                        self.servers[index].health = state
                    }
                }
                self.checkingHealth = false
            }
        }
    }

    // MARK: - Mutations (through Claude's own CLI)

    /// Builds and runs `claude mcp add`. Returns the CLI's output so the caller can
    /// show what went wrong.
    func add(_ server: MCPServer, completion: @escaping (Bool, String) -> Void) {
        guard let project else { return }
        var parts = ["claude", "mcp", "add", Shell.quoted(server.name),
                     "--scope", server.scope.rawValue]
        if server.transport != .stdio {
            parts += ["--transport", server.transport.rawValue]
        }
        for (key, value) in server.env.sorted(by: { $0.key < $1.key }) {
            parts += ["-e", Shell.quoted("\(key)=\(value)")]
        }
        for (key, value) in server.headers.sorted(by: { $0.key < $1.key }) {
            parts += ["-H", Shell.quoted("\(key): \(value)")]
        }
        switch server.transport {
        case .stdio:
            // `--` keeps the server's own flags out of claude's parser.
            parts += ["--", server.command] + server.args.map(Shell.quoted)
        case .http, .sse:
            parts.append(Shell.quoted(server.url))
        }

        let command = "cd \(Shell.quoted(project.path)) && " + parts.joined(separator: " ")
        Shell.runAsync("/bin/zsh", ["-l", "-i", "-c", command]) { status, output in
            Task { @MainActor in
                self.scan()
                completion(status == 0, output)
            }
        }
    }

    func remove(_ server: MCPServer) {
        guard let project else { return }
        let command = "cd \(Shell.quoted(project.path)) && claude mcp remove "
            + "\(Shell.quoted(server.name)) -s \(server.scope.rawValue)"
        Shell.runAsync("/bin/zsh", ["-l", "-i", "-c", command]) { _, _ in
            Task { @MainActor in self.scan() }
        }
    }

    // MARK: - Reading

    nonisolated static func read(project: Project) -> [MCPServer] {
        var out: [MCPServer] = []

        let claudeJSON = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude.json")
        if let root = object(at: claudeJSON) {
            out += parse(root["mcpServers"], scope: .user)
            if let projects = root["projects"] as? [String: Any],
               let entry = projects[project.path] as? [String: Any] {
                out += parse(entry["mcpServers"], scope: .local)
            }
        }

        let projectFile = project.url.appendingPathComponent(".mcp.json")
        if let root = object(at: projectFile) {
            out += parse(root["mcpServers"], scope: .project)
        }

        return out.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    nonisolated static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func parse(_ raw: Any?, scope: MCPServer.Scope) -> [MCPServer] {
        guard let dict = raw as? [String: Any] else { return [] }
        return dict.compactMap { name, value in
            guard let entry = value as? [String: Any] else { return nil }
            let url = entry["url"] as? String ?? ""
            let declared = (entry["type"] as? String).flatMap(MCPServer.Transport.init)
            // A missing `type` means stdio when there is a command, http when a url.
            let transport = declared ?? (url.isEmpty ? .stdio : .http)
            return MCPServer(name: name,
                             scope: scope,
                             transport: transport,
                             command: entry["command"] as? String ?? "",
                             args: entry["args"] as? [String] ?? [],
                             url: url,
                             env: entry["env"] as? [String: String] ?? [:],
                             headers: entry["headers"] as? [String: String] ?? [:])
        }
    }

    /// Parses `claude mcp list` output lines like
    /// `name: npx thing - ✔ Connected` / `- ! Needs authentication`.
    ///
    /// The name is matched against the servers we already know rather than guessed
    /// from the punctuation: a plugin server is called `plugin:vercel:vercel`, and
    /// a url contains a colon too, so splitting on one gets it wrong either way.
    nonisolated static func parseHealth(_ output: String,
                                        names: [String]) -> [String: MCPServer.Health] {
        // Longest first, so `plugin:a:b` wins over a hypothetical `plugin:a`.
        let candidates = names.sorted { $0.count > $1.count }
        var states: [String: MCPServer.Health] = [:]

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let name = candidates.first(where: { trimmed.hasPrefix($0 + ":") })
            else { continue }
            let lower = trimmed.lowercased()
            if lower.contains("needs authentication") { states[name] = .needsAuth }
            else if lower.contains("connected") { states[name] = .connected }
            else if lower.contains("failed") || lower.contains("error") { states[name] = .failed }
        }
        return states
    }
}
