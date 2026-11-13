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
                if !model.sidebarHidden {
                    Sidebar(model: model)
                        .frame(width: model.sidebarWidth)

                    sidebarHandle
                }

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
        .sheet(isPresented: $model.conversationsOpen) {
            ConversationsSheet(model: model) { model.conversationsOpen = false }
        }
        .sheet(isPresented: $model.changesOpen) {
            ChangesSheet(model: model, path: model.workPath.isEmpty ? model.project.path : model.workPath) {
                model.changesOpen = false
            }
        }
        .sheet(isPresented: $model.findOpen) {
            if let tab = model.activeTab {
                FindSheet(model: model, tab: tab) { model.findOpen = false }
            }
        }
        .sheet(isPresented: $model.themeSheetOpen) {
            ThemeEditor(model: model, onDismiss: { model.themeSheetOpen = false })
        }
        // Nothing a linked project's skill does starts without passing through here.
        .sheet(item: $model.pendingRequest) { request in
            LinkedRunConfirm(model: model, request: request)
        }
        // Everything below reads the project's accent from here; nothing consults a
        // global, because a second window is showing a different project.
        .environment(\.studioTheme, model.theme)
        .onDisappear { model.stop() }
    }

    /// The sidebar width is dragged to size and persisted in `.cs/settings.json`.
    private var sidebarHandle: some View {
        Rectangle()
            .fill(draggingSidebar ? model.theme.accent : theme.separator.opacity(0.5))
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

            // "17 waiting" used to count every session that had handed the turn
            // back, which on a busy day was every session — and said nothing. It
            // counts what is actually on you now, and names the half that cannot be
            // cleared by looking.
            if model.attentionCount > 0 {
                HStack(spacing: 6) {
                    StatusDot(color: Theme.waiting)
                    Text(model.questionCount > 0
                         ? "\(model.questionCount) asking · \(model.attentionCount) unread"
                         : "\(model.attentionCount) unread")
                }
                .font(Theme.ui(11.5))
                .foregroundStyle(theme.text2)
                .help(model.questionCount > 0
                      ? "\(model.questionCount) session(s) are waiting on an answer; the rest have finished."
                      : "Finished turns you have not looked at yet.")
            }

            // "Start services" used to sit here, on every screen. It belongs where
            // the services are: the header of that pane, next to the per-service
            // buttons it is the plural of.
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

// MARK: - Tab bar

private struct TabBar: View {
    @ObservedObject var model: StudioModel
    @Environment(\.studioTheme) private var theme
    /// The tab whose title is being edited, by tab id.
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool
    /// The tab being dragged, for reordering.
    @State private var dragging: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(model.tabs) { tab in
                    item(tab)
                        .onDrag {
                            dragging = tab.id
                            return NSItemProvider(object: tab.id as NSString)
                        }
                        .onDrop(of: [.text], isTargeted: nil) { _ in
                            guard let source = dragging, source != tab.id else { return false }
                            model.moveTab(source, before: tab.id)
                            dragging = nil
                            return true
                        }
                }
                // Dropping past the last tab means "put it at the end" — without a
                // target there, a drag to the right of the row silently does nothing.
                Color.clear
                    .frame(width: 60, height: 34)
                    .onDrop(of: [.text], isTargeted: nil) { _ in
                        guard let source = dragging else { return false }
                        model.moveTabToEnd(source)
                        dragging = nil
                        return true
                    }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
        }
        .frame(height: 34)
        .background(theme.chrome)
    }

    private func item(_ tab: StudioTab) -> some View {
        let selected = model.activeTabID == tab.id
        let visible = selected || (model.splitPanes != nil && !model.splitMaximized
                                   && model.splitTabs?.contains(tab.id) == true)
        return HStack(spacing: 7) {
            TabKindIcon(kind: tab.kind)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(color: dotColor(tab), size: 5)
                        .background(Circle().fill(visible ? theme.surface : theme.chromeBase).padding(-1.5))
                        .offset(x: 2, y: 2)
                }
            if renaming == tab.id {
                // Focused as it appears, or the keystrokes go to the terminal below.
                TextField("session name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .foregroundStyle(theme.text)
                    .focused($renameFocused)
                    .frame(width: 130)
                    .onAppear { renameFocused = true }
                    .onSubmit { commitRename(tab) }
                    .onExitCommand { renaming = nil }
            } else {
                if model.sessionRecord(forTab: tab.id)?.saved == true {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(theme.accent)
                }
                Text(tab.title)
                    .font(Theme.ui(12))
                    .foregroundStyle(selected ? theme.text : theme.text2)
                    .lineLimit(1)
            }
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
        .frame(height: 30)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7, style: .continuous)
                .fill(visible ? theme.surface : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(tab) }
        .onTapGesture { model.activeTabID = tab.id }
        .contextMenu {
            if let record = model.sessionRecord(forTab: tab.id) {
                Button("Rename") { beginRename(tab) }
                Button(record.saved ? "Remove from saved" : "Save session") {
                    model.setSaved(record, saved: !record.saved)
                }
                Divider()
            }
            if model.activeTabID != tab.id {
                Button("Open in split") { model.openInSplit(tab.id) }
            }
            if model.splitTabs?.contains(tab.id) == true {
                Button("Close pane") { model.closePane(tab.id) }
            }
            Divider()
            Button("Close tab") { model.closeTab(id: tab.id) }
        }
    }

    /// Only a session carries a name of its own — every other tab is titled after
    /// the thing it shows (a skill, a service, a script), and renaming the tab
    /// would rename nothing.
    private func beginRename(_ tab: StudioTab) {
        guard let record = model.sessionRecord(forTab: tab.id) else { return }
        model.activeTabID = tab.id
        renameText = record.name
        renaming = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFocused = true }
    }

    private func commitRename(_ tab: StudioTab) {
        if let record = model.sessionRecord(forTab: tab.id) {
            model.renameSession(record, to: renameText)
        }
        renaming = nil
    }

    private func dotColor(_ tab: StudioTab) -> Color {
        switch tab.kind {
        case .session:
            switch model.engine.attention[tab.terminalKey] ?? .idle {
            case .working:        return Theme.running
            // A question and an unread finish are both on you; a finish you have
            // already looked at is not, and goes quiet.
            case .waiting, .done: return Theme.waiting
            case .seen, .idle:    return theme.idle
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
    @ObservedObject private var plan = PlanUsage.shared
    @Environment(\.studioTheme) private var theme
    @State private var waitingOpen = false

    var body: some View {
        HStack(spacing: 14) {
            if !plan.limits.isEmpty { planUsage }

            if let running = model.liveUsage.last?.usage {
                HStack(spacing: 5) {
                    StatusDot(color: theme.accent, size: 5)
                    Text("using \(running.display) · \(model.owner(of: running.name))")
                        .foregroundStyle(theme.text2)
                        .lineLimit(1)
                }
            }

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

            Spacer(minLength: 8)

            if !Tmux.isAvailable {
                Text("tmux missing — sessions are not persistent").foregroundStyle(Theme.danger)
            }
            if let next = model.store.nextRun {
                item("clock", "\(next.skill) · \(next.date.shortStamp)")
                    .help("Next scheduled run")
            }
            item("server.rack", "\(model.runningServiceCount)/\(model.store.config.services.count)")
                .help("Running services")
            item("terminal", "\(model.openSessions.count)")
                .help("Open sessions")
            if model.attentionCount > 0 {
                Button { waitingOpen.toggle() } label: {
                    HStack(spacing: 5) {
                        StatusDot(color: Theme.waiting, size: 5)
                        Text("\(model.attentionCount) needs you")
                            .foregroundStyle(Theme.waiting)
                    }
                }
                .buttonStyle(.plain)
                .help("Sessions waiting on you")
                .popover(isPresented: $waitingOpen, arrowEdge: .top) {
                    WaitingList(model: model) { waitingOpen = false }
                }
            }
        }
        .font(Theme.ui(11))
        .foregroundStyle(theme.text3)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(theme.chrome)
    }

    private var planUsage: some View {
        HStack(spacing: 8) {
            Text("Used").foregroundStyle(theme.text2)
            Image(systemName: "asterisk")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.accent)
            meter(plan.peak)
            HStack(spacing: 5) {
                ForEach(Array(plan.limits.enumerated()), id: \.element.id) { index, limit in
                    if index > 0 { Text("·").foregroundStyle(theme.text3) }
                    segment(limit)
                }
            }
        }
        .help(planHelp)
    }

    private func segment(_ limit: PlanUsage.Limit) -> some View {
        HStack(spacing: 4) {
            Text("\(limit.percent)%")
                .font(Theme.mono(10.5, .medium))
                .foregroundStyle(tone(limit.percent) ?? theme.text2)
            switch limit.kind {
            case .scoped(let name):
                Text(name)
            case .session, .weekly:
                if let left = limit.remaining() { Text(left).font(Theme.mono(10.5)) }
            }
        }
    }

    private func meter(_ percent: Int) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(theme.separator)
            Capsule()
                .fill(tone(percent) ?? theme.text2)
                .frame(width: max(3, 56 * CGFloat(min(100, percent)) / 100))
        }
        .frame(width: 56, height: 4)
    }

    private func tone(_ percent: Int) -> Color? {
        if percent >= 90 { return Theme.danger }
        if percent >= 70 { return Theme.warning }
        return nil
    }

    private var planHelp: String {
        var lines = plan.limits.map { limit in
            let left = limit.remaining().map { " · resets in \($0)" } ?? ""
            return "\(limit.title): \(limit.percent)%\(left)"
        }
        if let fetchedAt = plan.fetchedAt {
            lines.append("Updated \(fetchedAt.relative) by Claude Code")
        }
        return lines.joined(separator: "\n")
    }

    private func item(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .light))
            Text(text).font(Theme.mono(10.5))
        }
    }
}

