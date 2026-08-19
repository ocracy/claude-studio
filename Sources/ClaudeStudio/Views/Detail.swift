import SwiftUI
import AppKit

/// Content by tab kind: terminal, skill card or run history.
struct ContentArea: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    var body: some View {
        Group {
            if let tab = model.activeTab {
                content(for: tab)
            } else {
                EmptyStudio(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface)
    }

    @ViewBuilder
    private func content(for tab: StudioTab) -> some View {
        switch tab.kind {
        case .session, .terminal, .service, .script:
            TerminalPane(model: model, tab: tab)
        case .command:
            if let command = model.claudeCommands.command(named: tab.ref) {
                ClaudeCommandPane(model: model, command: command)
            } else {
                message("Command not found: \(tab.ref)")
            }
        case .skill:
            if let skill = model.skills.skill(named: tab.ref) {
                SkillPane(model: model, skill: skill)
            } else {
                message("Skill not found: \(tab.ref)")
            }
        case .cron:
            if let schedule = model.store.schedule(for: tab.ref) {
                CronPane(model: model, schedule: schedule)
            } else {
                message("Schedule removed: \(tab.ref)")
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(12.5))
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty state

private struct EmptyStudio: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(theme.text3)
            Text("Pick a session, skill, schedule, service or terminal on the left")
                .font(Theme.ui(12.5))
                .foregroundStyle(theme.text3)
            HStack(spacing: 8) {
                SmallButton(title: "Claude session", icon: "plus", prominent: true) {
                    model.newSession()
                }
                SmallButton(title: "Terminal", icon: "plus") { model.newTerminal() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Terminal

private struct TerminalPane: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let tab: StudioTab
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if tab.kind == .session, model.sessionNeedsReopen(tab.terminalKey) {
                linkNotice
            }
            TerminalHost(key: tab.terminalKey, engine: model.engine)
        }
    }

    /// A session reads its working directories once, at startup. When the links change
    /// underneath it the honest thing is to say so and offer the one-click fix.
    private var linkNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 10))
                .foregroundStyle(theme.accent)
            Text("Project links changed — reopen this session to apply them.")
                .font(Theme.ui(11.5))
                .foregroundStyle(theme.text2)
            Spacer()
            SmallButton(title: "Reopen", prominent: true) {
                model.reopenSession(tmux: tab.ref)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if editingTitle {
                // The field must take focus the moment it appears; otherwise your
                // keystrokes go to the terminal and renaming "does not work".
                TextField("name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(13, .medium))
                    .frame(maxWidth: 260)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.accent)))
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editingTitle = false }
                    .onAppear { titleFocused = true }
            } else {
                // Double-click the title to rename; the tmux session is recorded
                // under that name.
                Text(tab.title)
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: beginRename)
                    .help(renameable ? "Double-click to rename" : "")
            }

            HStack(spacing: 5) {
                StatusDot(color: stateColor)
                Text(state).font(Theme.ui(11)).foregroundStyle(theme.text3)
            }

            if let running = model.liveUsage(forTab: tab.terminalKey) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 9.5))
                        .foregroundStyle(theme.accent)
                    Text("\(running.display) · \(model.owner(of: running.name))")
                        .font(Theme.ui(11))
                        .foregroundStyle(theme.text2)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.field))
            }

            Spacer(minLength: 8)

            Text(meta)
                .font(Theme.mono(10.5))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
                .truncationMode(.head)

            actions
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
    }

    @ViewBuilder private var actions: some View {
        switch tab.kind {
        case .service:
            if let service = serviceValue {
                let live = (model.engine.serviceStatus[service.id] ?? .stopped).isLive
                SmallButton(title: live ? "Stop" : "Start",
                            icon: live ? "stop.fill" : "play.fill") { model.toggleService(service) }
                IconButton(icon: "arrow.clockwise", help: "Restart") {
                    model.engine.restartService(service, project: model.project)
                }
            }
        case .session:
            IconButton(icon: "pencil", help: "Rename", action: beginRename)
            IconButton(icon: "xmark.circle", help: "Close session") {
                model.closeTab(id: tab.id)
            }
        case .terminal:
            IconButton(icon: "pencil", help: "Rename", action: beginRename)
            IconButton(icon: "clear", help: "Clear screen") {
                model.engine.clear(key: tab.terminalKey)
            }
        case .script:
            if let script = scriptValue {
                SmallButton(title: model.engine.isLive(tab.terminalKey) ? "Running…" : "Run again",
                            icon: "play.fill",
                            prominent: !model.engine.isLive(tab.terminalKey)) {
                    model.runScript(script)
                }
                IconButton(icon: "clear", help: "Clear screen") {
                    model.engine.clear(key: tab.terminalKey)
                }
            }
        default:
            EmptyView()
        }
    }

    private var renameable: Bool { tab.kind == .session || tab.kind == .terminal }

    private func beginRename() {
        guard renameable else { return }
        draftTitle = tab.title
        editingTitle = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { titleFocused = true }
    }

    private func commitRename() {
        editingTitle = false
        switch tab.kind {
        case .session:
            guard let record = model.store.session(tmux: tab.ref) else { return }
            model.renameSession(record, to: draftTitle)
        case .terminal:
            guard let id = UUID(uuidString: tab.ref), let terminal = model.store.terminal(id)
            else { return }
            model.renameTerminal(terminal, to: draftTitle)
        default:
            break
        }
    }

    private var scriptValue: ProjectScript? {
        guard tab.kind == .script, let id = UUID(uuidString: tab.ref) else { return nil }
        return model.store.script(id)
    }

    private var serviceValue: Service? {
        guard tab.kind == .service, let id = UUID(uuidString: tab.ref) else { return nil }
        return model.store.service(id)
    }

    private var state: String {
        switch tab.kind {
        case .session: return (model.engine.attention[tab.terminalKey] ?? .idle).label
        case .service:
            guard let service = serviceValue else { return "" }
            return (model.engine.serviceStatus[service.id] ?? .stopped).label
        default: return model.engine.isLive(tab.terminalKey) ? "open" : "closed"
        }
    }

    private var stateColor: Color {
        switch tab.kind {
        case .session:
            switch model.engine.attention[tab.terminalKey] ?? .idle {
            case .working: return Theme.running
            case .waiting: return Theme.waiting
            case .idle:    return theme.idle
            }
        case .service:
            guard let service = serviceValue else { return theme.idle }
            return (model.engine.serviceStatus[service.id] ?? .stopped).color
        default:
            return model.engine.isLive(tab.terminalKey) ? Theme.running : theme.idle
        }
    }

    private var meta: String {
        switch tab.kind {
        case .service: return serviceValue?.command ?? ""
        case .script:
            guard let script = scriptValue else { return "" }
            return script.resolvedCwd(projectPath: model.project.path)
        case .session: return Tmux.isAvailable ? tab.ref : "no tmux"
        case .terminal:
            guard let id = UUID(uuidString: tab.ref), let terminal = model.store.terminal(id)
            else { return "" }
            return terminal.resolvedCwd(projectPath: model.project.path)
        default: return ""
        }
    }
}

