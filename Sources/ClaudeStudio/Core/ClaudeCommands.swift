import Foundation
import SwiftUI

/// Discovers Claude Code slash commands the way Claude itself resolves them:
///
///   `<project>/.claude/commands/<name>.md`        → `/name`
///   `<project>/.claude/commands/<dir>/<name>.md`  → `/dir:name`
///   `~/.claude/commands/…`                        → the same, available everywhere
///
/// A project command shadows a global one of the same name. Frontmatter is optional;
/// `description` and `argument-hint` are used when present, and a command without
/// frontmatter is perfectly valid — plenty of real ones are just markdown.
@MainActor
final class CommandStore: ObservableObject {
    @Published private(set) var commands: [ClaudeCommand] = []

    private var watcher: DirectoryWatcher?

    func start(project: Project) {
        scan(project: project)
        watcher = DirectoryWatcher(url: Paths.projectCommandsDir(project)) { [weak self] in
            self?.scan(project: project)
        }
    }

    func scan(project: Project) {
        let projectDir = Paths.projectCommandsDir(project)
        Task.detached(priority: .utility) {
            let projectCommands = Self.discover(in: projectDir, scope: .project)
            let globalCommands = Self.discover(in: Paths.globalCommandsDir, scope: .global)
            let names = Set(projectCommands.map(\.name))
            let merged = (projectCommands + globalCommands.filter { !names.contains($0.name) })
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            await MainActor.run { self.commands = merged }
        }
    }

    func command(named name: String) -> ClaudeCommand? { commands.first { $0.name == name } }

    // MARK: - Discovery

    /// Walks one level of subdirectories, which is how Claude namespaces commands.
    private nonisolated static func discover(in root: URL,
                                            scope: Skill.Scope) -> [ClaudeCommand] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var found: [ClaudeCommand] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let namespace = entry.lastPathComponent
                found += discover(in: entry, scope: scope).map {
                    var nested = $0
                    nested.name = "\(namespace):\($0.name)"
                    return nested
                }
            } else if entry.pathExtension.lowercased() == "md" {
                found.append(read(entry, scope: scope))
            }
        }
        return found
    }

    private nonisolated static func read(_ url: URL, scope: Skill.Scope) -> ClaudeCommand {
        var command = ClaudeCommand(name: url.deletingPathExtension().lastPathComponent,
                                    url: url, scope: scope)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return command }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8 * 1024)) ?? Data()
        guard let head = String(data: data, encoding: .utf8) else { return command }

        let (fields, body) = Frontmatter.split(head)
        command.description = fields?["description"]?.nilIfEmpty
        command.argumentHint = fields?["argument-hint"]?.nilIfEmpty
        // No frontmatter description: fall back to the first meaningful line, which is
        // what the command is about anyway.
        if command.description == nil {
            command.description = body
                .components(separatedBy: .newlines)
                .first { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                }?
                .trimmingCharacters(in: .whitespaces)
        }
        return command
    }
}