private struct WaitingList: View {
    @ObservedObject var model: StudioModel
    let onDismiss: () -> Void
    @ObservedObject private var states = SessionStates.shared
    @State private var selected = 0

    private var rows: [(record: SessionRecord, live: SessionStates.Live?)] {
        let waiting = model.openSessions.filter { model.attention(of: $0).needsAttention }
        let questions = waiting.filter { model.attention(of: $0).isQuestion }
        return (questions + waiting.filter { !model.attention(of: $0).isQuestion }).map { record in
            (record, states.live.first { $0.key == record.tabKey })
        }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "needs you \(rows.count)", icon: "bell")
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.element.record.id) { index, row in
                Button { open(row.record) } label: {
                    HoverRow(selected: index == selected,
                             padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8), radius: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            let question = model.attention(of: row.record).isQuestion
                            Image(systemName: question ? "questionmark.circle" : "checkmark.circle")
                                .font(.system(size: 11, weight: .light))
                                .foregroundStyle(question ? Theme.waiting : model.theme.text3)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(row.record.name)
                                        .font(Theme.ui(12.5, .medium))
                                        .foregroundStyle(model.theme.text)
                                    Spacer(minLength: 8)
                                    if let at = row.live?.at {
                                        Text(at.relative)
                                            .font(Theme.ui(10.5))
                                            .foregroundStyle(model.theme.text3)
                                    }
                                }
                                Text(row.live?.headline ?? (question ? "Asking a question" : "Finished"))
                                    .font(Theme.ui(11.5))
                                    .foregroundStyle(model.theme.text2)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Text("↑↓ select · ↩ open · esc close")
                .font(Theme.ui(10.5))
                .foregroundStyle(model.theme.text3)
                .padding(.horizontal, 8)
                .padding(.top, 2)
        }
        .padding(8)
        .frame(width: 340)
        .environment(\.studioTheme, model.theme)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) {
            selected = min(selected + 1, max(rows.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selected = max(selected - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            if rows.indices.contains(selected) { open(rows[selected].record) }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private func open(_ record: SessionRecord) {
        model.openSession(record)
        onDismiss()
    }
}
