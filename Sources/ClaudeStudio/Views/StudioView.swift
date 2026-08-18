import SwiftUI
import AppKit

/// Main screen: top bar · activity rail · sidebar · tabs · content · status bar.
struct StudioView: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let onClose: () -> Void

    @State private var draggingSidebar = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, onClose: onClose, onAppearance: { model.themeSheetOpen = true })

            HStack(spacing: 0) {
                ActivityRail(model: model)
                Rectangle().fill(theme.separator).frame(width: 1)

                Sidebar(model: model)
                    .frame(width: model.sidebarWidth)

                sidebarHandle

                VStack(spacing: 0) {
                    TabBar(model: model)
                    ContentArea(model: model)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)

            StatusBar(model: model)
        }
        .background(theme.surface)
        .overlay {
            if model.paletteOpen { CommandPalette(model: model) }
        }
        .sheet(isPresented: $model.themeSheetOpen) {
            ThemeEditor(model: model, onDismiss: { model.themeSheetOpen = false })
        }
        // Everything below reads the project's accent from here; nothing consults a
        // global, because a second window is showing a different project.
        .environment(\.studioTheme, model.theme)
        .onDisappear { model.stop() }
    }

    /// The sidebar width is dragged to size and persisted in `.cs/settings.json`.
    private var sidebarHandle: some View {
        Rectangle()
            .fill(draggingSidebar ? model.theme.accent : theme.separator)
            .frame(width: 1)
            .overlay(Color.clear.frame(width: 7).contentShape(Rectangle()))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        draggingSidebar = true
                        model.sidebarWidth = min(420, max(190, model.sidebarWidth + value.translation.width))
                    }
                    .onEnded { _ in
                        draggingSidebar = false
                        model.store.mutate { $0.sidebarWidth = Double(model.sidebarWidth) }
                    }
            )
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @ObservedObject var model: StudioModel
    let onClose: () -> Void
    let onAppearance: () -> Void
    @State private var menuOpen = false
    @ObservedObject private var updater = Updater.shared
    @Environment(\.studioTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Text("Claude Studio")
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(theme.text)
                .fixedSize()

            Button { menuOpen.toggle() } label: {
                HStack(spacing: 6) {
                    // The project's own color, right where its name is — this is what
                    // tells two windows apart on a crowded screen.
                    StatusDot(color: theme.accent, size: 7)
                    Text(model.project.name)
                        .font(Theme.ui(12.5, .medium))
                        .foregroundStyle(theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.text3)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(menuOpen ? theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .headerControl()
            .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
                ProjectMenu(model: model,
                            onAppearance: { menuOpen = false; onAppearance() },
                            onClose: { menuOpen = false; onClose() })
            }

            Text(model.project.displayPath)
                .font(Theme.mono(11))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 12)

            if model.attentionCount > 0 {
                HStack(spacing: 6) {
                    StatusDot(color: Theme.waiting)
                    Text("\(model.attentionCount) waiting")
                }
                .font(Theme.ui(11.5))
                .foregroundStyle(theme.text2)
            }

            if !model.store.config.services.isEmpty {
                SmallButton(title: model.runningServiceCount > 0 ? "Stop all" : "Start services",
                            icon: model.runningServiceCount > 0 ? "stop.fill" : "play.fill") {
                    model.runningServiceCount > 0 ? model.stopAllServices() : model.startAllServices()
                }
                .headerControl()
            }

            if let version = updater.availableVersion {
                SmallButton(title: "Update · \(version)", icon: "arrow.down.circle") {
                    SettingsWindow.show()
                }
                .headerControl()
            }

            IconButton(icon: "gearshape", help: "Settings (⌘,)") {
                SettingsWindow.show()
            }
            .headerControl()
        }
        // Flush left, in line with the activity rail's icons below. The traffic
        // lights sit in the transparent title bar ABOVE this row — the header is
        // pushed down past them rather than indented around them, which is what
        // used to leave a gap nothing filled.
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .frame(height: 48)
        // Empty header space zooms the window on a double-click, like a title bar;
        // the controls opt out through `headerControl()` (see HeaderDoubleClick).
        .background(theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
    }
}

