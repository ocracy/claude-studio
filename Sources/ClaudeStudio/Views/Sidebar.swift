import SwiftUI
import AppKit

/// Sidebar whose content follows the selected rail item.
struct Sidebar: View {
    @ObservedObject var model: StudioModel
    @Environment(\.studioTheme) private var theme

    @State private var serviceSheet: Service?
    @State private var addingService = false
    @State private var scriptSheet: ProjectScript?
    @State private var addingScript = false
    @State private var mcpSheet: MCPServer?
    @State private var linkSheet = false
    @State private var editingLink: ProjectLink?
    @State private var mcpAddMenu = false
    @State private var scheduleSheet: Schedule?
    @State private var sessionMenu = false
    @State private var maker: MakerRequest?
    @State private var sessionManager = false
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var sessionFilter = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ProjectSwitcherButton(model: model)
            navigation
            header

            ScrollView {
                LazyVStack(spacing: 1) {
                    switch model.pane {
                    case .sessions:  sessionsList
                    case .skills:    skillsList
                    case .mcp:       mcpList
                    case .cron:      cronList
                    case .services:  servicesList
                    case .commands:  claudeCommandsList
                    case .scripts:   scriptsList
                    case .terminals: terminalsList
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }

            footer
        }
        .frame(maxHeight: .infinity)
        .background(theme.chrome)
        .onChange(of: model.pane) {
            if model.pane == .mcp { model.mcp.scan() }
            if model.pane == .commands { model.claudeCommands.scan(project: model.project) }
            // Ports move without the app: probe them the moment the list is looked
            // at, rather than leaving a service dark until the 4 s refresh.
            if model.pane == .services { model.engine.refreshExternalStatuses(model.store.config.services) }
        }
        .sheet(item: $serviceSheet) { service in
            ServiceEditor(model: model, service: service, isNew: addingService) {
                serviceSheet = nil
                addingService = false
            }
        }
        .sheet(item: $scheduleSheet) { schedule in
            ScheduleEditor(model: model, schedule: schedule) { scheduleSheet = nil }
        }
        .sheet(item: $scriptSheet) { script in
            ScriptEditor(model: model, script: script, isNew: addingScript) {
                scriptSheet = nil
                addingScript = false
            }
        }
        .sheet(item: $mcpSheet) { server in
            MCPEditor(model: model, server: server) { mcpSheet = nil }
        }
        .sheet(isPresented: $linkSheet) {
            LinkEditor(model: model) { linkSheet = false }
        }
        .sheet(item: $editingLink) { link in
            LinkEditor(model: model, onDismiss: { editingLink = nil }, editing: link)
        }
        .sheet(isPresented: $sessionManager) {
            SessionManager(model: model) { sessionManager = false }
        }
        .sheet(item: $maker) { request in
            ClaudeMaker(model: model, kind: request.kind,
                        service: request.service, script: request.script) { maker = nil }
        }
    }