// MARK: - Skill

private struct SkillPane: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let skill: Skill
    @State private var section: Section = .definition
    @State private var body_ = ""

    private enum Section: String, CaseIterable, Identifiable {
        case definition, runs
        var id: String { rawValue }
        var label: String { self == .definition ? "Definition" : "Runs" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: skill.name,
                       state: model.runs.isRunning(skill.name) ? "running" : skill.scope.label,
                       stateColor: model.runs.isRunning(skill.name) ? Theme.running : theme.idle,
                       meta: skill.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                SmallButton(title: "Run", icon: "play.fill", prominent: true) {
                    model.runSkillVisible(skill)
                }
                SmallButton(title: "In background") { model.runSkillBackground(skill) }
                IconButton(icon: "square.and.pencil", help: "Open SKILL.md") {
                    NSWorkspace.shared.open(skill.url)
                }
            }

            // Sub-tabs sit directly under the header, left aligned, so the current
            // section is obvious at a glance.
            SubTabs(items: Section.allCases.map { ($0.rawValue, $0.label) },
                    selected: section.rawValue) { section = Section(rawValue: $0) ?? .definition }

            switch section {
            case .definition: definition
            case .runs:       RunList(model: model, skill: skill.name)
            }
        }
        .onAppear(perform: load)
        .onChange(of: skill.id) { load() }
    }

    private var definition: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 26) {
                    fact("scope", skill.scope.label)
                    if let schedule = model.store.schedule(for: skill.name) {
                        fact("schedule", schedule.enabled ? schedule.summary : "paused")
                    }
                    fact("runs", "\(model.runs.runs(for: skill.name).count)")
                    if let last = model.runs.latest(for: skill.name), let at = last.startedAt {
                        fact("last", at.relative)
                    }
                }
                .padding(.bottom, 18)
                .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
                .padding(.bottom, 20)

                MarkdownView(text: body_.isEmpty ? "_(skill body is empty)_" : body_)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fact(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: key)
            Text(value).font(Theme.ui(12)).foregroundStyle(theme.text)
        }
    }

    private func load() {
        guard let text = try? String(contentsOf: skill.url, encoding: .utf8) else {
            body_ = ""
            return
        }
        body_ = Frontmatter.split(text).body
    }
}

