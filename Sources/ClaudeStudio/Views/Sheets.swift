import SwiftUI
import AppKit

// MARK: - Session manager

/// Every Claude session of the project in one list: which are alive in tmux,
/// which can be reopened — and unwanted ones are deleted here.
struct SessionManager: View {
    @ObservedObject var model: StudioModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Session manager")
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(model.project.name)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.bottom, 4)

            Text("Open sessions live in tmux; closed ones keep their record and reopen under the same name.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.text3)
                .padding(.bottom, 14)

            if model.sessions.isEmpty {
                Text("No recorded sessions.")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.sessions) { record in
                            row(record)
                        }
                    }
                }
                .frame(height: 300)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator)))
            }

            HStack(spacing: 10) {
                Button {
                    for record in model.openSessions { model.closeSession(record) }
                } label: {
                    Text("Close all sessions")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
                .disabled(model.openSessions.isEmpty)

                Spacer()
                SmallButton(title: "Done", prominent: true, action: onDismiss)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.bg)
    }

    private func row(_ record: SessionRecord) -> some View {
        let live = model.liveSessions.contains(record.tmux)
        return HStack(spacing: 10) {
            StatusDot(color: live ? Theme.running : Theme.idle)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                Text("\(record.tmux) · \(record.lastUsed.relative)")
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.text3)
            }
            Spacer()
            Text(live ? "open" : (model.canResume(record) ? "resumable" : "closed"))
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.text3)
            SmallButton(title: live ? "Close" : "Open") {
                live ? model.closeSession(record) : model.openSession(record)
            }
            IconButton(icon: "trash", help: "Delete record", tint: Theme.danger) {
                model.deleteSession(record)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Service settings

struct ServiceEditor: View {
    @ObservedObject var model: StudioModel
    @State var service: Service
    let isNew: Bool
    let onDismiss: () -> Void

    @State private var portText = ""

    var body: some View {
        SheetShell(title: isNew ? "New service" : service.name,
                   destructive: isNew ? nil : ("Delete service", {
                       model.engine.stopService(service)
                       model.store.removeService(service.id)
                       onDismiss()
                   }),
                   confirm: ("Save", save),
                   onDismiss: onDismiss) {
            Field(label: "name") {
                TextField("frontend", text: $service.name)
                    .textFieldStyle(.plain).font(Theme.ui(12.5))
            }
            Field(label: "command") {
                TextField("npm run dev", text: $service.command)
                    .textFieldStyle(.plain).font(Theme.mono(12))
            }
            Field(label: "directory") {
                TextField(model.project.displayPath, text: $service.cwd)
                    .textFieldStyle(.plain).font(Theme.mono(12))
            }
            Field(label: "port (optional)") {
                TextField("5173", text: $portText)
                    .textFieldStyle(.plain).font(Theme.mono(12))
            }
            Toggle("Start automatically when the project opens", isOn: $service.autoStart)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .font(Theme.ui(12.5))
        }
        .onAppear { portText = service.port.map(String.init) ?? "" }
    }

    private func save() {
        service.port = Int(portText.trimmingCharacters(in: .whitespaces))
        guard service.name.nilIfEmpty != nil, service.command.nilIfEmpty != nil else { return }
        if isNew { model.store.addService(service) } else { model.store.updateService(service) }
        onDismiss()
    }
}

// MARK: - MCP server

/// Add or inspect an MCP server. Writing goes through `claude mcp add`, so Claude's
/// own validation and scope handling stay authoritative; an existing server is shown
/// read-only with the actions that only its CLI can perform.
struct MCPEditor: View {
    @ObservedObject var model: StudioModel
    @State var server: MCPServer
    let onDismiss: () -> Void

    @State private var argsText = ""
    @State private var envText = ""
    @State private var headersText = ""
    @State private var failure: String?
    @State private var saving = false

    /// A server that already exists on disk is edited by removing and re-adding —
    /// the CLI has no update verb — so the form only creates.
    private var isNew: Bool { !model.mcp.servers.contains { $0.id == server.id } }

    var body: some View {
        SheetShell(title: isNew ? "Add MCP server" : server.name,
                   destructive: isNew ? nil : ("Remove server", {
                       model.mcp.remove(server)
                       onDismiss()
                   }),
                   confirm: isNew ? ("Add", save) : ("Done", onDismiss),
                   onDismiss: onDismiss) {
            if isNew {
                Field(label: "name") {
                    TextField("sentry", text: $server.name)
                        .textFieldStyle(.plain).font(Theme.ui(12.5))
                }

                Field(label: "transport") {
                    Picker("", selection: $server.transport) {
                        ForEach(MCPServer.Transport.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }

                if server.transport == .stdio {
                    Field(label: "command") {
                        TextField("npx", text: $server.command)
                            .textFieldStyle(.plain).font(Theme.mono(12))
                    }
                    Field(label: "arguments (one per line)") {
                        TextEditor(text: $argsText)
                            .font(Theme.mono(12)).frame(height: 48)
                            .scrollContentBackground(.hidden)
                    }
                    Field(label: "environment (KEY=value per line)") {
                        TextEditor(text: $envText)
                            .font(Theme.mono(12)).frame(height: 40)
                            .scrollContentBackground(.hidden)
                    }
                } else {
                    Field(label: "url") {
                        TextField("https://mcp.example.com/mcp", text: $server.url)
                            .textFieldStyle(.plain).font(Theme.mono(12))
                    }
                    Field(label: "headers (Name: value per line)") {
                        TextEditor(text: $headersText)
                            .font(Theme.mono(12)).frame(height: 40)
                            .scrollContentBackground(.hidden)
                    }
                }

                Field(label: "scope") {
                    Picker("", selection: $server.scope) {
                        ForEach(MCPServer.Scope.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                }
                Text(server.scope.help)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.text3)

                if let failure {
                    Text(failure)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                detail("transport", server.transport.rawValue)
                detail(server.transport == .stdio ? "command" : "url", server.detail)
                detail("scope", "\(server.scope.label) — \(server.scope.help)")
                detail("connection", server.health.label)

                HStack(spacing: 8) {
                    if server.transport != .stdio {
                        SmallButton(title: "Sign in") {
                            model.runMCPCommand("login \(Shell.quoted(server.name))",
                                                title: "mcp login: \(server.name)")
                            onDismiss()
                        }
                    }
                    SmallButton(title: "Details") {
                        model.runMCPCommand("get \(Shell.quoted(server.name))",
                                            title: "mcp: \(server.name)")
                        onDismiss()
                    }
                    SmallButton(title: "Check connection") { model.mcp.checkHealth() }
                }
                Text("Edit a server by removing it and adding it again — `claude mcp` has no update verb.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            argsText = server.args.joined(separator: "\n")
            envText = server.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
            headersText = server.headers.map { "\($0.key): \($0.value)" }.sorted()
                .joined(separator: "\n")
        }
    }

    private func detail(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: key)
            Text(value)
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard !saving, server.name.nilIfEmpty != nil else { return }
        switch server.transport {
        case .stdio: guard server.command.nilIfEmpty != nil else { return }
        case .http, .sse: guard server.url.nilIfEmpty != nil else { return }
        }

        server.args = argsText.components(separatedBy: .newlines).compactMap(\.nilIfEmpty)
        server.env = Self.pairs(envText, separator: "=")
        server.headers = Self.pairs(headersText, separator: ":")

        saving = true
        model.mcp.add(server) { ok, output in
            saving = false
            if ok { onDismiss() } else { failure = output.nilIfEmpty ?? "claude mcp add failed." }
        }
    }

    /// Splits `KEY=value` / `Name: value` lines, keeping any separator inside the value.
    private static func pairs(_ text: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            guard let index = line.firstIndex(of: separator) else { continue }
            let key = String(line[line.startIndex..<index]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: index)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            out[key] = value
        }
        return out
    }
}

// MARK: - Script settings

struct ScriptEditor: View {
    @ObservedObject var model: StudioModel
    @State var script: ProjectScript
    let isNew: Bool
    let onDismiss: () -> Void

    var body: some View {
        SheetShell(title: isNew ? "New script" : script.name,
                   destructive: isNew ? nil : ("Delete script", {
                       model.removeScript(script)
                       onDismiss()
                   }),
                   confirm: ("Save", save),
                   onDismiss: onDismiss) {
            Field(label: "name") {
                TextField("build", text: $script.name)
                    .textFieldStyle(.plain).font(Theme.ui(12.5))
            }
            Field(label: "command") {
                TextField("npm run build", text: $script.command)
                    .textFieldStyle(.plain).font(Theme.mono(12))
            }
            Field(label: "directory") {
                TextField(model.project.path, text: $script.cwd)
                    .textFieldStyle(.plain).font(Theme.mono(12))
            }
            Text("Runs once in its own tab and shows the exit code in place. No port, no auto-start.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        guard script.name.nilIfEmpty != nil, script.command.nilIfEmpty != nil else { return }
        if isNew { model.store.addScript(script) } else { model.store.updateScript(script) }
        onDismiss()
    }
}

// MARK: - Schedule settings

struct ScheduleEditor: View {
    @ObservedObject var model: StudioModel
    @State var schedule: Schedule
    let onDismiss: () -> Void

    var body: some View {
        SheetShell(title: "Scheduled run",
                   destructive: model.store.schedule(for: schedule.skill) != nil
                        ? ("Delete schedule", {
                            model.store.removeSchedule(skill: schedule.skill)
                            onDismiss()
                        }) : nil,
                   confirm: ("Save", save),
                   onDismiss: onDismiss) {
            Field(label: "skill") {
                Picker("", selection: $schedule.skill) {
                    ForEach(model.skills.skills) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().pickerStyle(.menu).font(Theme.ui(12.5))
            }

            Field(label: "frequency") {
                Picker("", selection: $schedule.frequency) {
                    ForEach(Schedule.Frequency.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
            }

            HStack(spacing: 10) {
                if schedule.frequency == .weekly {
                    Field(label: "day") {
                        Picker("", selection: $schedule.weekday) {
                            ForEach(0..<7, id: \.self) { Text(Schedule.weekdayNames[$0]).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                }
                if schedule.frequency != .hourly {
                    Field(label: "hour") {
                        Stepper(value: $schedule.hour, in: 0...23) {
                            Text(String(format: "%02d", schedule.hour)).font(Theme.mono(12))
                        }
                    }
                }
                Field(label: "minute") {
                    Stepper(value: $schedule.minute, in: 0...59, step: 5) {
                        Text(String(format: "%02d", schedule.minute)).font(Theme.mono(12))
                    }
                }
            }

            Field(label: "extra instruction (optional)") {
                TextEditor(text: $schedule.prompt)
                    .font(Theme.mono(12))
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
            }

            Toggle("Schedule enabled", isOn: $schedule.enabled)
                .toggleStyle(.switch).tint(Theme.accent).font(Theme.ui(12.5))

            Text("Runs \(schedule.summary); launchd takes over even while the app is closed. The report is written to `.cs/runs/\(schedule.skill)/`.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        model.store.setSchedule(schedule)
        onDismiss()
    }
}

// MARK: - Shared shell

struct SheetShell<Content: View>: View {
    let title: String
    var destructive: (String, () -> Void)?
    let confirm: (String, () -> Void)
    let onDismiss: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Theme.ui(15, .semibold))
                .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.top, 18)

            HStack(spacing: 10) {
                if let (label, action) = destructive {
                    Button(action: action) {
                        Text(label).font(Theme.ui(11.5)).foregroundStyle(Theme.danger)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(action: onDismiss) {
                    Text("Cancel").font(Theme.ui(11.5)).foregroundStyle(Theme.text3)
                }
                .buttonStyle(.plain)
                SmallButton(title: confirm.0, prominent: true, action: confirm.1)
            }
            .padding(.top, 20)
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.bg)
    }
}

/// A labelled form field.
struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(text: label)
            content()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.separator))
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
