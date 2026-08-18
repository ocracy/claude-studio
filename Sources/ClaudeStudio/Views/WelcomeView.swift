import SwiftUI
import AppKit

/// Launch screen: pick a folder or return to a recent project.
/// Nothing is scanned — the list comes from one small JSON file, so the window
/// appears instantly.
struct WelcomeView: View {
    let onOpen: (Project) -> Void

    @StateObject private var recents = Recents.shared
    @ObservedObject private var updater = Updater.shared
    @State private var query = ""
    @State private var sessionCounts: [String: Int] = [:]
    /// Project path → its accent, read from each `.cs/settings.json` off the main
    /// thread. The list is what these colors are for: telling projects apart before
    /// one is even open.
    @State private var accents: [String: Color] = [:]
    @FocusState private var searchFocused: Bool

    private var filtered: [Project] {
        guard let q = query.nilIfEmpty?.lowercased() else { return recents.projects }
        return recents.projects.filter {
            $0.name.lowercased().contains(q) || $0.displayPath.lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            intro
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(Theme.chrome)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }

            recentsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .onAppear {
            recents.pruneMissing()
            loadSessionCounts()
            loadAccents()
            searchFocused = true
        }
    }

    // MARK: - Left column

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 60)

            Text("Claude Studio")
                .font(Theme.ui(24, .semibold))
                .foregroundStyle(Theme.text)
            Text("one screen for your projects")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.text3)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                action(icon: "folder", title: "Open folder…", shortcut: "⌘O") {
                    if let project = Recents.chooseFolder() { onOpen(project) }
                }
                action(icon: "macwindow.badge.plus", title: "New window", shortcut: "⇧⌘N") {
                    WindowManager.shared.openWelcome()
                }
                action(icon: "gearshape", title: "Settings", shortcut: "⌘,") {
                    SettingsWindow.show()
                }
                // Without a project window there is no top bar to carry the badge,
                // so the welcome screen surfaces the update too.
                if let version = updater.availableVersion {
                    action(icon: "arrow.down.circle", title: "Update to \(version)",
                           shortcut: "", accent: true) {
                        SettingsWindow.show()
                    }
                }
            }
            .padding(.top, 28)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                note("Sessions persist through tmux")
                note("Skills are read from `.claude/skills`")
                note("Scheduled runs continue while the app is closed")
                note("Settings live in the project's `.cs` folder")
            }
            .padding(.bottom, 26)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(icon: String, title: String, shortcut: String,
                        accent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HoverRow(padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                    Text(title)
                        .font(Theme.ui(12.5, accent ? .medium : .regular))
                        .foregroundStyle(accent ? Theme.accent : Theme.text)
                    Spacer()
                    Text(shortcut).font(Theme.mono(10.5)).foregroundStyle(Theme.text3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(Theme.text3).frame(width: 3, height: 3).padding(.top, 5)
            Text(text).font(Theme.ui(11)).foregroundStyle(Theme.text3)
        }
    }

    // MARK: - Right column

    private var recentsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "recent projects")
                Spacer()
            }
            .padding(.horizontal, 26)
            .padding(.top, 62)
            .padding(.bottom, 10)

            searchField
                .padding(.horizontal, 26)
                .padding(.bottom, 10)

            if recents.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { row($0) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.text3)
            TextField("search", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .focused($searchFocused)
                .onSubmit { if let first = filtered.first { onOpen(first) } }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.separator))
        )
    }

    private func row(_ project: Project) -> some View {
        Button { onOpen(project) } label: {
            HoverRow(padding: EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)) {
                HStack(spacing: 10) {
                    StatusDot(color: accents[project.path] ?? Theme.accent, size: 7)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(Theme.ui(12.5, .medium))
                            .foregroundStyle(Theme.text)
                        Text(project.displayPath)
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer()
                    if let count = sessionCounts[project.shortID], count > 0 {
                        HStack(spacing: 5) {
                            StatusDot(color: Theme.running, size: 5)
                            Text("\(count) sessions")
                        }
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.text2)
                    }
                    Text(project.lastOpened.relative)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.text3)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            }
            Button("Remove from list") { recents.forget(project) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No projects yet")
                .font(Theme.ui(15, .medium))
                .foregroundStyle(Theme.text2)
            Text("Open a folder to get started.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.text3)
            SmallButton(title: "Open folder", icon: "folder", prominent: true) {
                if let project = Recents.chooseFolder() { onOpen(project) }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Each project's accent, read once in the background — the recents list can be
    /// long and every entry means opening a small file.
    private func loadAccents() {
        let projects = recents.projects
        Task.detached(priority: .utility) {
            var found: [String: Color] = [:]
            for project in projects {
                found[project.path] = ProjectSettings.theme(of: project).accent
            }
            let result = found
            await MainActor.run { self.accents = result }
        }
    }

    /// Live session counts are read from tmux once, in the background.
    private func loadSessionCounts() {
        guard Tmux.isAvailable else { return }
        Task.detached(priority: .utility) {
            var counts: [String: Int] = [:]
            for session in Tmux.sessions() where !session.name.contains("-sh-") {
                counts[session.projectID, default: 0] += 1
            }
            let result = counts
            await MainActor.run { self.sessionCounts = result }
        }
    }
}