// MARK: - Claude command

/// A slash command's own page: what it does, and one button to run it in a session.
private struct ClaudeCommandPane: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let command: ClaudeCommand
    @State private var body_ = ""
    @State private var section: Section = .definition

    private enum Section: String, CaseIterable, Identifiable {
        case definition, usage
        var id: String { rawValue }
        var label: String { self == .definition ? "Definition" : "Usage" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: command.invocation,
                       state: command.scope.label,
                       stateColor: theme.idle,
                       meta: command.url.path
                        .replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                SmallButton(title: "Run in a session", icon: "play.fill", prominent: true) {
                    model.runClaudeCommand(command)
                }
                IconButton(icon: "square.and.pencil", help: "Open file") {
                    NSWorkspace.shared.open(command.url)
                }
            }

            SubTabs(items: Section.allCases.map { ($0.rawValue, $0.label) },
                    selected: section.rawValue) { section = Section(rawValue: $0) ?? .definition }

            if section == .usage {
                RunList(model: model, skill: command.name, showReports: false)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let hint = command.argumentHint {
                        HStack(spacing: 26) {
                            fact("argument", hint)
                            fact("invoke", "\(command.invocation) \(hint)")
                        }
                        .padding(.bottom, 18)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(theme.separator).frame(height: 1)
                        }
                        .padding(.bottom, 20)
                    }

                    MarkdownView(text: body_.isEmpty ? "_(command body is empty)_" : body_)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }
        .onAppear {
            load()
            model.runs.refresh(skill: command.name)
        }
        .onChange(of: command.id) { load() }
    }

    private func fact(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: key)
            Text(value).font(Theme.mono(12)).foregroundStyle(theme.text)
        }
    }

    private func load() {
        guard let text = try? String(contentsOf: command.url, encoding: .utf8) else {
            body_ = ""
            return
        }
        body_ = Frontmatter.split(text).body
    }
}

// MARK: - Schedule

private struct CronPane: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let schedule: Schedule
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: schedule.skill,
                       state: schedule.enabled ? schedule.summary : "paused",
                       stateColor: schedule.enabled ? theme.accent : theme.idle,
                       meta: schedule.enabled
                             ? "next · \(schedule.nextFire?.shortStamp ?? "—")" : "") {
                SmallButton(title: "Run now", icon: "play.fill", prominent: true) {
                    model.runSkillNow(schedule.skill)
                }
                SmallButton(title: schedule.enabled ? "Pause" : "Resume") {
                    var updated = schedule
                    updated.enabled.toggle()
                    model.store.setSchedule(updated)
                }
                IconButton(icon: "slider.horizontal.3", help: "Edit") { editing = true }
            }

            RunList(model: model, skill: schedule.skill)
        }
        .sheet(isPresented: $editing) {
            ScheduleEditor(model: model, schedule: schedule) { editing = false }
        }
    }
}

// MARK: - Run list and output

