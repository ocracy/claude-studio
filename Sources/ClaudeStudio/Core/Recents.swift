import Foundation
import SwiftUI
import AppKit

/// Karşılama ekranındaki "son projeler" listesi. Tek küçük JSON dosyası —
/// uygulama açılışında disk taraması yapılmaz, liste anında gelir.
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

    /// Diskte artık olmayan girdileri temizler.
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

    // MARK: - Klasör seçici

    /// Sistem klasör seçicisini açar. Seçim yapılmazsa `nil`.
    static func chooseFolder() -> Project? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Aç"
        panel.message = "Bir proje klasörü seçin"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Project(path: url.path)
    }
}
