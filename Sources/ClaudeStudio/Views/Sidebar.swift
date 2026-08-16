import SwiftUI
import AppKit

/// Seçili raya göre içerik değiştiren kenar çubuğu.
struct Sidebar: View {
    @ObservedObject var model: StudioModel

    @State private var serviceSheet: Service?
    @State private var addingService = false
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
        .sheet(isPresented: $sessionManager) {
            SessionManager(model: model) { sessionManager = false }
        }
    }

    // MARK: - Başlık / altlık

    private var header: some View {
        HStack(spacing: 2) {
            SectionLabel(text: model.pane.title)
            Spacer()
            if model.pane == .sessions {
                IconButton(icon: "list.bullet.rectangle", help: "Oturum yöneticisi") {
                    sessionManager = true
                }
                IconButton(icon: "plus", help: "Yeni oturum / önceki oturumlar") {
                    sessionMenu = true
                }
                .popover(isPresented: $sessionMenu, arrowEdge: .bottom) {
                    SessionOpener(model: model) { sessionMenu = false }
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
        case .sessions:  return "\(model.openSessions.count) açık · \(model.pastSessions.count) önceki"
        case .skills:    return "\(model.skills.skills.count) beceri · .claude/skills"
        case .cron:      return "\(model.store.activeSchedules.count) aktif zamanlama"
        case .services:  return "\(model.runningServiceCount)/\(model.store.config.services.count) çalışıyor"
        case .terminals: return "\(model.store.config.terminals.count) terminal"
        }
    }

    private var addHelp: String {
        switch model.pane {
        case .sessions:  return "Yeni oturum"
        case .skills:    return "Claude ile yeni beceri oluştur"
        case .cron:      return "Beceri zamanla"
        case .services:  return "Servis ekle"
        case .terminals: return "Yeni terminal (⌘T)"
        }
    }

    private func add() {
        switch model.pane {
        case .sessions:
            model.newSession()
        case .skills:
            model.newSession(name: "yeni beceri", prompt: newSkillPrompt, autoRun: true)
        case .cron:
            guard let first = model.skills.skills.first else { return }
            scheduleSheet = model.store.schedule(for: first.name) ?? Schedule(skill: first.name)
        case .services:
            addingService = true
            serviceSheet = Service(name: "yeni servis", command: "")
        case .terminals:
            model.newTerminal()
        }
    }

    private var newSkillPrompt: String {
        """
        Bu projeye yeni bir Claude Code becerisi ekle: `.claude/skills/<ad>/SKILL.md`.
        Önce ne yapmasını istediğimi sor, sonra frontmatter'ında `name` ve `description` \
        alanları olan sade bir SKILL.md yaz.
        """
    }

    // MARK: - Oturumlar

    @ViewBuilder private var sessionsList: some View {
        if model.openSessions.isEmpty {
            emptyHint("Açık oturum yok.", action: "Claude oturumu başlat") { model.newSession() }
        }
        ForEach(model.openSessions) { record in
            if renaming == record.tmux {
                renameField(record)
            } else {
                // Tek tık açar, çift tık adı düzenler — Finder/VS Code refleksi.
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
                        IconButton(icon: "xmark", help: "Oturumu kapat") {
                            model.closeSession(record)
                        }
                    }
                }
                .onTapGesture(count: 2) { beginRename(record) }
                .onTapGesture { model.openSession(record) }
                .contextMenu {
                    Button("Yeniden adlandır") { beginRename(record) }
                    Button("Oturumu kapat") { model.closeSession(record) }
                    Divider()
                    Button("Kaydı sil") { model.deleteSession(record) }
                }
            }
        }

        if !model.pastSessions.isEmpty {
            SectionLabel(text: "önceki oturumlar")
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(model.pastSessions.prefix(8)) { record in
                row(selected: false,
                    dot: Theme.idle,
                    title: record.name,
                    meta: model.canResume(record) ? "konuşma sürdürülür · \(record.lastUsed.relative)"
                                                  : "yeni başlar · \(record.lastUsed.relative)",
                    action: { model.openSession(record) })
                    .contextMenu {
                        Button("Geri aç") { model.openSession(record) }
                        Button("Kaydı sil") { model.deleteSession(record) }
                    }
            }
        }
    }

    private func beginRename(_ record: SessionRecord) {
        renameText = record.name
        renaming = record.tmux
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { renameFocused = true }
    }

    /// Alan açılır açılmaz odaklanır; yoksa tuşlar terminale gider.
    private func renameField(_ record: SessionRecord) -> some View {
        TextField("oturum adı", text: $renameText)
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

    // MARK: - Beceriler

    @ViewBuilder private var skillsList: some View {
        if model.skills.skills.isEmpty {
            emptyHint("`.claude/skills` boş.", action: "Claude ile beceri oluştur") {
                model.newSession(name: "yeni beceri", prompt: newSkillPrompt, autoRun: true)
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
                        Text("genel")
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
                    Button("Oturumda çalıştır") { model.runSkillVisible(skill) }
                    Button("Arka planda çalıştır") { model.runSkillBackground(skill) }
                    Divider()
                    Button("Zamanla…") {
                        scheduleSheet = model.store.schedule(for: skill.name) ?? Schedule(skill: skill.name)
                    }
                    Button("SKILL.md'yi aç") { NSWorkspace.shared.open(skill.url) }
                }
        }
    }

    private func skillMeta(skill: Skill, schedule: Schedule?, last: SkillRun?) -> String {
        if model.runs.isRunning(skill.name) { return "çalışıyor…" }
        var parts: [String] = []
        if let schedule, schedule.enabled { parts.append(schedule.summary) }
        if let last, let at = last.startedAt { parts.append(at.relative) }
        if parts.isEmpty, let description = skill.description { return description }
        return parts.joined(separator: " · ")
    }

    // MARK: - Zamanlamalar

    @ViewBuilder private var cronList: some View {
        if model.store.config.schedules.isEmpty {
            emptyHint("Zamanlanmış çalışma yok.", action: "Beceri zamanla") {
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
                      ? "\(schedule.summary) · sonraki \(schedule.nextFire?.shortStamp ?? "—")"
                      : "duraklatıldı",
                trailing: {
                    IconButton(icon: schedule.enabled ? "pause" : "play",
                               help: schedule.enabled ? "Duraklat" : "Sürdür") {
                        var updated = schedule
                        updated.enabled.toggle()
                        model.store.setSchedule(updated)
                    }
                },
                action: { model.openCron(schedule) })
                .contextMenu {
                    Button("Düzenle…") { scheduleSheet = schedule }
                    Button("Şimdi çalıştır") { model.runs.runInBackground(skill: schedule.skill) }
                    Divider()
                    Button("Zamanlamayı sil") { model.store.removeSchedule(skill: schedule.skill) }
                }
        }
    }

    // MARK: - Servisler

    @ViewBuilder private var servicesList: some View {
        if model.store.config.services.isEmpty {
            emptyHint("Servis tanımlı değil.", action: "Servis ekle") {
                addingService = true
                serviceSheet = Service(name: "yeni servis", command: "")
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
                               help: status.isLive ? "Durdur" : "Başlat") {
                        model.toggleService(service)
                    }
                },
                action: {
                    model.openService(service)
                    if !status.isLive { model.engine.startService(service, project: model.project) }
                })
                .contextMenu {
                    Button("Yeniden başlat") { model.engine.restartService(service, project: model.project) }
                    Button("Ayarlar…") { serviceSheet = service }
                    Divider()
                    Button("Servisi sil") {
                        model.engine.stopService(service)
                        model.store.removeService(service.id)
                    }
                }
        }
    }

    // MARK: - Terminaller

    @ViewBuilder private var terminalsList: some View {
        if model.store.config.terminals.isEmpty {
            emptyHint("Terminal yok.", action: "Terminal aç") { model.newTerminal() }
        }
        ForEach(model.store.config.terminals) { terminal in
            let key = "terminal:\(terminal.id.uuidString)"
            row(selected: model.activeTabID == key,
                dot: model.engine.isLive(key) ? Theme.running : Theme.idle,
                title: terminal.name,
                meta: terminal.cwd.nilIfEmpty ?? model.project.displayPath,
                action: { model.openTerminal(terminal) })
                .contextMenu {
                    Button("Kapat ve sil") { model.removeTerminal(terminal) }
                }
        }
    }

    // MARK: - Ortak satır

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

// MARK: - Yeni / önceki oturum açıcı

/// "+" düğmesinin açtığı liste: yeni oturum ya da kapatılmış bir oturumu
/// aynı isimle geri getirme.
private struct SessionOpener: View {
    @ObservedObject var model: StudioModel
    let onDismiss: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: "yeni oturum")
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

            HStack(spacing: 6) {
                TextField("oturum adı (isteğe bağlı)", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12.5))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.field)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.separator)))
                    .onSubmit(create)
                SmallButton(title: "Aç", prominent: true, action: create)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            if !model.pastSessions.isEmpty {
                Divider()
                SectionLabel(text: "önceki oturumlar")
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
                                                 ? "konuşma sürdürülür · \(record.lastUsed.relative)"
                                                 : "yeni başlar · \(record.lastUsed.relative)")
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
