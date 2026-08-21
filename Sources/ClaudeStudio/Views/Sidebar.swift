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
    @State private var transcriptMenu = false
    @State private var maker: MakerRequest?
    @State private var sessionManager = false
    @State private var renaming: String?
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
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
            SectionLabel(text: model.pane.title)
            Spacer()
            if model.pane == .sessions {
                IconButton(icon: "list.bullet.rectangle", help: "Session manager") {
                    sessionManager = true
                }
                IconButton(icon: "clock.arrow.circlepath",
                           help: "Claude conversations — resume one") {
                    transcriptMenu = true
                }
                .popover(isPresented: $transcriptMenu, arrowEdge: .bottom) {
                    TranscriptOpener(model: model) { transcriptMenu = false }
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
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(Theme.mono(10.5))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 1) }
    }

    private var footerText: String {
        switch model.pane {
        case .sessions:  return "\(model.openSessions.count) open · \(model.pastSessions.count) previous"
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

    @ViewBuilder private var sessionsList: some View {
        if model.openSessions.isEmpty {
            // No call to action: "+" sits right above, and repeating it here only
            // made the pane look emptier than it is.
            Text("No open sessions.")
                .font(Theme.ui(12))
                .foregroundStyle(theme.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
        }
        ForEach(model.openSessions) { record in
            if renaming == record.tmux {
                renameField(record)
            } else {
                // Single click opens, double click renames — the Finder/VS Code reflex.
                HoverRow(selected: model.activeTabID == record.tabKey,
                         padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 6)) {
                    HStack(spacing: 8) {
                        StatusDot(color: color(for: model.attention(of: record)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.name)
                                .font(Theme.ui(12.5))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Text("\(model.attention(of: record).label) · \(record.lastUsed.relative)")
                                .font(Theme.ui(10.5))
                                .foregroundStyle(theme.text3)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        IconButton(icon: "xmark", help: "Close session") {
                            model.closeSession(record)
                        }
                    }
                }
                .onTapGesture(count: 2) { beginRename(record) }
                .onTapGesture { model.openSession(record) }
                .contextMenu {
                    Button("Rename") { beginRename(record) }
                    Button("Close session") { model.closeSession(record) }
                    Divider()
                    Button("Delete record") { model.deleteSession(record) }
                }
            }
        }

        if !model.pastSessions.isEmpty {
            SectionLabel(text: "previous sessions")
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(model.pastSessions.prefix(8)) { record in
                if renaming == record.tmux {
                    renameField(record)
                } else {
                    // Built by hand rather than through `row`, for the same reason an
                    // open session is: `row` is a Button, and a Button takes the first
                    // click of a double click as one more press — the session would
                    // reopen instead of the field appearing. A name matters MORE here
                    // than above: this list is what is left of a conversation once its
                    // tab is gone, and "claude" three times over says nothing.
                    HoverRow(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 6)) {
                        HStack(spacing: 8) {
                            StatusDot(color: theme.idle)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.name)
                                    .font(Theme.ui(12.5))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
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
                    .onTapGesture(count: 2) { beginRename(record) }
                    .onTapGesture { model.openSession(record) }
                    .contextMenu {
                        Button("Reopen") { model.openSession(record) }
                        Button("Rename") { beginRename(record) }
                        Divider()
                        Button("Delete record") { model.deleteSession(record) }
                    }
                }
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
        case .working: return Theme.running
        case .waiting: return Theme.waiting
        case .idle:    return theme.idle
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "new session")
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

            HStack(spacing: 6) {
                TextField("session name (optional)", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12.5))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.separator)))
                    .onSubmit(create)
                SmallButton(title: "Open", prominent: true, action: create)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            if !model.pastSessions.isEmpty {
                Divider()
                SectionLabel(text: "previous sessions")
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.pastSessions.prefix(12)) { record in
                            Button {
                                model.openSession(record)
                                onDismiss()
                            } label: {
                                HoverRow(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)) {
                                    HStack(spacing: 8) {
                                        Image(systemName: model.canResume(record)
                                              ? "arrow.uturn.backward" : "bubble.left")
                                            .font(.system(size: 10))
                                            .foregroundStyle(theme.text3)
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(record.name)
                                                .font(Theme.ui(12.5))
                                                .foregroundStyle(theme.text)
                                            Text(model.canResume(record)
                                                 ? "resumes conversation · \(record.lastUsed.relative)"
                                                 : "starts fresh · \(record.lastUsed.relative)")
                                                .font(Theme.ui(10.5))
                                                .foregroundStyle(theme.text3)
                                        }
                                        Spacer()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 320)
    }

    private func create() {
        model.newSession(name: name.nilIfEmpty)
        onDismiss()
    }
}

// MARK: - Claude's own conversations

/// Claude Code's transcripts for this project, straight off disk — including
/// conversations that were never started from Claude Studio. Picking one resumes
/// it (`claude --resume <sid>`) in a session of its own.
private struct TranscriptOpener: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let onDismiss: () -> Void
    @State private var transcripts: [ClaudeTranscripts.Transcript] = []
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "claude conversations")
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)

            if loading {
                Text("Reading transcripts…")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(theme.text3)
                    .padding(.horizontal, 10).padding(.vertical, 12)
            } else if transcripts.isEmpty {
                Text("Claude has not recorded a conversation in this project yet.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(theme.text3)
                    .padding(.horizontal, 10).padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(transcripts) { transcript in
                            Button {
                                model.resumeTranscript(transcript)
                                onDismiss()
                            } label: {
                                row(transcript)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 360)
        .onAppear {
            // Reading dozens of transcript heads is disk work, not UI work — the
            // path is taken here so the detached task never touches the model.
            let path = model.project.path
            Task.detached(priority: .userInitiated) {
                let found = ClaudeTranscripts.list(projectPath: path)
                await MainActor.run {
                    transcripts = found
                    loading = false
                }
            }
        }
    }

    private func row(_ transcript: ClaudeTranscripts.Transcript) -> some View {
        let live = model.sessions.first { $0.claudeSID == transcript.id }
            .map { model.isOpen($0) } ?? false
        return HoverRow(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)) {
            HStack(spacing: 8) {
                Image(systemName: live ? "bubble.left.fill" : "arrow.uturn.backward")
                    .font(.system(size: 10))
                    .foregroundStyle(live ? Theme.running : theme.text3)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transcript.title)
                        .font(Theme.ui(12.5))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text("\(live ? "open" : "resume") · \(transcript.modified.relative) · \(transcript.id.prefix(8))")
                        .font(Theme.mono(10))
                        .foregroundStyle(theme.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
        }
    }
}