private struct ProjectMenu: View {
    @ObservedObject var model: StudioModel
    let onAppearance: () -> Void
    let onClose: () -> Void
    @StateObject private var recents = Recents.shared
    @Environment(\.studioTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            item("Appearance…", icon: "paintpalette",
                 detail: theme.preset.name) { onAppearance() }
            item("Reveal in Finder", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.project.url])
            }
            item("Open in Terminal", icon: "terminal") {
                Shell.runDetached("open -a Terminal \(Shell.quoted(model.project.path))")
            }
            item("Project settings (.cs)", icon: "gearshape") {
                Paths.ensure(Paths.csDir(model.project))
                NSWorkspace.shared.open(Paths.csDir(model.project))
            }
            Divider().padding(.vertical, 5)

            SectionLabel(text: "workspaces")
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 4)

            // Another project always opens in its own window — that is what keeps
            // switching instant, since nothing has to be torn down.
            ForEach(recents.projects.filter { $0.path != model.project.path }.prefix(6)) { project in
                item(project.name, icon: "folder", detail: project.displayPath) {
                    WindowManager.shared.open(project: project)
                }
            }
            item("Open folder…", icon: "folder.badge.plus") {
                WindowManager.shared.perform(.openFolder)
            }

            Divider().padding(.vertical, 5)
            item("Close project", icon: "xmark", tone: Theme.danger) { onClose() }
        }
        .padding(6)
        .frame(width: 260)
    }

    private func item(_ title: String, icon: String, detail: String = "",
                      tone: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HoverRow(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)) {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(Theme.ui(12.5)).foregroundStyle(tone ?? theme.text)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(Theme.mono(10))
                                .foregroundStyle(theme.text3)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Activity rail

private struct ActivityRail: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var dragging: StudioModel.Pane?
    @Environment(\.studioTheme) private var theme

    var body: some View {
        VStack(spacing: 4) {
            ForEach(StudioModel.orderedPanes) { pane in
                button(pane)
                    // Drag to reorder; the context menu does the same without a drag.
                    .onDrag {
                        dragging = pane
                        return NSItemProvider(object: pane.rawValue as NSString)
                    }
                    .onDrop(of: [.text], isTargeted: nil) { _ in
                        guard let source = dragging, source != pane else { return false }
                        StudioModel.movePane(source, before: pane)
                        dragging = nil
                        return true
                    }
                    .contextMenu {
                        Button("Move up") { StudioModel.movePane(pane, by: -1) }
                        Button("Move down") { StudioModel.movePane(pane, by: 1) }
                        Divider()
                        Button("Reset order") { StudioModel.resetPaneOrder() }
                    }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .background(theme.chrome)
    }

    private func button(_ pane: StudioModel.Pane) -> some View {
        let selected = model.pane == pane
        return Button { model.pane = pane } label: {
            Image(systemName: pane.icon)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(selected ? theme.text : theme.text3)
                .frame(width: 46, height: 40)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(selected ? theme.accent : .clear)
                        .frame(width: 2)
                }
                .overlay(alignment: .topTrailing) {
                    if pane == .sessions && model.attentionCount > 0 {
                        StatusDot(color: Theme.waiting, size: 5)
                            .padding(.top, 9).padding(.trailing, 9)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pane.help)
    }
}

// MARK: - Tab bar

private struct TabBar: View {
    @ObservedObject var model: StudioModel
    @Environment(\.studioTheme) private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs) { tab in
                    item(tab)
                }
            }
        }
        .frame(height: 34)
        .background(theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
    }

    private func item(_ tab: StudioTab) -> some View {
        let selected = model.activeTabID == tab.id
        return HStack(spacing: 7) {
            StatusDot(color: dotColor(tab), size: 5)
            Text(tab.title)
                .font(Theme.ui(12))
                .foregroundStyle(selected ? theme.text : theme.text2)
                .lineLimit(1)
            Button { model.closeTab(id: tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.text3)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 34)
        .background(selected ? theme.surface : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(selected ? theme.accent : .clear).frame(height: 2)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(theme.separator).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.activeTabID = tab.id }
    }

    private func dotColor(_ tab: StudioTab) -> Color {
        switch tab.kind {
        case .session:
            switch model.engine.attention[tab.terminalKey] ?? .idle {
            case .working: return Theme.running
            case .waiting: return Theme.waiting
            case .idle:    return theme.idle
            }
        case .service:
            guard let id = UUID(uuidString: tab.ref) else { return theme.idle }
            return (model.engine.serviceStatus[id] ?? .stopped).color
        case .terminal, .script:
            return model.engine.isLive(tab.terminalKey) ? Theme.running : theme.idle
        case .command:      return theme.accent.opacity(0.7)
        case .skill, .cron: return theme.text3
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var usage = UsageMonitor.shared
    @Environment(\.studioTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            Text(model.project.name).foregroundStyle(theme.text2)

            // What a session is running right now, and whose capability it is — the
            // skill may belong to this project, a linked one, or your global set.
            if let running = model.liveUsage.last?.usage {
                HStack(spacing: 5) {
                    StatusDot(color: theme.accent, size: 5)
                    Text("using \(running.display) · \(model.owner(of: running.name))")
                        .foregroundStyle(theme.text2)
                }
            }

            // A skill running with no tab of its own — a scheduled or background run —
            // is otherwise invisible from here.
            if let skill = model.runs.running.sorted().first {
                Button { model.openCron(skillNamed: skill) } label: {
                    HStack(spacing: 5) {
                        StatusDot(color: Theme.running, size: 5)
                        Text(model.runs.running.count > 1
                             ? "running \(model.runs.running.count) skills"
                             : "running \(skill)")
                            .foregroundStyle(theme.text2)
                    }
                }
                .buttonStyle(.plain)
                .help("Show the live output")
            }

            Spacer()
            Text("\(model.openSessions.count) sessions")
            Text("\(model.runningServiceCount)/\(model.store.config.services.count) services")
            if let next = model.store.nextRun {
                Text("next: \(next.skill) · \(next.date.shortStamp)")
            }
            if !Tmux.isAvailable {
                Text("tmux missing — sessions are not persistent").foregroundStyle(Theme.danger)
            }
        }
        .font(Theme.mono(10.5))
        .foregroundStyle(theme.text3)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
    }
}
