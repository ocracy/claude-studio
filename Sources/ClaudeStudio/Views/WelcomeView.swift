import SwiftUI
import AppKit

struct WelcomeView: View {
    let onOpen: (Project) -> Void

    @StateObject private var recents = Recents.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var states = SessionStates.shared
    @State private var query = ""
    @State private var sessionCounts: [String: Int] = [:]
    @State private var colors: [String: Color] = [:]
    @State private var highlighted = 0
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
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .background(Theme.chrome)

            recentsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .onAppear {
            recents.pruneMissing()
            loadSessionCounts()
            loadColors()
            searchFocused = true
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 56)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(0.16))
                .overlay(
                    Image(systemName: "asterisk")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                )
                .frame(width: 38, height: 38)

            Text("Claude Studio")
                .font(Theme.ui(20, .semibold))
                .foregroundStyle(Theme.text)
                .padding(.top, 14)
            Text("Every project, every session, one window each.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.text3)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 1) {
                action(icon: "folder.badge.plus", title: "Open folder…", shortcut: "⌘O") {
                    if let project = Recents.chooseFolder() { onOpen(project) }
                }
                action(icon: "macwindow", title: "New window", shortcut: "⇧⌘N") {
                    WindowManager.shared.openWelcome()
                }
                action(icon: "gearshape", title: "Settings", shortcut: "⌘,") {
                    SettingsWindow.show()
                }
                if let version = updater.availableVersion {
                    action(icon: "arrow.down.circle", title: "Update to \(version)",
                           shortcut: "", accent: true) {
                        SettingsWindow.show()
                    }
                }
            }
            .padding(.top, 26)
            .padding(.horizontal, -8)

            Spacer()

            Text("Sessions live in tmux and outlive the app.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.text3)
            Text("v\(updater.currentVersion)")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.text3.opacity(0.7))
                .padding(.top, 3)
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(icon: String, title: String, shortcut: String,
                        accent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HoverRow(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8), radius: 6) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(accent ? Theme.accent : Theme.text3)
                        .frame(width: 18)
                    Text(title)
                        .font(Theme.ui(12.5))
                        .foregroundStyle(accent ? Theme.accent : Theme.text)
                    Spacer()
                    Text(shortcut).font(Theme.ui(11)).foregroundStyle(Theme.text3)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var recentsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Recent projects")
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.text)
                if !recents.projects.isEmpty {
                    Text("\(recents.projects.count)")
                        .font(Theme.ui(12))
                        .foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            .padding(.bottom, 14)

            searchField
                .padding(.bottom, 10)

            if recents.projects.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                Text("Nothing matches “\(query)”.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, project in
                            row(project, index: index)
                        }
                    }
                    .padding(.horizontal, -6)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 40)
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(filtered.count - 1, highlighted + 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Theme.text3)
            TextField("Search projects", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(13))
                .focused($searchFocused)
                .onSubmit {
                    if filtered.indices.contains(highlighted) { onOpen(filtered[highlighted]) }
                }
            Text("↵ to open")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.text3)
                .opacity(filtered.isEmpty ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hover))
    }

    private func row(_ project: Project, index: Int) -> some View {
        let live = states.live.filter { $0.projectPath == project.path }
        let working = live.filter { $0.attention == .working }.count
        let waiting = live.filter { $0.attention.needsAttention }.count
        let open = sessionCounts[project.shortID] ?? 0
        return Button { onOpen(project) } label: {
            HoverRow(selected: index == highlighted && !query.isEmpty,
                     padding: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 10), radius: 8) {
                HStack(spacing: 12) {
                    ProjectAvatar(name: project.name,
                                  color: colors[project.path] ?? ProjectAvatar.color(for: project.path),
                                  size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(Theme.ui(13, .medium))
                            .foregroundStyle(Theme.text)
                        Text(project.displayPath)
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.text3)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 10) {
                        if working > 0 { badge(working, color: Theme.running, help: "working") }
                        if waiting > 0 { badge(waiting, color: Theme.waiting, help: "waiting for you") }
                        if open > 0 && working == 0 && waiting == 0 {
                            Text("\(open) open")
                                .font(Theme.ui(11))
                                .foregroundStyle(Theme.text3)
                        }
                    }
                    Text(project.lastOpened.compactAge)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 34, alignment: .trailing)
                    Text(index < 9 ? "⌘\(index + 1)" : "")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.text3.opacity(0.7))
                        .frame(width: 24, alignment: .trailing)
                }
            }
        }
        .buttonStyle(.plain)
        .background {
            if index < 9 {
                Button("") { onOpen(project) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .opacity(0)
            }
        }
        .help(project.lastOpened.relative)
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.url])
            }
            Button("Remove from list") { recents.forget(project) }
        }
    }

    private func badge(_ value: Int, color: Color, help: String) -> some View {
        HStack(spacing: 4) {
            StatusDot(color: color, size: 6)
            Text("\(value)").font(Theme.ui(11)).foregroundStyle(Theme.text2)
        }
        .help("\(value) \(help)")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No projects yet")
                .font(Theme.ui(14, .medium))
                .foregroundStyle(Theme.text2)
            Text("Open a folder and it shows up here, with its live sessions.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.text3)
            SmallButton(title: "Open folder…", icon: "folder.badge.plus", prominent: true) {
                if let project = Recents.chooseFolder() { onOpen(project) }
            }
            .padding(.top, 6)
            Spacer()
        }
        .padding(.top, 12)
    }

    private func loadColors() {
        let projects = recents.projects
        Task.detached(priority: .utility) {
            let found = Dictionary(projects.map { ($0.path, ProjectAvatar.color(for: $0)) }, uniquingKeysWith: { first, _ in first })
            await MainActor.run { self.colors = found }
        }
    }

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
