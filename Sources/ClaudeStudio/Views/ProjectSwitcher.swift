import SwiftUI
import AppKit

struct ProjectAvatar: View {
    let name: String
    var color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color.opacity(0.22))
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(color)
            )
            .frame(width: size, height: size)
    }

    nonisolated static let palette: [Color] = [
        Color(red: 0.851, green: 0.467, blue: 0.341),
        Color(red: 0.310, green: 0.631, blue: 0.941),
        Color(red: 0.239, green: 0.769, blue: 0.514),
        Color(red: 0.776, green: 0.525, blue: 0.753),
        Color(red: 0.910, green: 0.639, blue: 0.239),
        Color(red: 0.306, green: 0.788, blue: 0.690),
    ]

    nonisolated static func color(for project: Project) -> Color {
        let theme = ProjectSettings.theme(of: project)
        return theme.isDefault ? color(for: project.path) : theme.accent
    }

    nonisolated static func color(for path: String) -> Color {
        let hash = path.unicodeScalars.reduce(UInt32(2166136261)) { ($0 ^ $1.value) &* 16777619 }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

struct ProjectSwitcherButton: View {
    @ObservedObject var model: StudioModel
    @Environment(\.studioTheme) private var theme

    var body: some View {
        Button { model.projectSwitcherOpen.toggle() } label: {
            HoverRow(selected: model.projectSwitcherOpen,
                     padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8), radius: 7) {
                HStack(spacing: 9) {
                    ProjectAvatar(name: model.project.name, color: theme.accent, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.project.name)
                            .font(Theme.ui(12.5, .medium))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text(model.project.displayPath)
                            .font(Theme.ui(10.5))
                            .foregroundStyle(theme.text3)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .light))
                        .foregroundStyle(theme.text3)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Switch project (⌘⇧O)")
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .popover(isPresented: $model.projectSwitcherOpen, arrowEdge: .bottom) {
            ProjectSwitcher(model: model) { model.projectSwitcherOpen = false }
        }
    }
}

struct ProjectSwitcher: View {
    @ObservedObject var model: StudioModel
    let onDismiss: () -> Void
    @StateObject private var recents = Recents.shared
    @ObservedObject private var states = SessionStates.shared
    @Environment(\.studioTheme) private var theme
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool
    @State private var colors: [String: Color] = [:]

    private var projects: [Project] {
        let all = recents.projects.filter { $0.path != model.project.path }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(needle) || $0.path.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(theme.text3)
                TextField("Switch to project…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13))
                    .focused($focused)
                    .onSubmit { open(at: highlighted) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Rectangle().fill(theme.separator.opacity(0.5)).frame(height: 1)

            ScrollView {
                VStack(spacing: 1) {
                    if projects.isEmpty {
                        Text(query.isEmpty ? "No other projects yet." : "Nothing matches.")
                            .font(Theme.ui(12))
                            .foregroundStyle(theme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        Button { open(at: index) } label: {
                            HoverRow(selected: index == highlighted,
                                     padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8), radius: 7) {
                                row(project, index: index)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)

            Rectangle().fill(theme.separator.opacity(0.5)).frame(height: 1)

            Button {
                onDismiss()
                WindowManager.shared.perform(.openFolder)
            } label: {
                HoverRow(padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8), radius: 7) {
                    HStack(spacing: 9) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(theme.text3)
                            .frame(width: 24)
                        Text("Open folder…").font(Theme.ui(12.5)).foregroundStyle(theme.text)
                        Spacer()
                        Text("⌘O").font(Theme.ui(10.5)).foregroundStyle(theme.text3)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(6)
        }
        .frame(width: 340)
        .onAppear {
            focused = true
            let projects = recents.projects
            Task.detached(priority: .utility) {
                let found = Dictionary(projects.map { ($0.path, ProjectAvatar.color(for: $0)) }, uniquingKeysWith: { first, _ in first })
                await MainActor.run { colors = found }
            }
        }
        .onChange(of: query) { highlighted = 0 }
        .onKeyPress(.downArrow) {
            highlighted = min(projects.count - 1, highlighted + 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
    }

    private func row(_ project: Project, index: Int) -> some View {
        let live = states.live.filter { $0.projectPath == project.path }
        let asking = live.filter { $0.attention == .waiting }.count
        let unread = live.filter { $0.attention == .done }.count
        let working = live.filter { $0.attention == .working }.count
        return HStack(spacing: 9) {
            ProjectAvatar(name: project.name, color: colors[project.path] ?? ProjectAvatar.color(for: project.path), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(Theme.ui(12.5))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if WindowManager.shared.isOpen(project) {
                        Text("open")
                            .font(Theme.ui(9.5))
                            .foregroundStyle(theme.text3)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.hover))
                    }
                }
                Text(project.displayPath)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            HStack(spacing: 8) {
                if working > 0 { count(working, Theme.running) }
                if asking + unread > 0 { count(asking + unread, Theme.waiting) }
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(theme.text3)
                }
            }
        }
        .background(
            Group {
                if index < 9 {
                    Button("") { open(at: index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                        .opacity(0)
                }
            }
        )
    }

    private func count(_ value: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            StatusDot(color: color, size: 5)
            Text("\(value)").font(Theme.mono(10.5)).foregroundStyle(theme.text3)
        }
    }

    private func open(at index: Int) {
        guard projects.indices.contains(index) else { return }
        let project = projects[index]
        onDismiss()
        WindowManager.shared.open(project: project)
    }
}
