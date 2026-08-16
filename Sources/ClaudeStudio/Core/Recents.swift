import Foundation
import SwiftUI
import AppKit

/// The "recent projects" list on the welcome screen. One small JSON file — no
/// disk scanning at launch, so the list appears instantly.
@MainActor
final class Recents: ObservableObject {
    static let shared = Recents()

    @Published private(set) var projects: [Project] = []

    private init() {
        if let data = try? Data(contentsOf: Paths.recentsFile),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded
        }
    }

    func remember(_ project: Project) {
        var updated = projects.filter { $0.path != project.path }
        var fresh = project
        fresh.lastOpened = Date()
        updated.insert(fresh, at: 0)
        projects = Array(updated.prefix(20))
        save()
    }

    func forget(_ project: Project) {
        projects.removeAll { $0.path == project.path }
        save()
    }

    /// Drops entries that no longer exist on disk.
    func pruneMissing() {
        let before = projects.count
        projects = projects.filter(\.exists)
        if projects.count != before { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(projects) else { return }
        Paths.writeAtomically(data, to: Paths.recentsFile)
    }

    // MARK: - Folder picker

    /// Opens the system folder picker. Returns `nil` if nothing is chosen.
    static func chooseFolder() -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Project(path: url.path)
    }
}