    /// What the "with Claude" sheet was opened for: a whole list, or one entry.
    struct MakerRequest: Identifiable {
        let id = UUID()
        let kind: ClaudeMaker.Kind
        var service: Service?
        var script: ProjectScript?
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack(spacing: 2) {
            Text(model.pane.label)
                .font(Theme.ui(12.5, .medium))
                .foregroundStyle(theme.text2)
            Spacer()
            if model.pane == .sessions {
                IconButton(icon: "list.bullet.rectangle", help: "Session manager") {
                    sessionManager = true
                }
                IconButton(icon: "clock.arrow.circlepath",
                           help: "Claude conversations — search, read, resume") {
                    model.conversationsOpen = true
                }
                IconButton(icon: "plus", help: "New session / previous sessions") {
                    sessionMenu = true
                }
                .popover(isPresented: $sessionMenu, arrowEdge: .bottom) {
                    SessionOpener(model: model) { sessionMenu = false }
                }
            } else if model.pane == .mcp {
                IconButton(icon: "stethoscope", help: "Check connections") {
                    model.mcp.checkHealth()
                }
                IconButton(icon: "plus", help: "Add a server or link a project") {
                    mcpAddMenu = true
                }
                .popover(isPresented: $mcpAddMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        if !model.bridgeConnected {
                            addMenuItem("Connect this project", icon: "bolt.horizontal",
                                        detail: "let Claude read its services and runs") {
                                mcpAddMenu = false
                                model.connectBridge()
                            }
                        }
                        addMenuItem("Link a Claude project", icon: "link",
                                    detail: "share its skills, services and files") {
                            mcpAddMenu = false
                            linkSheet = true
                        }
                        addMenuItem("Add an MCP server", icon: "point.3.connected.trianglepath.dotted",
                                    detail: "stdio, HTTP or SSE") {
                            mcpAddMenu = false
                            mcpSheet = MCPServer(name: "", scope: .project, transport: .stdio)
                        }
                    }
                    .padding(6)
                    .frame(width: 280)
                }
            } else {
                // Services and scripts can be written by Claude instead of typed:
                // it reads the project and fills the file in. Its own button, next
                // to "+", because it is a different act — not a variant of adding
                // one by hand, and it works on the whole list at once.
                // The plural of the play button on each row, and it lives with them
                // rather than in the window header, where it was on screen in every
                // pane — including the ones that have nothing to do with services.
                if model.pane == .services, !model.store.config.services.isEmpty {
                    let anyRunning = model.runningServiceCount > 0
                    IconButton(icon: anyRunning ? "stop.circle" : "play.circle",
                               help: anyRunning ? "Stop all services" : "Start all services") {
                        anyRunning ? model.stopAllServices() : model.startAllServices()
                    }
                }
                if model.pane == .services || model.pane == .scripts {
                    IconButton(icon: "sparkles",
                               help: model.pane == .services
                                     ? "Write services with Claude"
                                     : "Write scripts with Claude") {
                        maker = MakerRequest(kind: model.pane == .services ? .services : .scripts)
                    }
                }
                IconButton(icon: "plus", help: addHelp, action: add)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var navigation: some View {
        VStack(spacing: 1) {
            Button { model.newSession() } label: {
                HoverRow(padding: EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8), radius: 6) {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .light))
                            .foregroundStyle(theme.text2)
                            .frame(width: 16)
                        Text("New session")
                            .font(Theme.ui(12.5))
                            .foregroundStyle(theme.text)
                        Spacer(minLength: 4)
                        Text("⌘N")
                            .font(Theme.ui(10.5))
                            .foregroundStyle(theme.text3)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)
            ForEach(StudioModel.orderedPanes) { pane in
                Button { model.pane = pane } label: {
                    HoverRow(selected: model.pane == pane,
                             padding: EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8),
                             radius: 6) {
                        HStack(spacing: 9) {
                            Image(systemName: pane.icon)
                                .font(.system(size: 13, weight: .light))
                                .foregroundStyle(model.pane == pane ? theme.text : theme.text3)
                                .frame(width: 16)
                            Text(pane.label)
                                .font(Theme.ui(12.5))
                                .foregroundStyle(model.pane == pane ? theme.text : theme.text2)
                            Spacer(minLength: 4)
                            navigationBadge(pane)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(pane.help)
                .contextMenu {
                    Button("Move up") { StudioModel.movePane(pane, by: -1) }
                    Button("Move down") { StudioModel.movePane(pane, by: 1) }
                    Divider()
                    Button("Reset order") { StudioModel.resetPaneOrder() }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
    }

    @ViewBuilder private func navigationBadge(_ pane: StudioModel.Pane) -> some View {
        switch pane {
        case .sessions where model.attentionCount > 0:
            HStack(spacing: 4) {
                StatusDot(color: Theme.waiting, size: 5)
                Text("\(model.attentionCount)")
            }
            .font(Theme.mono(10.5))
            .foregroundStyle(theme.text3)
        case .services where model.runningServiceCount > 0:
            HStack(spacing: 4) {
                StatusDot(color: Theme.running, size: 5)
                Text("\(model.runningServiceCount)")
            }
            .font(Theme.mono(10.5))
            .foregroundStyle(theme.text3)
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            IconButton(icon: "gearshape", help: "Settings (⌘,)") { SettingsWindow.show() }
            IconButton(icon: "paintpalette", help: "Appearance") { model.themeSheetOpen = true }
            Text(footerText)
                .font(Theme.ui(10.5))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
            Spacer()
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
    }

    private var footerText: String {
        switch model.pane {
        case .sessions:
            let saved = model.savedSessions.count
            let open = "\(model.openSessions.count) open"
            let previous = "\(model.pastSessions.count) previous"
            return saved > 0 ? "\(open) · \(saved) saved · \(previous)" : "\(open) · \(previous)"
        case .skills:    return "\(model.skills.skills.count) skills · .claude/skills"
        case .mcp:       return model.mcp.checkingHealth
                                ? "checking connections…"
                                : (model.bridgeConnected ? "connected · " : "not connected · ")
                                    + "\(model.links.count) links · \(otherServers.count) servers"
        case .cron:      return "\(model.store.activeSchedules.count) active schedules"
        case .services:  return "\(model.runningServiceCount)/\(model.store.config.services.count) running"
        case .commands:  return "\(model.claudeCommands.commands.count) commands · .claude/commands"
        case .scripts:   return "\(model.store.config.scripts.count) scripts"
        case .terminals: return "\(model.store.config.terminals.count) terminals"
        }
    }

    private var addHelp: String {
        switch model.pane {
        case .sessions:  return "New session"
        case .skills:    return "Create a new skill with Claude"
        case .mcp:       return "Add a server or link a project"
        case .cron:      return "Schedule a skill"
        case .services:  return "Add a service"
        case .commands:  return "Create a command with Claude"
        case .scripts:   return "Add a script"
        case .terminals: return "New terminal (⌘T)"
        }
    }

    private func add() {
        switch model.pane {
        case .sessions:
            model.newSession()
        case .skills:
            model.createSkillWithClaude()
        case .mcp:
            mcpAddMenu = true
        case .cron:
            guard let first = model.skills.skills.first else { return }
            scheduleSheet = model.store.schedule(for: first.name) ?? Schedule(skill: first.name)
        case .services:
            newService()
        case .commands:
            model.createCommandWithClaude()
        case .scripts:
            newScript()
        case .terminals:
            model.newTerminal()
        }
    }

    /// A new service starts out pointing at the project root, spelled out, so it
    /// is obvious what it will run in and easy to change.
    private func newService() {
        addingService = true
        serviceSheet = Service(name: "", command: "", cwd: model.project.path)
    }

    private func newScript() {
        addingScript = true
        scriptSheet = ProjectScript(name: "", command: "", cwd: model.project.path)
    }

    private func addMenuItem(_ title: String, icon: String, detail: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HoverRow(padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accent)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(Theme.ui(12.5)).foregroundStyle(theme.text)
                        Text(detail).font(Theme.ui(10.5)).foregroundStyle(theme.text3)
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
    }


    // MARK: - Sessions

    private var trimmedFilter: String { sessionFilter.trimmingCharacters(in: .whitespaces) }

    private func matches(_ record: SessionRecord) -> Bool {
        trimmedFilter.isEmpty
            || record.name.localizedCaseInsensitiveContains(trimmedFilter)
            || meta(for: record).localizedCaseInsensitiveContains(trimmedFilter)
    }

    private var sessionSearch: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.text3)
            TextField("Search sessions", text: $sessionFilter)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
            if !sessionFilter.isEmpty {
                Button { sessionFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.text3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.field))
        .padding(.horizontal, 2)
        .padding(.bottom, 8)
    }

    private struct StateGroup: Identifiable {
        var id: String { title }
        let title: String
        let urgent: Bool
        let records: [SessionRecord]
    }

    private func stateGroups(_ open: [SessionRecord]) -> [StateGroup] {
        let order: [(title: String, members: Set<Attention>)] = [
            ("needs you", [.waiting]), ("finished", [.done]), ("working", [.working]), ("ready", [.seen, .idle]),
        ]
        return order.compactMap { entry in
            let records = open.filter { entry.members.contains(model.attention(of: $0)) }
            return records.isEmpty ? nil
                : StateGroup(title: entry.title, urgent: entry.title == "needs you", records: records)
        }
    }

    @ViewBuilder private var sessionsList: some View {
        sessionSearch

        let open = model.openSessions.filter(matches)
        if model.openSessions.isEmpty {
            Text("No open sessions.")
                .font(Theme.ui(12))
                .foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
        } else if !open.isEmpty {
            VStack(spacing: 1) {
                HStack {
                    SectionLabel(text: "open \(open.count)", icon: "circle.dotted")
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 3)
                let groups = stateGroups(open)
                ForEach(groups) { group in
                    if groups.count > 1 {
                        Text("\(group.title) \(group.records.count)")
                            .font(Theme.ui(10.5, .medium))
                            .foregroundStyle(group.urgent ? Theme.waiting : theme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.top, group.id == groups.first?.id ? 0 : 6)
                            .padding(.bottom, 2)
                    }
                    ForEach(group.records) { record in
                        openSession(record)
                    }
                }
            }
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.hover.opacity(0.6))
            )
        }

        let saved = model.savedClosedSessions.filter(matches)
        if !saved.isEmpty {
            SectionLabel(text: "pinned \(saved.count)", icon: "pin")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(saved) { record in
                closedSession(record)
            }
        }

        let past = model.pastSessions.filter(matches).prefix(trimmedFilter.isEmpty ? 8 : 40)
        if !past.isEmpty {
            SectionLabel(text: "recent", icon: "clock")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(Array(past)) { record in
                closedSession(record)
            }
        }

        if !trimmedFilter.isEmpty && open.isEmpty && saved.isEmpty && past.isEmpty {
            Text("Nothing matches.")
                .font(Theme.ui(12))
                .foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
        }
    }

    @ViewBuilder private func openSession(_ record: SessionRecord) -> some View {
        if renaming == record.tmux {
            renameField(record)
        } else {
            let state = model.attention(of: record)
            HoverRow(selected: model.activeTabID == record.tabKey,
                     padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 4),
                     radius: 7) {
                HStack(alignment: .top, spacing: 8) {
                    statusGlyph(state)
                        .frame(width: 14, height: 15)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if record.saved {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(theme.accent)
                            }
                            Text(record.name)
                                .font(Theme.ui(12.5))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(trailingMeta(for: record))
                                .font(Theme.mono(10))
                                .foregroundStyle(theme.text3)
                                .lineLimit(1)
                                .fixedSize()
                            if state.needsAttention {
                                StatusDot(color: Theme.waiting, size: 6)
                                    .padding(.leading, 2)
                            }
                        }
                        HStack(spacing: 5) {
                            if let worktree = record.worktree {
                                worktreeChip(worktree)
                            }
                            Text(meta(for: record))
                                .font(Theme.ui(11))
                                .foregroundStyle(theme.text3)
                                .lineLimit(1)
                        }
                    }
                    IconButton(icon: "xmark", help: "Close session") {
                        model.closeSession(record)
                    }
                    .opacity(model.activeTabID == record.tabKey ? 1 : 0.55)
                }
            }
            .onTapGesture(count: 2) { beginRename(record) }
            .onTapGesture { model.openSession(record) }
            .contextMenu {
                Button("Rename") { beginRename(record) }
                Button(record.saved ? "Remove from saved" : "Save session") {
                    model.setSaved(record, saved: !record.saved)
                }
                Button("Close session") { model.closeSession(record) }
                Divider()
                Button("Delete record") { model.deleteSession(record) }
            }
        }
    }

    private func worktreeChip(_ name: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 8.5, weight: .regular))
            Text(name)
                .font(Theme.ui(10))
                .lineLimit(1)
        }
        .foregroundStyle(theme.text2)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(theme.hover))
        .fixedSize()
        .help("Runs in the worktree .claude/worktrees/\(name)")
    }

    @ViewBuilder private func statusGlyph(_ state: Attention) -> some View {
        switch state {
        case .working:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .tint(theme.accent)
        case .waiting:
            Image(systemName: "bell.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.waiting)
        case .done, .seen, .idle:
            Circle()
                .strokeBorder(theme.text3, style: StrokeStyle(lineWidth: 1, dash: state == .idle ? [1.5, 1.5] : []))
                .frame(width: 9, height: 9)
        }
    }

    private func trailingMeta(for record: SessionRecord) -> String {
        let age = record.lastUsed.compactAge
        guard let name = model.sessionDetails[record.tabKey]?.model else { return age }
        return "\(name.lowercased()) \(age)"
    }

    /// The line under an open session's name.
    ///
    /// When something is on you it says WHAT — the question Claude is holding, or
    /// the last thing it said. The bare state was true of every row at once
    /// ("waiting", eighteen times) and so distinguished nothing.
    private func meta(for record: SessionRecord) -> String {
        let state = model.attention(of: record)
        if state.needsAttention || state == .working,
           let headline = SessionStates.shared.live
            .first(where: { $0.key == record.tabKey })?.headline {
            return headline
        }
        return state.label
    }

    /// A session with no tab: saved, or simply previous.
    ///
    /// Built by hand rather than through `row`, for the same reason an open
    /// session is: `row` is a Button, and a Button takes the first click of a
    /// double click as one more press — the session would reopen instead of the
    /// field appearing. A name matters MORE here than above: this list is what is
    /// left of a conversation once its tab is gone, and "claude" three times over
    /// says nothing.
    @ViewBuilder private func closedSession(_ record: SessionRecord) -> some View {
        if renaming == record.tmux {
            renameField(record)
        } else {
            HoverRow(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 6)) {
                HStack(spacing: 8) {
                    statusGlyph(.idle)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if record.saved {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(theme.accent)
                            }
                            Text(record.name)
                                .font(Theme.ui(12.5))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: model.canResume(record) ? "arrow.uturn.backward" : "sparkle")
                                .font(.system(size: 9, weight: .light))
                            Text(record.lastUsed.relative)
                                .font(Theme.ui(10.5))
                                .lineLimit(1)
                        }
                        .foregroundStyle(theme.text3)
                        .help(model.canResume(record) ? "Resumes the conversation" : "Starts fresh")
                    }
                    Spacer(minLength: 4)
                }
            }
            .onTapGesture(count: 2) { beginRename(record) }
            .onTapGesture { model.openSession(record) }
            .contextMenu {
                Button("Reopen") { model.openSession(record) }
                Button("Rename") { beginRename(record) }
                Button(record.saved ? "Remove from saved" : "Save session") {
                    model.setSaved(record, saved: !record.saved)
                }
                Divider()
                Button("Delete record") { model.deleteSession(record) }
            }
        }
    }

    private func beginRename(_ record: SessionRecord) {
        renameText = record.name
        renaming = record.tmux
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFocused = true }
    }

    /// Focuses as soon as it appears; otherwise keystrokes go to the terminal.
    private func renameField(_ record: SessionRecord) -> some View {
        TextField("session name", text: $renameText)
            .textFieldStyle(.plain)
            .font(Theme.ui(12.5))
            .focused($renameFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.field)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.accent)))
            .onAppear { renameFocused = true }
            .onSubmit {
                model.renameSession(record, to: renameText)
                renaming = nil
            }
            .onExitCommand { renaming = nil }
    }

    private func color(for state: Attention) -> Color {
        switch state {
        case .working:        return Theme.running
        case .waiting, .done: return Theme.waiting
        case .seen, .idle:    return theme.idle
        }
    }

    // MARK: - Skills

    @ViewBuilder private var skillsList: some View {
        if model.skills.skills.isEmpty {
            emptyHint("`.claude/skills` is empty.", action: "Create a skill with Claude",
                      perform: model.createSkillWithClaude)
        }
        ForEach(model.skills.skills) { skill in
            let schedule = model.store.schedule(for: skill.name)
            let last = model.runs.latest(for: skill.name)
            let inUse = model.liveUsage.contains { $0.usage.name == skill.name }
            row(selected: model.activeTabID == "skill:\(skill.name)",
                dot: inUse ? theme.accent
                     : model.runs.isRunning(skill.name) ? Theme.running
                     : (last?.status.color ?? theme.idle),
                title: skill.name,
                meta: skillMeta(skill: skill, schedule: schedule, last: last),
                trailing: {
                    if skill.scope == .global {
                        Text("global")
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.text3)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().strokeBorder(theme.separator))
                    }
                    if schedule?.enabled == true {
                        Image(systemName: "clock").font(.system(size: 9.5))
                            .foregroundStyle(theme.accent)
                    }
                },
                action: { model.openSkill(skill) })
                .contextMenu {
                    Button("Run in a session") { model.runSkillVisible(skill) }
                    Button("Run in background") { model.runSkillBackground(skill) }
                    Divider()
                    Button("Schedule…") {
                        scheduleSheet = model.store.schedule(for: skill.name) ?? Schedule(skill: skill.name)
                    }
                    Button("Open SKILL.md") { NSWorkspace.shared.open(skill.url) }
                }
        }
    }

    private func skillMeta(skill: Skill, schedule: Schedule?, last: SkillRun?) -> String {
        if model.runs.isRunning(skill.name) { return "running…" }
        var parts: [String] = []
        if let schedule, schedule.enabled { parts.append(schedule.summary) }
        if let last, let at = last.startedAt { parts.append(at.relative) }
        if parts.isEmpty, let description = skill.description { return description }
        return parts.joined(separator: " · ")
    }

    // MARK: - Schedulelar

    @ViewBuilder private var cronList: some View {
        if model.store.config.schedules.isEmpty {
            emptyHint("No scheduled runs.", action: "Schedule a skill") {
                guard let first = model.skills.skills.first else { return }
                scheduleSheet = Schedule(skill: first.name)
            }
        }
        ForEach(model.store.config.schedules) { schedule in
            let last = model.runs.latest(for: schedule.skill)
            let running = model.runs.isRunning(schedule.skill)
            row(selected: model.activeTabID == "cron:\(schedule.skill)",
                dot: running ? Theme.running
                     : schedule.enabled ? (last?.status.color ?? theme.accent) : theme.idle,
                title: schedule.skill,
                // A run in flight replaces the schedule summary: what it is doing now
                // matters more than when it will do it next.
                meta: running ? "running now…"
                      : schedule.enabled
                      ? "\(schedule.summary) · next \(schedule.nextFire?.shortStamp ?? "—")"
                      : "paused",
                trailing: {
                    IconButton(icon: schedule.enabled ? "pause" : "play",
                               help: schedule.enabled ? "Pause" : "Resume") {
                        var updated = schedule
                        updated.enabled.toggle()
                        model.store.setSchedule(updated)
                    }
                },
                action: { model.openCron(schedule) })
                .contextMenu {
                    Button("Edit…") { scheduleSheet = schedule }
                    Button("Run now") { model.runSkillNow(schedule.skill) }
                    Button("Run now in background") {
                        model.runs.runInBackground(skill: schedule.skill)
                    }
                    Divider()
                    Button("Delete schedule") { model.store.removeSchedule(skill: schedule.skill) }
                }
        }
    }

    // MARK: - Serviceler

    @ViewBuilder private var servicesList: some View {
        if model.store.config.services.isEmpty {
            emptyHint("No services defined.", action: "Let Claude find them") {
                maker = MakerRequest(kind: .services)
            }
        }
        ForEach(model.store.config.services) { service in
            let status = model.engine.serviceStatus[service.id] ?? .stopped
            row(selected: model.activeTabID == "service:\(service.id.uuidString)",
                dot: status.color,
                title: service.name,
                meta: [status.label, service.port.map { ":\($0)" }]
                        .compactMap { $0 }.joined(separator: " · "),
                trailing: {
                    IconButton(icon: status.isLive ? "stop.fill" : "play.fill",
                               help: status.isLive ? "Stop" : "Start") {
                        model.toggleService(service)
                    }
                },
                action: {
                    model.openService(service)
                    if !status.isLive { model.engine.startService(service, project: model.project) }
                })
                .contextMenu {
                    Button("Restart") { model.engine.restartService(service, project: model.project) }
                    Button("Settings…") { serviceSheet = service }
                    Button("Update with Claude…") {
                        maker = MakerRequest(kind: .services, service: service)
                    }
                    Divider()
                    Button("Delete service") {
                        model.engine.stopService(service)
                        model.store.removeService(service.id)
                    }
                }
        }
    }

    // MARK: - MCP servers

    /// Everything except our own bridge, which has a row of its own at the top —
    /// listed twice it would read as two connections, and "Remove" on the generic
    /// row would take the pane's own switch away from under it.
    private var otherServers: [MCPServer] {
        model.mcp.servers.filter { $0.name != ProjectBridge.serverName }
    }

    @ViewBuilder private var mcpList: some View {
        SectionLabel(text: "this project")
            .padding(.horizontal, 8)
            .padding(.top, 2)
            .padding(.bottom, 4)
        bridgeRow

        if !model.links.isEmpty {
            SectionLabel(text: "linked projects")
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 4)
            ForEach(model.links) { link in
                row(selected: false,
                    dot: link.exists ? (link.allowEdits ? theme.accent : Theme.running)
                                     : Theme.danger,
                    title: link.name,
                    meta: link.exists ? link.displayPath : "missing · \(link.displayPath)",
                    trailing: {
                        Text(link.allowEdits ? "edits" : "read-only")
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.text3)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().strokeBorder(theme.separator))
                    },
                    action: { WindowManager.shared.open(project: Project(path: link.path)) })
                    .contextMenu {
                        Button("Edit link…") { editingLink = link }
                        Button(link.allowEdits ? "Make read-only" : "Allow edits") {
                            model.setLinkEdits(link, allowed: !link.allowEdits)
                        }
                        Button("Open in a new window") {
                            WindowManager.shared.open(project: Project(path: link.path))
                        }
                        Divider()
                        Button("Unlink") { model.unlink(link) }
                    }

                // A linked project's skills are kept out of the session's skill list
                // on purpose, so this is where they can be reached at all. Indented
                // under their project, because which project a deploy acts on is the
                // only thing about it worth knowing at a glance.
                ForEach(model.skills(of: link), id: \.name) { skill in
                    Button { model.askToRun(skill: skill.name, of: link) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.text3)
                            Text(skill.name)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(theme.text2)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 26).padding(.trailing, 8).padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(skill.description ?? "Run \(skill.name) in \(link.name)")
                }
            }

        }

        if model.links.isEmpty {
            emptyHint(model.bridgeConnected
                        ? "No other project is linked."
                        : "Link another project to reach its skills and files.",
                      action: "Link a Claude project") {
                linkSheet = true
            }
        }

        if !otherServers.isEmpty {
            SectionLabel(text: "mcp servers")
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
        }
        ForEach(otherServers) { server in
            row(selected: false,
                dot: server.health.color,
                title: server.name,
                meta: server.detail,
                trailing: {
                    Text(server.scope.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.text3)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().strokeBorder(theme.separator))
                        .help(server.scope.help)
                },
                action: { mcpSheet = server })
                .contextMenu {
                    Button("Details") {
                        model.runMCPCommand("get \(Shell.quoted(server.name))",
                                            title: "mcp: \(server.name)")
                    }
                    if server.transport != .stdio {
                        Button("Sign in") {
                            model.runMCPCommand("login \(Shell.quoted(server.name))",
                                                title: "mcp login: \(server.name)")
                        }
                    }
                    Button("Check connections") { model.mcp.checkHealth() }
                    Divider()
                    Button("Remove") { model.mcp.remove(server) }
                }
        }
    }

    // MARK: - Claude commands

    @ViewBuilder private var claudeCommandsList: some View {
        if model.claudeCommands.commands.isEmpty {
            emptyHint("`.claude/commands` is empty.", action: "Create a command with Claude",
                      perform: model.createCommandWithClaude)
        }
        ForEach(model.claudeCommands.commands) { command in
            let inUse = model.liveUsage.contains { $0.usage.name == command.name }
            row(selected: model.activeTabID == "command:\(command.name)",
                dot: inUse ? theme.accent : theme.accent.opacity(0.4),
                title: command.invocation,
                meta: command.description ?? command.argumentHint ?? "",
                trailing: {
                    if command.scope == .global {
                        Text("global")
                            .font(.system(size: 9.5))
                            .foregroundStyle(theme.text3)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().strokeBorder(theme.separator))
                    }
                    IconButton(icon: "play.fill", help: "Run in a session") {
                        model.runClaudeCommand(command)
                    }
                },
                action: { model.openClaudeCommand(command) })
                .contextMenu {
                    Button("Run in a session") { model.runClaudeCommand(command) }
                    Button("Open file") { NSWorkspace.shared.open(command.url) }
                }
        }
    }

    // MARK: - Scripts

    @ViewBuilder private var scriptsList: some View {
        if model.store.config.scripts.isEmpty {
            emptyHint("No scripts defined.", action: "Let Claude find them") {
                maker = MakerRequest(kind: .scripts)
            }
        }
        ForEach(model.store.config.scripts) { script in
            let key = "script:\(script.id.uuidString)"
            row(selected: model.activeTabID == key,
                dot: model.engine.isLive(key) ? Theme.running : theme.idle,
                title: script.name,
                meta: script.command,
                trailing: {
                    IconButton(icon: "play.fill", help: "Run") { model.runScript(script) }
                },
                action: { model.runScript(script) })
                .contextMenu {
                    Button("Run") { model.runScript(script) }
                    Button("Run in background") { model.runScriptInBackground(script) }
                    Button("Settings…") { scriptSheet = script }
                    Button("Update with Claude…") {
                        maker = MakerRequest(kind: .scripts, script: script)
                    }
                    Divider()
                    Button("Delete script") { model.removeScript(script) }
                }
        }
    }

    // MARK: - Terminals

    @ViewBuilder private var terminalsList: some View {
        if model.store.config.terminals.isEmpty {
            emptyHint("No terminals.", action: "Open a terminal") { model.newTerminal() }
        }
        ForEach(model.store.config.terminals) { terminal in
            let key = "terminal:\(terminal.id.uuidString)"
            row(selected: model.activeTabID == key,
                dot: model.engine.isLive(key) ? Theme.running : theme.idle,
                title: terminal.name,
                meta: terminal.cwd.nilIfEmpty ?? model.project.displayPath,
                action: { model.openTerminal(terminal) })
                .contextMenu {
                    Button("Close and delete") { model.removeTerminal(terminal) }
                }
        }
    }

    // MARK: - Shared row

    private func row<Trailing: View>(
        selected: Bool, dot: Color, title: String, meta: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HoverRow(selected: selected,
                     padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 6)) {
                HStack(spacing: 8) {
                    StatusDot(color: dot)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(Theme.ui(12.5))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        if !meta.isEmpty {
                            Text(meta)
                                .font(Theme.ui(10.5))
                                .foregroundStyle(theme.text3)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    trailing()
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// The switch for Claude Studio's own MCP server.
    ///
    /// It sits at the top of the pane, before the links, because what it gives a
    /// session first is a view of THIS project — the services, terminals and skill
    /// runs it is sitting in. Reaching another project is the second thing it does,
    /// and used to be the only way to get the first.
    @ViewBuilder private var bridgeRow: some View {
        let connected = model.bridgeConnected
        row(selected: false,
            dot: connected ? (model.bridgeServer?.health.color ?? Theme.running) : Theme.idle,
            title: model.project.name,
            meta: model.bridgeConnecting
                ? "connecting…"
                : (connected
                    ? "services, terminals and skill runs are readable"
                    : "let Claude see what this project is running"),
            trailing: {
                if connected {
                    Text("connected")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.text3)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().strokeBorder(theme.separator))
                } else if !model.bridgeConnecting {
                    SmallButton(title: "Connect") { model.connectBridge() }
                }
            },
            action: { if !connected { model.connectBridge() } })
            .help(connected
                  ? "Claude Studio's MCP server is registered for \(model.project.name). "
                    + "A session started before this needs reopening to see it."
                  : "Registers Claude Studio's MCP server for this project, so a session "
                    + "can read its services, terminals and skill runs — and reach any "
                    + "project you link.")
            .contextMenu {
                if connected {
                    Button("Check connections") { model.mcp.checkHealth() }
                    Divider()
                    Button("Disconnect") { model.disconnectBridge() }
                } else {
                    Button("Connect this project") { model.connectBridge() }
                }
            }
    }

    private func emptyHint(_ text: String, action: String,
                           perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(Theme.ui(12)).foregroundStyle(theme.text3)
            Button(action: perform) {
                Text(action).font(Theme.ui(11.5)).foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
    }
}

// MARK: - New / previous session opener

/// The list behind the "+" button: start a new session, or bring a closed one
/// back under the same name.
private struct SessionOpener: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let onDismiss: () -> Void
    @State private var name = ""
    @State private var inWorktree = false
    /// Focused as the popover appears. Without it the field looked ready to type
    /// into and was not: Enter went nowhere, and "+ , Enter" — the fastest way to
    /// start an unnamed session, and the one everybody reaches for — did nothing
    /// at all until the field had been clicked first.
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "new session")
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

            HStack(spacing: 6) {
                TextField("session name (optional)", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12.5))
                    .focused($focused)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(focused ? theme.accent : theme.separator)))
                    .onSubmit(create)
                SmallButton(title: "Open", prominent: true, action: create)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            Toggle(isOn: $inWorktree) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("In a new worktree").font(Theme.ui(12)).foregroundStyle(theme.text)
                    Text("Its own branch and folder, so parallel sessions never touch the same files.")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 6)

            Text("Leave the name empty and Claude names the session itself.")
                .font(Theme.ui(10))
                .foregroundStyle(theme.text3)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            // Saved first and in full: that is what saving one is for.
            if !model.savedClosedSessions.isEmpty {
                Divider()
                section("saved", records: model.savedClosedSessions, icon: "bookmark.fill")
            }
            if !model.pastSessions.isEmpty {
                Divider()
                section("previous sessions", records: Array(model.pastSessions.prefix(12)),
                        icon: nil)
            }
        }
        .frame(width: 340)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
    }

    private func section(_ title: String, records: [SessionRecord],
                         icon: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: title)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(records) { record in
                        Button {
                            model.openSession(record)
                            onDismiss()
                        } label: {
                            row(record, icon: icon)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(record.saved ? "Remove from saved" : "Save session") {
                                model.setSaved(record, saved: !record.saved)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: records.count > 5 ? 220 : CGFloat(records.count) * 44 + 8)
        }
    }

    private func row(_ record: SessionRecord, icon: String?) -> some View {
        HoverRow(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)) {
            HStack(spacing: 8) {
                Image(systemName: icon
                      ?? (model.canResume(record) ? "arrow.uturn.backward" : "bubble.left"))
                    .font(.system(size: 10))
                    .foregroundStyle(icon == nil ? theme.text3 : theme.accent)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name)
                        .font(Theme.ui(12.5))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    // A saved session outlives the machine being on: reopening it
                    // resumes the same conversation, and the row says which of the
                    // two it will do before it is pressed.
                    Text(model.canResume(record)
                         ? "resumes conversation · \(record.lastUsed.relative)"
                         : "starts fresh · \(record.lastUsed.relative)")
                        .font(Theme.ui(10.5))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
        }
    }

    private func create() {
        model.newSession(name: name.nilIfEmpty, worktree: inWorktree ? worktreeName : nil)
        onDismiss()
    }

    private var worktreeName: String {
        let slug = String((name.nilIfEmpty ?? "")
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            .split(separator: "-")
            .joined(separator: "-")
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return slug.isEmpty ? "session-\(suffix)" : "\(slug.prefix(40))-\(suffix)"
    }
}

