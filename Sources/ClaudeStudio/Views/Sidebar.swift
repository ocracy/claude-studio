import SwiftUI
import AppKit

/// Sidebar whose content follows the selected rail item.
struct Sidebar: View {
    @ObservedObject var model: StudioModel

    @State private var serviceSheet: Service?
    @State private var addingService = false
    @State private var commandSheet: ProjectCommand?
    @State private var addingCommand = false
    @State private var addMenu = false
    @State private var scheduleSheet: Schedule?
    @State private var sessionMenu = false
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
                    case .cron:      cronList
                    case .services:  servicesList
                    case .commands:  commandsList
                    case .terminals: terminalsList
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }

            footer
        }
        .frame(maxHeight: .infinity)
        .background(Theme.chrome)
        .sheet(item: $serviceSheet) { service in
            ServiceEditor(model: model, service: service, isNew: addingService) {
                serviceSheet = nil
                addingService = false
            }
        }
        .sheet(item: $scheduleSheet) { schedule in
            ScheduleEditor(model: model, schedule: schedule) { scheduleSheet = nil }
        }
        .sheet(item: $commandSheet) { command in
            CommandEditor(model: model, command: command, isNew: addingCommand) {
                commandSheet = nil
                addingCommand = false
            }
        }
        .sheet(isPresented: $sessionManager) {
            SessionManager(model: model) { sessionManager = false }
        }
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
                IconButton(icon: "plus", help: "New session / previous sessions") {
                    sessionMenu = true
                }
                .popover(isPresented: $sessionMenu, arrowEdge: .bottom) {
                    SessionOpener(model: model) { sessionMenu = false }
                }
            } else if model.pane == .services || model.pane == .commands {
                // One button, two things to create: a long-running service or a
                // one-shot command. They live in different panes but are added here.
                IconButton(icon: "plus", help: "Add a service or command") { addMenu = true }
                    .popover(isPresented: $addMenu, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 1) {
                            addMenuItem("New service", icon: "server.rack",
                                        detail: "long-running, port aware") {
                                addMenu = false
                                newService()
                            }
                            addMenuItem("New command", icon: "bolt",
                                        detail: "runs once in a tab") {
                                addMenu = false
                                newCommand()
                            }
                        }
                        .padding(6)
                        .frame(width: 250)
                    }
            } else {
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
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private var footerText: String {
        switch model.pane {
        case .sessions:  return "\(model.openSessions.count) open · \(model.pastSessions.count) previous"
        case .skills:    return "\(model.skills.skills.count) skills · .claude/skills"
        case .cron:      return "\(model.store.activeSchedules.count) active schedules"
        case .services:  return "\(model.runningServiceCount)/\(model.store.config.services.count) running"
        case .commands:  return "\(model.store.config.commands.count) commands"
        case .terminals: return "\(model.store.config.terminals.count) terminals"
        }
    }

    private var addHelp: String {
        switch model.pane {
        case .sessions:  return "New session"
        case .skills:    return "Create a new skill with Claude"
        case .cron:      return "Schedule a skill"
        case .services:  return "Add a service"
        case .commands:  return "Add a command"
        case .terminals: return "New terminal (⌘T)"
        }
    }

    private func add() {
        switch model.pane {
        case .sessions:
            model.newSession()
        case .skills:
            model.newSession(name: "new skill", prompt: newSkillPrompt, autoRun: true)
        case .cron:
            guard let first = model.skills.skills.first else { return }
            scheduleSheet = model.store.schedule(for: first.name) ?? Schedule(skill: first.name)
        case .services:
            newService()
        case .commands:
            newCommand()
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

    private func newCommand() {
        addingCommand = true
        commandSheet = ProjectCommand(name: "", command: "", cwd: model.project.path)
    }

    private func addMenuItem(_ title: String, icon: String, detail: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HoverRow(padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                        Text(detail).font(Theme.ui(10.5)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var newSkillPrompt: String {
        """
        Add a new Claude Code skill to this project: `.claude/skills/<name>/SKILL.md`.
        Ask me what it should do first, then write a short SKILL.md with `name` and
        `description` in its frontmatter.
        """
    }

    // MARK: - Sessions

    @ViewBuilder private var sessionsList: some View {
        if model.openSessions.isEmpty {
            emptyHint("No open sessions.", action: "Start a Claude session") { model.newSession() }
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
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Text("\(model.attention(of: record).label) · \(record.lastUsed.relative)")
                                .font(Theme.ui(10.5))
                                .foregroundStyle(Theme.text3)
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
                row(selected: false,
                    dot: Theme.idle,
                    title: record.name,
                    meta: model.canResume(record) ? "resumes conversation · \(record.lastUsed.relative)"
                                                  : "starts fresh · \(record.lastUsed.relative)",
                    action: { model.openSession(record) })
                    .contextMenu {
                        Button("Reopen") { model.openSession(record) }
                        Button("Delete record") { model.deleteSession(record) }
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
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent)))
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
        case .idle:    return Theme.idle
        }
    }

    // MARK: - Skills

    @ViewBuilder private var skillsList: some View {
        if model.skills.skills.isEmpty {
            emptyHint("`.claude/skills` is empty.", action: "Create a skill with Claude") {
                model.newSession(name: "new skill", prompt: newSkillPrompt, autoRun: true)
            }
        }
        ForEach(model.skills.skills) { skill in
            let schedule = model.store.schedule(for: skill.name)
            let last = model.runs.latest(for: skill.name)
            row(selected: model.activeTabID == "skill:\(skill.name)",
                dot: model.runs.isRunning(skill.name) ? Theme.running : (last?.status.color ?? Theme.idle),
                title: skill.name,
                meta: skillMeta(skill: skill, schedule: schedule, last: last),
                trailing: {
                    if skill.scope == .global {
                        Text("global")
                            .font(.system(size: 9.5))
                            .foregroundStyle(Theme.text3)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().strokeBorder(Theme.separator))
                    }
                    if schedule?.enabled == true {
                        Image(systemName: "clock").font(.system(size: 9.5))
                            .foregroundStyle(Theme.accent)
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
            row(selected: model.activeTabID == "cron:\(schedule.skill)",
                dot: schedule.enabled ? (last?.status.color ?? Theme.accent) : Theme.idle,
                title: schedule.skill,
                meta: schedule.enabled
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
                    Button("Run now") { model.runs.runInBackground(skill: schedule.skill) }
                    Divider()
                    Button("Delete schedule") { model.store.removeSchedule(skill: schedule.skill) }
                }
        }
    }

    // MARK: - Serviceler

    @ViewBuilder private var servicesList: some View {
        if model.store.config.services.isEmpty {
            emptyHint("No services defined.", action: "Add a service") {
                addingService = true
                serviceSheet = Service(name: "new service", command: "")
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
                    Divider()
                    Button("Delete service") {
                        model.engine.stopService(service)
                        model.store.removeService(service.id)
                    }
                }
        }
    }

    // MARK: - Commands

    @ViewBuilder private var commandsList: some View {
        if model.store.config.commands.isEmpty {
            emptyHint("No commands defined.", action: "Add a command", perform: newCommand)
        }
        ForEach(model.store.config.commands) { command in
            let key = "command:\(command.id.uuidString)"
            row(selected: model.activeTabID == key,
                dot: model.engine.isLive(key) ? Theme.running : Theme.idle,
                title: command.name,
                meta: command.command,
                trailing: {
                    IconButton(icon: "play.fill", help: "Run") { model.runCommand(command) }
                },
                action: { model.runCommand(command) })
                .contextMenu {
                    Button("Run") { model.runCommand(command) }
                    Button("Run in background") { model.runCommandInBackground(command) }
                    Button("Settings…") { commandSheet = command }
                    Divider()
                    Button("Delete command") { model.removeCommand(command) }
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
                dot: model.engine.isLive(key) ? Theme.running : Theme.idle,
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
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        if !meta.isEmpty {
                            Text(meta)
                                .font(Theme.ui(10.5))
                                .foregroundStyle(Theme.text3)
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

    private func emptyHint(_ text: String, action: String,
                           perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.text3)
            Button(action: perform) {
                Text(action).font(Theme.ui(11.5)).foregroundStyle(Theme.accent)
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
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.separator)))
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
                                            .foregroundStyle(Theme.text3)
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(record.name)
                                                .font(Theme.ui(12.5))
                                                .foregroundStyle(Theme.text)
                                            Text(model.canResume(record)
                                                 ? "resumes conversation · \(record.lastUsed.relative)"
                                                 : "starts fresh · \(record.lastUsed.relative)")
                                                .font(Theme.ui(10.5))
                                                .foregroundStyle(Theme.text3)
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
