import SwiftUI
import AppKit

/// Ana ekran: üst bar · etkinlik rayı · kenar çubuğu · sekmeler · içerik · durum çubuğu.
struct StudioView: View {
    @ObservedObject var model: StudioModel
    let onClose: () -> Void

    @State private var draggingSidebar = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(model: model, onClose: onClose)

            HStack(spacing: 0) {
                ActivityRail(model: model)
                Rectangle().fill(Theme.separator).frame(width: 1)

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
        .background(Theme.bg)
        .onDisappear { model.stop() }
    }

    /// Kenar çubuğu genişliği sürüklenerek ayarlanır; değer `.cs/config.json`'a yazılır.
    private var sidebarHandle: some View {
        Rectangle()
            .fill(draggingSidebar ? Theme.accent : Theme.separator)
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

// MARK: - Üst bar

private struct TopBar: View {
    @ObservedObject var model: StudioModel
    let onClose: () -> Void
    @State private var menuOpen = false
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        HStack(spacing: 8) {
            // Trafik ışıklarının şeridi — başlık hemen bitiminde başlar.
            Color.clear.frame(width: 72, height: 1)

            Text("Claude Studio")
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(Theme.text)
                .fixedSize()

            Button { menuOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.text2)
                    Text(model.project.name)
                        .font(Theme.ui(12.5, .medium))
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(menuOpen ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
                ProjectMenu(model: model, onClose: { menuOpen = false; onClose() })
            }

            Text(model.project.displayPath)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .truncationMode(.head)

            Spacer(minLength: 12)

            if model.attentionCount > 0 {
                HStack(spacing: 6) {
                    StatusDot(color: Theme.waiting)
                    Text("\(model.attentionCount) oturum bekliyor")
                }
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.text2)
            }

            if !model.store.config.services.isEmpty {
                SmallButton(title: model.runningServiceCount > 0 ? "Tümünü durdur" : "Servisleri başlat",
                            icon: model.runningServiceCount > 0 ? "stop.fill" : "play.fill") {
                    model.runningServiceCount > 0 ? model.stopAllServices() : model.startAllServices()
                }
            }

            if let version = updater.availableVersion {
                SmallButton(title: "Güncelle · \(version)", icon: "arrow.down.circle") {
                    SettingsWindow.show()
                }
            }

            IconButton(icon: "gearshape", help: "Ayarlar (⌘,)") {
                SettingsWindow.show()
            }
        }
        .padding(.leading, 0)
        .padding(.trailing, 10)
        .frame(height: 42)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

private struct ProjectMenu: View {
    @ObservedObject var model: StudioModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            item("Finder'da göster", icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.project.url])
            }
            item("Terminalde aç", icon: "terminal") {
                Shell.runDetached("open -a Terminal \(Shell.quoted(model.project.path))")
            }
            item("Proje ayarları (.cs)", icon: "gearshape") {
                Paths.ensure(Paths.csDir(model.project))
                NSWorkspace.shared.open(Paths.csDir(model.project))
            }
            Divider().padding(.vertical, 5)
            item("Projeyi kapat", icon: "xmark", tone: Theme.danger) { onClose() }
        }
        .padding(6)
        .frame(width: 230)
    }

    private func item(_ title: String, icon: String, tone: Color = Theme.text,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HoverRow(padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)) {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 11)).frame(width: 14)
                    Text(title).font(Theme.ui(12.5))
                    Spacer()
                }
                .foregroundStyle(tone)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Etkinlik rayı

private struct ActivityRail: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        VStack(spacing: 4) {
            ForEach(StudioModel.Pane.allCases) { pane in
                button(pane)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .background(Theme.chrome)
    }

    private func button(_ pane: StudioModel.Pane) -> some View {
        let selected = model.pane == pane
        return Button { model.pane = pane } label: {
            Image(systemName: pane.icon)
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(selected ? Theme.text : Theme.text3)
                .frame(width: 46, height: 40)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(selected ? Theme.accent : .clear)
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

// MARK: - Sekme çubuğu

private struct TabBar: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.tabs) { tab in
                    item(tab)
                }
            }
        }
        .frame(height: 34)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }

    private func item(_ tab: StudioTab) -> some View {
        let selected = model.activeTabID == tab.id
        return HStack(spacing: 7) {
            StatusDot(color: dotColor(tab), size: 5)
            Text(tab.title)
                .font(Theme.ui(12))
                .foregroundStyle(selected ? Theme.text : Theme.text2)
                .lineLimit(1)
            Button { model.closeTab(id: tab.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.text3)
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: 34)
        .background(selected ? Theme.bg : Color.clear)
        .overlay(alignment: .top) {
            Rectangle().fill(selected ? Theme.accent : .clear).frame(height: 2)
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.activeTabID = tab.id }
    }

    private func dotColor(_ tab: StudioTab) -> Color {
        switch tab.kind {
        case .session:
            switch model.engine.attention[tab.terminalKey] ?? .idle {
            case .working: return Theme.running
            case .waiting: return Theme.waiting
            case .idle:    return Theme.idle
            }
        case .service:
            guard let id = UUID(uuidString: tab.ref) else { return Theme.idle }
            return (model.engine.serviceStatus[id] ?? .stopped).color
        case .terminal:     return model.engine.isLive(tab.terminalKey) ? Theme.running : Theme.idle
        case .skill, .cron: return Theme.text3
        }
    }
}

// MARK: - Durum çubuğu

private struct StatusBar: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        HStack(spacing: 16) {
            Text(model.project.name).foregroundStyle(Theme.text2)
            Spacer()
            Text("\(model.openSessions.count) oturum")
            Text("\(model.runningServiceCount)/\(model.store.config.services.count) servis")
            if let next = model.store.nextRun {
                Text("sonraki: \(next.skill) · \(next.date.shortStamp)")
            }
            if !Tmux.isAvailable {
                Text("tmux yok — oturumlar kalıcı değil").foregroundStyle(Theme.danger)
            }
        }
        .font(Theme.mono(10.5))
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}
