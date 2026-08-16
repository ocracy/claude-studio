import Foundation
import SwiftUI

/// Claude Code skill'lerini keşfeder — hiçbir dönüştürme yapmadan, Claude'un
/// kendi düzenini olduğu gibi okuyarak:
///
///   .claude/skills/<ad>/SKILL.md   → skill adı = klasör adı
///   .claude/skills/<ad>.md         → skill adı = dosya adı
///
/// Proje skill'leri `~/.claude/skills` altındaki genel skill'lerle birlikte
/// listelenir; aynı ada sahip proje skill'i geneli gölgeler (Claude'un
/// önceliğiyle aynı).
@MainActor
final class SkillStore: ObservableObject {
    @Published private(set) var skills: [Skill] = []
    @Published private(set) var scanning = false

    private var watcher: DirectoryWatcher?

    /// Skill'leri tarar ve `.claude/skills` klasörünü izlemeye alır — dosya
    /// eklendiğinde/silindiğinde liste kendiliğinden tazelenir.
    func start(project: Project, onChange: (@MainActor (Set<String>) -> Void)? = nil) {
        scan(project: project, onChange: onChange)
        let dir = Paths.projectSkillsDir(project)
        watcher = DirectoryWatcher(url: dir) { [weak self] in
            self?.scan(project: project, onChange: onChange)
        }
    }

    func scan(project: Project, onChange: (@MainActor (Set<String>) -> Void)? = nil) {
        scanning = true
        let projectDir = Paths.projectSkillsDir(project)
        Task.detached(priority: .utility) {
            let projectSkills = Self.discover(in: projectDir, scope: .project)
            let globalSkills = Self.discover(in: Paths.globalSkillsDir, scope: .global)
            let names = Set(projectSkills.map(\.name))
            let merged = projectSkills + globalSkills.filter { !names.contains($0.name) }
            await MainActor.run {
                self.skills = merged
                self.scanning = false
                onChange?(names)
            }
        }
    }

    func skill(named name: String) -> Skill? { skills.first { $0.name == name } }

    // MARK: - Keşif

    private nonisolated static func discover(in root: URL, scope: Skill.Scope) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var found: [String: Skill] = [:]
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let file = entry.appendingPathComponent("SKILL.md")
                guard fm.fileExists(atPath: file.path) else { continue }
                let name = entry.lastPathComponent
                found[name] = Skill(name: name, description: frontmatterDescription(file),
                                    url: file, scope: scope)
            } else if entry.pathExtension.lowercased() == "md",
                      entry.deletingPathExtension().lastPathComponent.lowercased() != "readme" {
                let name = entry.deletingPathExtension().lastPathComponent
                found[name] = Skill(name: name, description: frontmatterDescription(entry),
                                    url: entry, scope: scope)
            }
        }
        return found.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// SKILL.md frontmatter'ındaki `description`. Yalnız baştaki blok okunur.
    private nonisolated static func frontmatterDescription(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8 * 1024)) ?? Data()
        guard let head = String(data: data, encoding: .utf8) else { return nil }
        return Frontmatter.split(head).fields?["description"]?.nilIfEmpty
    }
}

// MARK: - Frontmatter

/// `---` ile sarılı YAML benzeri başlık bloğu okuyucusu. Tam YAML DEĞİL —
/// kasıtlı: dış bağımlılık eklemeden `key: value` ve `key: |` bloklarını
/// karşılamak yeter.
enum Frontmatter {

    static func split(_ text: String) -> (fields: [String: String]?, body: String) {
        let lines = text.components(separatedBy: .newlines)
        guard let first = lines.first,
              first.trimmingCharacters(in: .whitespaces) == "---",
              let endIdx = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return (nil, text) }

        var fields: [String: String] = [:]
        var pendingKey: String?
        var block: [String] = []

        func flush() {
            if let key = pendingKey {
                fields[key] = block.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            pendingKey = nil
            block = []
        }

        for raw in lines[1..<endIdx] {
            if pendingKey != nil {
                if raw.isEmpty || raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                    block.append(raw.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "" : String(raw.drop(while: { $0 == " " || $0 == "\t" })))
                    continue
                }
                flush()
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":")
            else { continue }

            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            if ["|", ">", "|-", ">-"].contains(value) { pendingKey = key; continue }
            if let hash = value.range(of: " #") {
                value = String(value[value.startIndex..<hash.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            fields[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        flush()

        let body = lines[(endIdx + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (fields, body)
    }

    static func date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: raw) { return d }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
                       "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }
}

// MARK: - Klasör izleyici

/// Bir klasördeki değişiklikleri izler (yazma/silme/yeniden adlandırma) ve
/// 300 ms sönümleme ile geri çağırır. Klasör yoksa oluşturulmasını bekler.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var debounce: DispatchWorkItem?

    init?(url: URL, handler: @escaping @MainActor () -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            self?.debounce?.cancel()
            let work = DispatchWorkItem { Task { @MainActor in handler() } }
            self?.debounce = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        src.setCancelHandler { [descriptor] in close(descriptor) }
        src.resume()
        source = src
    }

    deinit {
        debounce?.cancel()
        source?.cancel()
    }
}
