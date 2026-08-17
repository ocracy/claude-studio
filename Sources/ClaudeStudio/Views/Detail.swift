import SwiftUI
import AppKit

/// Content by tab kind: terminal, skill card or run history.
struct ContentArea: View {
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
        .background(Theme.bg)
    }

    @ViewBuilder
    private func content(for tab: StudioTab) -> some View {
        switch tab.kind {
        case .session, .terminal, .service, .command:
            TerminalPane(model: model, tab: tab)
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
            .foregroundStyle(Theme.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty state

private struct EmptyStudio: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Theme.text3)
            Text("Pick a session, skill, schedule, service or terminal on the left")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.text3)
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
    @ObservedObject var model: StudioModel
    let tab: StudioTab
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHost(key: tab.terminalKey, engine: model.engine)
        }
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
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.accent)))
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editingTitle = false }
                    .onAppear { titleFocused = true }
            } else {
                // Double-click the title to rename; the tmux session is recorded
                // under that name.
                Text(tab.title)
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: beginRename)
                    .help(renameable ? "Double-click to rename" : "")
            }

            HStack(spacing: 5) {
                StatusDot(color: stateColor)
                Text(state).font(Theme.ui(11)).foregroundStyle(Theme.text3)
            }

            Spacer(minLength: 8)

            Text(meta)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.head)

            actions
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
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
        case .command:
            if let command = commandValue {
                SmallButton(title: model.engine.isLive(tab.terminalKey) ? "Running…" : "Run again",
                            icon: "play.fill",
                            prominent: !model.engine.isLive(tab.terminalKey)) {
                    model.runCommand(command)
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

    private var commandValue: ProjectCommand? {
        guard tab.kind == .command, let id = UUID(uuidString: tab.ref) else { return nil }
        return model.store.command(id)
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
            case .idle:    return Theme.idle
            }
        case .service:
            guard let service = serviceValue else { return Theme.idle }
            return (model.engine.serviceStatus[service.id] ?? .stopped).color
        default:
            return model.engine.isLive(tab.terminalKey) ? Theme.running : Theme.idle
        }
    }

    private var meta: String {
        switch tab.kind {
        case .service: return serviceValue?.command ?? ""
        case .command:
            guard let command = commandValue else { return "" }
            return command.resolvedCwd(projectPath: model.project.path)
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
                       stateColor: model.runs.isRunning(skill.name) ? Theme.running : Theme.idle,
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
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
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
            Text(value).font(Theme.ui(12)).foregroundStyle(Theme.text)
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

// MARK: - Schedule

private struct CronPane: View {
    @ObservedObject var model: StudioModel
    let schedule: Schedule
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: schedule.skill,
                       state: schedule.enabled ? schedule.summary : "paused",
                       stateColor: schedule.enabled ? Theme.accent : Theme.idle,
                       meta: schedule.enabled
                             ? "next · \(schedule.nextFire?.shortStamp ?? "—")" : "") {
                SmallButton(title: "Run now", icon: "play.fill", prominent: true) {
                    model.runs.runInBackground(skill: schedule.skill)
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
    @ObservedObject var model: StudioModel
    let skill: String

    private var runs: [SkillRun] { model.runs.runs(for: skill) }

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
                .background(Theme.chrome)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }

            if let run = selected {
                output(run)
            } else {
                VStack(spacing: 6) {
                    Text("No runs yet.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.text3)
                    Text(".cs/runs/\(skill)/")
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if model.runs.isRunning(skill) {
                    HStack(spacing: 8) {
                        StatusDot(color: Theme.running)
                        Text("running…").font(Theme.ui(12)).foregroundStyle(Theme.text2)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
                ForEach(runs) { run in
                    Button { model.selectedRun[skill] = run.id } label: {
                        HoverRow(selected: selected?.id == run.id,
                                 padding: EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8)) {
                            HStack(spacing: 8) {
                                StatusDot(color: run.status.color)
                                Text(run.startedAt?.shortStamp ?? run.fileStem)
                                    .font(Theme.mono(11))
                                    .foregroundStyle(Theme.text)
                                Spacer()
                                Text(run.status.label)
                                    .font(Theme.ui(10.5))
                                    .foregroundStyle(run.status.color)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open file") { NSWorkspace.shared.open(run.url) }
                        Button("Delete") {
                            try? FileManager.default.removeItem(at: run.url)
                            model.runs.refresh(skill: skill)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private func output(_ run: SkillRun) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(run.startedAt?.shortStamp ?? run.fileStem)
                        .font(Theme.ui(13, .medium))
                        .foregroundStyle(Theme.text)
                    StatusDot(color: run.status.color)
                    Text(run.status.label).font(Theme.ui(11)).foregroundStyle(Theme.text3)
                    if let trigger = run.trigger {
                        Text("· \(trigger)").font(Theme.ui(11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    IconButton(icon: "arrow.up.forward.square", help: "Open file") {
                        NSWorkspace.shared.open(run.url)
                    }
                }
                .padding(.bottom, 14)

                if let summary = run.summary {
                    Text(summary)
                        .font(Theme.ui(13))
                        .foregroundStyle(Theme.text2)
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
    let items: [(String, String)]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { value, label in
                Button { onSelect(value) } label: {
                    Text(label)
                        .font(Theme.ui(12, selected == value ? .medium : .regular))
                        .foregroundStyle(selected == value ? Theme.text : Theme.text3)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selected == value ? Theme.accent : .clear)
                                .frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.leading, 8)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

// MARK: - Shared header

/// The content area's header strip: title, state, optional segments, actions.
struct PaneHeader<Actions: View>: View {
    let title: String
    var state: String = ""
    var stateColor: Color = Theme.idle
    var meta: String = ""
    var segments: [(String, String)] = []
    var selectedSegment: String = ""
    var onSegment: (String) -> Void = { _ in }
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Theme.ui(13, .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)

            if !state.isEmpty {
                HStack(spacing: 5) {
                    StatusDot(color: stateColor)
                    Text(state).font(Theme.ui(11)).foregroundStyle(Theme.text3)
                }
            }

            Spacer(minLength: 8)

            if !segments.isEmpty {
                HStack(spacing: 1) {
                    ForEach(segments, id: \.0) { value, label in
                        Button { onSegment(value) } label: {
                            Text(label)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(selectedSegment == value ? Theme.text : Theme.text3)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(selectedSegment == value ? Theme.bg : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            }

            if !meta.isEmpty {
                Text(meta)
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 280, alignment: .trailing)
            }

            actions()
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}
