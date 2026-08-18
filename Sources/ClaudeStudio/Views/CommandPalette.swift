import SwiftUI
import AppKit

/// ⌘P — one search field for everything the window can do: switch to a session,
/// reopen a closed one, start a terminal, run a skill, jump to a service, open
/// another workspace.
///
/// The list is built on demand, so a closed palette costs nothing.
struct CommandPalette: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    @StateObject private var recents = Recents.shared

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Clicking outside dismisses, like every palette on this platform.
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                field
                if results.isEmpty {
                    Text("No matches")
                        .font(Theme.ui(12))
                        .foregroundStyle(theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                } else {
                    list
                }
            }
            .frame(width: 620)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.chromeBase)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.separator))
                    .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
            )
            .padding(.top, 70)
        }
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onExitCommand { close() }
    }

    // MARK: - Pieces

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.text3)
            TextField("Search sessions, skills, services, workspaces…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(14))
                .focused($focused)
                .onSubmit(run)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        row(item, selected: index == selection)
                            .id(index)
                            .onTapGesture {
                                selection = index
                                run()
                            }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
            .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
        }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12))
                .foregroundStyle(selected ? theme.accent : theme.text3)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(item.group)
                .font(Theme.ui(10))
                .foregroundStyle(theme.text3)
            if !item.shortcut.isEmpty {
                Text(item.shortcut)
                    .font(Theme.mono(10))
                    .foregroundStyle(theme.text3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? theme.selection : .clear))
        .contentShape(Rectangle())
    }

    // MARK: - Behaviour

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func run() {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        close()
        item.action()
    }

    private func close() {
        model.paletteOpen = false
        query = ""
        selection = 0
    }

    // MARK: - Items

    private var results: [PaletteItem] {
        let all = items
        guard let needle = query.nilIfEmpty?.lowercased() else { return all }
        return all
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = Self.score(item.haystack, needle) else { return nil }
                return (item, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var items: [PaletteItem] {
        var out: [PaletteItem] = []

        // Actions first: they are what an empty query should offer.
        out.append(PaletteItem(id: "new-session", icon: "plus.bubble", group: "Action",
                               title: "New Claude session", shortcut: "⌘N") {
            model.newSession()
        })
        out.append(PaletteItem(id: "new-terminal", icon: "terminal", group: "Action",
                               title: "New terminal", shortcut: "⇧⌘T") {
            model.newTerminal()
        })

        for record in model.openSessions {
            out.append(PaletteItem(id: "s-\(record.tmux)", icon: "bubble.left.and.bubble.right",
                                   group: "Session", title: record.name,
                                   subtitle: model.attention(of: record).label) {
                model.openSession(record)
            })
        }

        for record in model.pastSessions {
            out.append(PaletteItem(id: "p-\(record.tmux)", icon: "arrow.uturn.backward",
                                   group: "Closed session", title: record.name,
                                   subtitle: model.canResume(record)
                                             ? "resumes conversation · \(record.lastUsed.relative)"
                                             : "starts fresh · \(record.lastUsed.relative)") {
                model.openSession(record)
            })
        }

        for skill in model.skills.skills {
            out.append(PaletteItem(id: "k-\(skill.id)", icon: "sparkles", group: "Skill",
                                   title: skill.name, subtitle: skill.description ?? "") {
                model.openSkill(skill)
            })
            out.append(PaletteItem(id: "kr-\(skill.id)", icon: "play.circle", group: "Run skill",
                                   title: "Run \(skill.name)", subtitle: "in a visible session") {
                model.runSkillVisible(skill)
            })
        }

        for service in model.store.config.services {
            let status = model.engine.serviceStatus[service.id] ?? .stopped
            out.append(PaletteItem(id: "v-\(service.id)", icon: "server.rack", group: "Service",
                                   title: service.name,
                                   subtitle: "\(status.label) · \(service.command)") {
                model.openService(service)
                if !status.isLive { model.engine.startService(service, project: model.project) }
            })
        }

        for link in model.links {
            out.append(PaleteLinkItem(link: link, model: model).item)
        }

        for server in model.mcp.servers {
            out.append(PaletteItem(id: "m-\(server.id)", icon: "point.3.connected.trianglepath.dotted",
                                   group: "MCP server", title: server.name,
                                   subtitle: "\(server.scope.label) · \(server.detail)") {
                model.runMCPCommand("get \(Shell.quoted(server.name))",
                                    title: "mcp: \(server.name)")
            })
        }

        for command in model.claudeCommands.commands {
            out.append(PaletteItem(id: "cc-\(command.id)", icon: "slash.circle",
                                   group: "Claude command", title: command.invocation,
                                   subtitle: command.description ?? "") {
                model.runClaudeCommand(command)
            })
        }

        for script in model.store.config.scripts {
            out.append(PaletteItem(id: "x-\(script.id)", icon: "bolt", group: "Script",
                                   title: script.name, subtitle: script.command) {
                model.runScript(script)
            })
        }

        for terminal in model.store.config.terminals {
            out.append(PaletteItem(id: "t-\(terminal.id)", icon: "terminal", group: "Terminal",
                                   title: terminal.name) {
                model.openTerminal(terminal)
            })
        }

        for schedule in model.store.config.schedules {
            out.append(PaletteItem(id: "c-\(schedule.id)", icon: "clock", group: "Schedule",
                                   title: schedule.skill,
                                   subtitle: schedule.enabled ? schedule.summary : "paused") {
                model.openCron(schedule)
            })
        }

        // Other workspaces open in their own window — one project, one window.
        for project in recents.projects where project.path != model.project.path {
            out.append(PaletteItem(id: "w-\(project.path)", icon: "folder", group: "Workspace",
                                   title: project.name, subtitle: project.displayPath) {
                WindowManager.shared.open(project: project)
            })
        }

        out.append(PaletteItem(id: "open-folder", icon: "folder.badge.plus", group: "Workspace",
                               title: "Open folder…", shortcut: "⌘O") {
            WindowManager.shared.perform(.openFolder)
        })
        out.append(PaletteItem(id: "new-skill", icon: "sparkles", group: "Action",
                               title: "Create a skill with Claude") {
            model.createSkillWithClaude()
        })
        out.append(PaletteItem(id: "new-command", icon: "slash.circle", group: "Action",
                               title: "Create a Claude command") {
            model.createCommandWithClaude()
        })
        out.append(PaletteItem(id: "check-mcp", icon: "stethoscope", group: "Action",
                               title: "Check MCP connections") {
            model.mcp.checkHealth()
        })
        out.append(PaletteItem(id: "appearance", icon: "paintpalette", group: "Action",
                               title: "Appearance — project theme") {
            model.themeSheetOpen = true
        })
        out.append(PaletteItem(id: "settings", icon: "gearshape", group: "Action",
                               title: "Settings", shortcut: "⌘,") {
            SettingsWindow.show()
        })
        out.append(PaletteItem(id: "reveal", icon: "folder", group: "Action",
                               title: "Reveal project in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.project.url])
        })
        return out
    }

    /// Subsequence match with bonuses for exact substrings and word starts —
    /// enough to feel like a real palette without a scoring library.
    static func score(_ haystack: String, _ needle: String) -> Int? {
        let hay = haystack.lowercased()
        if hay == needle { return 1000 }
        if hay.hasPrefix(needle) { return 800 }
        if hay.contains(needle) { return 600 }

        var score = 0
        var index = hay.startIndex
        var previousMatched = false
        for character in needle {
            guard let found = hay[index...].firstIndex(of: character) else { return nil }
            score += previousMatched && found == index ? 6 : 2
            previousMatched = found == index
            index = hay.index(after: found)
        }
        return score
    }
}

/// A linked project in the palette: opens it in its own window.
@MainActor
private struct PaleteLinkItem {
    let link: ProjectLink
    let model: StudioModel

    var item: PaletteItem {
        PaletteItem(id: "l-\(link.id)", icon: "link", group: "Linked project",
                    title: link.name,
                    subtitle: "\(link.allowEdits ? "edits" : "read-only") · \(link.displayPath)") {
            WindowManager.shared.open(project: Project(path: link.path))
        }
    }
}

struct PaletteItem: Identifiable {
    let id: String
    let icon: String
    let group: String
    let title: String
    var subtitle: String = ""
    var shortcut: String = ""
    let action: () -> Void

    init(id: String, icon: String, group: String, title: String,
         subtitle: String = "", shortcut: String = "", action: @escaping () -> Void) {
        self.id = id
        self.icon = icon
        self.group = group
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.action = action
    }

    var haystack: String { "\(title) \(subtitle) \(group)" }
}