private struct RunList: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let skill: String
    /// Reports come from scheduled and manual runs; uses come from Claude's hooks.
    /// They belong in one history, told apart at a glance rather than split in two.
    var showReports = true

    private var runs: [SkillRun] { showReports ? model.runs.runs(for: skill) : [] }
    private var uses: [UsageEvent] { model.runs.usage(for: skill) }

    /// The live log is selected instead of a report while a run is in flight. A run
    /// started by launchd or in the background has no tab of its own, so this is the
    /// only place its output is visible.
    @State private var watchingLive = false
    @State private var liveLog = ""
    @State private var liveTicker: Timer?
    /// The report whose conversation is about to be picked up again.
    @State private var continuing: SkillRun?

    private var isRunning: Bool { model.runs.isRunning(skill) }
    private var showsLive: Bool { watchingLive && isRunning }

    private var selected: SkillRun? {
        if let id = model.selectedRun[skill], let match = runs.first(where: { $0.id == id }) {
            return match
        }
        return runs.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 280)
                .background(theme.chrome)
                .overlay(alignment: .trailing) { Rectangle().fill(theme.separator).frame(width: 1) }

            if showsLive {
                liveOutput
            } else if let run = selected {
                output(run)
            } else if !uses.isEmpty {
                usageDetail
            } else {
                VStack(spacing: 6) {
                    Text(showReports ? "No runs yet." : "Not used yet.")
                        .font(Theme.ui(12.5)).foregroundStyle(theme.text3)
                    Text(".cs/runs/\(skill)/")
                        .font(Theme.mono(10.5)).foregroundStyle(theme.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        // A run that starts anywhere — this pane, a background run, launchd — puts
        // its output on screen without being asked. That is the whole point.
        .onChange(of: isRunning) { _, running in
            watchingLive = running
            running ? startTicking() : stopTicking()
        }
        .onAppear {
            watchingLive = isRunning
            if isRunning { startTicking() }
        }
        .onDisappear { stopTicking() }
        .sheet(item: $continuing) { run in
            ContinueRunSheet(model: model, skill: skill, run: run) { continuing = nil }
        }
    }

    private func startTicking() {
        liveLog = Runs.logTail(project: model.project, skill: skill)
        liveTicker?.invalidate()
        liveTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                self.liveLog = Runs.logTail(project: self.model.project, skill: self.skill)
            }
        }
    }

    private func stopTicking() {
        liveTicker?.invalidate()
        liveTicker = nil
    }

    /// What the runner is printing, refreshed every second and pinned to the bottom.
    private var liveOutput: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(color: Theme.running)
                Text("running now").font(Theme.ui(13, .medium)).foregroundStyle(theme.text)
                Text(".cs/runs/\(skill)/.run.log")
                    .font(Theme.mono(10.5)).foregroundStyle(theme.text3)
                Spacer()
                IconButton(icon: "doc.on.doc", help: "Copy the output") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(liveLog, forType: .string)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(liveLog.isEmpty ? "Waiting for output…" : liveLog)
                        .font(Theme.mono(11))
                        .foregroundStyle(liveLog.isEmpty ? theme.text3 : theme.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: liveLog) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if isRunning {
                    Button { watchingLive = true } label: {
                        HoverRow(selected: showsLive,
                                 padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)) {
                            HStack(spacing: 8) {
                                StatusDot(color: Theme.running)
                                Text("running…").font(Theme.ui(12)).foregroundStyle(theme.text)
                                Spacer()
                                Text("live").font(Theme.ui(10.5)).foregroundStyle(theme.text3)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                if !uses.isEmpty {
                    SectionLabel(text: "used by sessions")
                        .padding(.horizontal, 8)
                        .padding(.top, runs.isEmpty ? 2 : 12)
                        .padding(.bottom, 4)
                    ForEach(uses.prefix(40)) { use in
                        HStack(spacing: 8) {
                            Image(systemName: use.source == .user ? "character.cursor.ibeam"
                                                                  : "sparkles")
                                .font(.system(size: 9.5))
                                .foregroundStyle(theme.accent)
                                .frame(width: 12)
                            Text(use.at.shortStamp)
                                .font(Theme.mono(11))
                                .foregroundStyle(theme.text)
                            Spacer()
                            if let duration = use.duration {
                                Text(duration)
                                    .font(Theme.mono(10.5))
                                    .foregroundStyle(theme.text3)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .help(use.sessionName.map { "in \($0) · \(use.source.label)" }
                              ?? use.source.label)
                    }

                    if !runs.isEmpty {
                        SectionLabel(text: "reports")
                            .padding(.horizontal, 8)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }
                }

                ForEach(runs) { run in
                    Button {
                        model.selectedRun[skill] = run.id
                        watchingLive = false
                    } label: {
                        HoverRow(selected: selected?.id == run.id,
                                 padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)) {
                            HStack(spacing: 8) {
                                StatusDot(color: run.status.color)
                                Text(run.startedAt?.shortStamp ?? run.fileStem)
                                    .font(Theme.mono(11))
                                    .foregroundStyle(theme.text)
                                Spacer()
                                Text(run.status.label)
                                    .font(Theme.ui(10.5))
                                    .foregroundStyle(run.status.color)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if model.canContinue(run) {
                            Button("Continue this run…") { continuing = run }
                        }
                        Button("Copy report") { copyReport(run) }
                        Button("Open file") { NSWorkspace.shared.open(run.url) }
                        Button("Delete") {
                            try? FileManager.default.removeItem(at: run.url)
                            // The `.session` sidecar belongs to the report; leaving it
                            // behind would keep pointing at a conversation nothing names.
                            try? FileManager.default.removeItem(
                                at: run.url.deletingPathExtension().appendingPathExtension("session"))
                            model.runs.refresh(skill: skill)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    /// When there are no reports — the usual case for a command — the right pane
    /// summarises how it has been used instead of showing an empty slot.
    private var usageDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Used \(uses.count) time\(uses.count == 1 ? "" : "s")")
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(theme.text)
                ForEach(uses.prefix(40)) { use in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(use.at.shortStamp)
                            .font(Theme.mono(11))
                            .foregroundStyle(theme.text3)
                            .frame(width: 92, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(use.sessionName ?? "a session")
                                .font(Theme.ui(12))
                                .foregroundStyle(theme.text)
                            if let args = use.args {
                                Text(args)
                                    .font(Theme.mono(10.5))
                                    .foregroundStyle(theme.text3)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Text([use.source.label, use.duration].compactMap { $0 }
                                .joined(separator: " · "))
                            .font(Theme.ui(10.5))
                            .foregroundStyle(theme.text3)
                    }
                    Divider().overlay(theme.separator)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Puts the report on the clipboard as it is on disk — frontmatter included, so
    /// what is pasted is the file, not a re-rendering of it.
    private func copyReport(_ run: SkillRun) {
        let text = (try? String(contentsOf: run.url, encoding: .utf8)) ?? run.body
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func output(_ run: SkillRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(run.startedAt?.shortStamp ?? run.fileStem)
                        .font(Theme.ui(13, .medium))
                        .foregroundStyle(theme.text)
                    StatusDot(color: run.status.color)
                    Text(run.status.label).font(Theme.ui(11)).foregroundStyle(theme.text3)
                    if let trigger = run.trigger {
                        Text("· \(trigger)").font(Theme.ui(11)).foregroundStyle(theme.text3)
                    }
                    Spacer()
                    // Reading a report and answering it are one motion — the answer
                    // goes back to the conversation that wrote it, not to a new one.
                    if model.canContinue(run) {
                        SmallButton(title: "Continue", icon: "arrow.uturn.left") {
                            continuing = run
                        }
                    }
                    // The report is rendered markdown, and a drag selects within one
                    // block only — copying the whole thing needs a button.
                    IconButton(icon: "doc.on.doc", help: "Copy the report") {
                        copyReport(run)
                    }
                    IconButton(icon: "arrow.up.forward.square", help: "Open file") {
                        NSWorkspace.shared.open(run.url)
                    }
                }
                .padding(.bottom, 14)

                if let summary = run.summary {
                    Text(summary)
                        .font(Theme.ui(13))
                        .foregroundStyle(theme.text2)
                        .padding(.bottom, 16)
                }

                MarkdownView(text: run.body.isEmpty ? "_(report body is empty)_" : run.body)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Section tabs under the header (like VS Code's editor sub-tabs).
struct SubTabs: View {
    @Environment(\.studioTheme) private var theme
    let items: [(String, String)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { value, label in
                Button { onSelect(value) } label: {
                    Text(label)
                        .font(Theme.ui(12, selected == value ? .medium : .regular))
                        .foregroundStyle(selected == value ? theme.text : theme.text3)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selected == value ? theme.accent : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 8)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
    }
}

// MARK: - Shared header

/// The content area's header strip: title, state, optional segments, actions.
struct PaneHeader<Actions: View>: View {
    @Environment(\.studioTheme) private var theme
    let title: String
    var state: String = ""
    /// nil = the theme's idle grey; a value overrides it (a run's status).
    var stateColor: Color? = nil
    var meta: String = ""
    var segments: [(String, String)] = []
    var selectedSegment: String = ""
    var onSegment: (String) -> Void = { _ in }
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.ui(13, .medium))
                .foregroundStyle(theme.text)
                .lineLimit(1)

            if !state.isEmpty {
                HStack(spacing: 5) {
                    StatusDot(color: stateColor ?? theme.idle)
                    Text(state).font(Theme.ui(11)).foregroundStyle(theme.text3)
                }
            }

            Spacer(minLength: 8)

            if !segments.isEmpty {
                HStack(spacing: 1) {
                    ForEach(segments, id: \.0) { value, label in
                        Button { onSegment(value) } label: {
                            Text(label)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(selectedSegment == value ? theme.text : theme.text3)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(selectedSegment == value ? theme.surface : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.field))
            }

            if !meta.isEmpty {
                Text(meta)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 280, alignment: .trailing)
            }

            actions()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 1) }
    }
}
