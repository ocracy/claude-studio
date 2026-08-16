import SwiftUI
import AppKit

/// Sekmenin türüne göre içerik: terminal, beceri kartı ya da çalışma geçmişi.
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
        case .session, .terminal, .service:
            TerminalPane(model: model, tab: tab)
        case .skill:
            if let skill = model.skills.skill(named: tab.ref) {
                SkillPane(model: model, skill: skill)
            } else {
                message("Beceri bulunamadı: \(tab.ref)")
            }
        case .cron:
            if let schedule = model.store.schedule(for: tab.ref) {
                CronPane(model: model, schedule: schedule)
            } else {
                message("Zamanlama kaldırılmış: \(tab.ref)")
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

// MARK: - Boş durum

private struct EmptyStudio: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Theme.text3)
            Text("Soldan bir oturum, beceri, zamanlama, servis veya terminal seçin")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                SmallButton(title: "Claude oturumu", icon: "plus", prominent: true) {
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
                // Alan görünür olur olmaz odaklanmalı; yoksa yazdıkların
                // terminale gider ve "yeniden adlandırma çalışmıyor" olur.
                TextField("ad", text: $draftTitle)
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
                // Başlığa çift tıkla → yeniden adlandır; tmux oturumu bu isimle kaydedilir.
                Text(tab.title)
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: beginRename)
                    .help(renameable ? "Yeniden adlandırmak için çift tıkla" : "")
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
                SmallButton(title: live ? "Durdur" : "Başlat",
                            icon: live ? "stop.fill" : "play.fill") { model.toggleService(service) }
                IconButton(icon: "arrow.clockwise", help: "Yeniden başlat") {
                    model.engine.restartService(service, project: model.project)
                }
            }
        case .session:
            IconButton(icon: "pencil", help: "Yeniden adlandır", action: beginRename)
            IconButton(icon: "xmark.circle", help: "Oturumu kapat") {
                model.closeTab(id: tab.id)
            }
        case .terminal:
            IconButton(icon: "pencil", help: "Yeniden adlandır", action: beginRename)
            IconButton(icon: "clear", help: "Ekranı temizle") {
                model.engine.clear(key: tab.terminalKey)
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
        default: return model.engine.isLive(tab.terminalKey) ? "açık" : "kapalı"
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
        case .session: return Tmux.isAvailable ? tab.ref : "tmux yok"
        case .terminal:
            guard let id = UUID(uuidString: tab.ref), let terminal = model.store.terminal(id)
            else { return "" }
            return terminal.resolvedCwd(projectPath: model.project.path)
        default: return ""
        }
    }
}

// MARK: - Beceri

private struct SkillPane: View {
    @ObservedObject var model: StudioModel
    let skill: Skill
    @State private var section: Section = .tanim
    @State private var body_ = ""

    private enum Section: String, CaseIterable, Identifiable {
        case tanim, calismalar
        var id: String { rawValue }
        var label: String { self == .tanim ? "Tanım" : "Çalışmalar" }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: skill.name,
                       state: model.runs.isRunning(skill.name) ? "çalışıyor" : skill.scope.label,
                       stateColor: model.runs.isRunning(skill.name) ? Theme.running : Theme.idle,
                       meta: skill.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                SmallButton(title: "Çalıştır", icon: "play.fill", prominent: true) {
                    model.runSkillVisible(skill)
                }
                SmallButton(title: "Arka planda") { model.runSkillBackground(skill) }
                IconButton(icon: "square.and.pencil", help: "SKILL.md'yi aç") {
                    NSWorkspace.shared.open(skill.url)
                }
            }

            // Alt sekmeler: başlığın hemen altında, sola yaslı — hangi bölümde
            // olduğun tek bakışta belli olsun.
            SubTabs(items: Section.allCases.map { ($0.rawValue, $0.label) },
                    selected: section.rawValue) { section = Section(rawValue: $0) ?? .tanim }

            switch section {
            case .tanim:      definition
            case .calismalar: RunList(model: model, skill: skill.name)
            }
        }
        .onAppear(perform: load)
        .onChange(of: skill.id) { load() }
    }

    private var definition: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 26) {
                    fact("kapsam", skill.scope.label)
                    if let schedule = model.store.schedule(for: skill.name) {
                        fact("zamanlama", schedule.enabled ? schedule.summary : "duraklatıldı")
                    }
                    fact("çalışma", "\(model.runs.runs(for: skill.name).count)")
                    if let last = model.runs.latest(for: skill.name), let at = last.startedAt {
                        fact("son", at.relative)
                    }
                }
                .padding(.bottom, 18)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
                .padding(.bottom, 20)

                MarkdownView(text: body_.isEmpty ? "_(beceri gövdesi boş)_" : body_)
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

// MARK: - Zamanlama

private struct CronPane: View {
    @ObservedObject var model: StudioModel
    let schedule: Schedule
    @State private var editing = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: schedule.skill,
                       state: schedule.enabled ? schedule.summary : "duraklatıldı",
                       stateColor: schedule.enabled ? Theme.accent : Theme.idle,
                       meta: schedule.enabled
                             ? "sonraki · \(schedule.nextFire?.shortStamp ?? "—")" : "") {
                SmallButton(title: "Şimdi çalıştır", icon: "play.fill", prominent: true) {
                    model.runs.runInBackground(skill: schedule.skill)
                }
                SmallButton(title: schedule.enabled ? "Duraklat" : "Sürdür") {
                    var updated = schedule
                    updated.enabled.toggle()
                    model.store.setSchedule(updated)
                }
                IconButton(icon: "slider.horizontal.3", help: "Düzenle") { editing = true }
            }

            RunList(model: model, skill: schedule.skill)
        }
        .sheet(isPresented: $editing) {
            ScheduleEditor(model: model, schedule: schedule) { editing = false }
        }
    }
}

// MARK: - Çalışma listesi + çıktı

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
                    Text("Henüz çalışma yok.")
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
                        Text("çalışıyor…").font(Theme.ui(12)).foregroundStyle(Theme.text2)
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
                        Button("Dosyayı aç") { NSWorkspace.shared.open(run.url) }
                        Button("Sil") {
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
                    IconButton(icon: "arrow.up.forward.square", help: "Dosyayı aç") {
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

                MarkdownView(text: run.body.isEmpty ? "_(rapor gövdesi boş)_" : run.body)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Başlık altındaki bölüm sekmeleri (VS Code'un editör alt sekmeleri gibi).
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

// MARK: - Ortak başlık

/// İçerik alanının üst şeridi: başlık, durum, isteğe bağlı segmentler, eylemler.
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
