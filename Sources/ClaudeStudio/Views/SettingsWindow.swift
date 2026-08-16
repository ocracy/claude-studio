import SwiftUI
import AppKit

/// Tercihler penceresi (⌘,). Tek pencere; ikinci kez çağrılırsa öne gelir.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.title = "Ayarlar"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: SettingsView())
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }
}

/// İki sütun: solda bölümler, sağda o bölümün ayarları. Her satır tek bir şey
/// yapar ve ne yaptığını altında bir cümleyle söyler.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared
    @State private var section: Section = .bildirim

    private enum Section: String, CaseIterable, Identifiable {
        case bildirim, terminal, oturumlar, hakkinda
        var id: String { rawValue }

        var title: String {
            switch self {
            case .bildirim:  return "Bildirim ve ses"
            case .terminal:  return "Terminal"
            case .oturumlar: return "Oturumlar"
            case .hakkinda:  return "Hakkında"
            }
        }
        var icon: String {
            switch self {
            case .bildirim:  return "bell"
            case .terminal:  return "terminal"
            case .oturumlar: return "bubble.left.and.bubble.right"
            case .hakkinda:  return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.separator).frame(width: 1)
            content
        }
        .frame(width: 720, height: 460)
        .background(Theme.bg)
    }

    // MARK: - Sol sütun

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 34)
            ForEach(Section.allCases) { item in
                Button { section = item } label: {
                    HoverRow(selected: section == item,
                             padding: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10)) {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon)
                                .font(.system(size: 12))
                                .foregroundStyle(section == item ? Theme.accent : Theme.text3)
                                .frame(width: 16)
                            Text(item.title)
                                .font(Theme.ui(12.5))
                                .foregroundStyle(Theme.text)
                            Spacer()
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(Theme.chrome)
    }

    // MARK: - Sağ sütun

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(Theme.ui(16, .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.bottom, 18)

                switch section {
                case .bildirim:  bildirim
                case .terminal:  terminal
                case .oturumlar: oturumlar
                case .hakkinda:  hakkinda
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bölümler

    private var bildirim: some View {
        VStack(spacing: 0) {
            toggleRow("Claude seni beklerken ses çal",
                      note: "Oturum sırayı sana verdiğinde tek bir ton duyulur.",
                      isOn: $settings.soundEnabled)
            toggleRow("Çalışma bitince ses çal",
                      note: "Zamanlanmış ve arka plan çalışmaları için.",
                      isOn: $settings.soundOnRunFinish)

            row("Ses", note: "Seçtiğin sistem sesi her iki durumda da kullanılır.") {
                HStack(spacing: 8) {
                    Picker("", selection: $settings.soundName) {
                        ForEach(AppSettings.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    SmallButton(title: "Dinle") { Notify.play(settings.soundName) }
                }
            }

            toggleRow("Bildirim balonu göster",
                      note: "Sistem bildirimi olarak kısa bir özet.",
                      isOn: $settings.notifyEnabled)
            toggleRow("Dock simgesinde sayaç",
                      note: "Seni bekleyen oturum sayısı Dock'ta görünür.",
                      isOn: $settings.badgeEnabled, last: true)
        }
        .background(card)
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            row("Yazı tipi boyutu",
                note: "Bundan sonra açılan terminaller bu boyutu kullanır.") {
                HStack(spacing: 8) {
                    Text(String(format: "%.1f", settings.terminalFontSize))
                        .font(Theme.mono(12))
                        .frame(width: 34, alignment: .trailing)
                    Stepper("", value: $settings.terminalFontSize, in: 9...20, step: 0.5)
                        .labelsHidden()
                }
            }

            infoRow("Çok satırlı girdi",
                    note: "Claude Code'da yeni satır için Shift+Enter ya da Option+Enter. Eşleme uygulamada yapılıdır; `/terminal-setup` gerekmez.",
                    last: true)
        }
        .background(card)
    }

    private var oturumlar: some View {
        VStack(spacing: 0) {
            toggleRow("Proje açılınca son oturuma bağlan",
                      note: "Kapatıp açtığında kaldığın yerden devam edersin.",
                      isOn: $settings.autoAttachLastSession)

            infoRow("Kalıcılık",
                    note: "Oturumlar tmux'ta yaşar; uygulama kapansa da sürerler. Bir oturumu kapatırsan kaydı kalır ve aynı isimle, aynı konuşmayla geri açılır.",
                    last: true)
        }
        .background(card)
    }

    private var hakkinda: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Studio")
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.text)
                Text("Projelerin için tek ekran: Claude oturumları, beceriler, zamanlanmış çalışmalar, servisler ve terminaller.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 16)

            row("Sürüm \(updater.currentVersion)", note: updateNote) {
                updateControl
            }

            VStack(alignment: .leading, spacing: 6) {
                detail("Depo", "github.com/\(Updater.repository)")
                detail("tmux", Tmux.path ?? "kurulu değil")
                detail("Ayarlar", Paths.appSupport.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var updateNote: String {
        switch updater.state {
        case .idle:                      return "Yeni sürüm çıktığında buradan kurabilirsin."
        case .checking:                  return "Denetleniyor…"
        case .upToDate:                  return "En güncel sürümdesin."
        case let .available(version, _, _): return "\(version) yayınlandı."
        case let .downloading(progress): return "İndiriliyor… %\(Int(progress * 100))"
        case .installing:                return "Kuruluyor, uygulama yeniden başlayacak…"
        case let .failed(reason):        return reason
        }
    }

    @ViewBuilder private var updateControl: some View {
        switch updater.state {
        case .available:
            SmallButton(title: "Güncelle", icon: "arrow.down.circle", prominent: true) {
                updater.install()
            }
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            SmallButton(title: "Denetle") { updater.check() }
        }
    }

    private func detail(_ key: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(key).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).frame(width: 60, alignment: .leading)
            Text(value).font(Theme.mono(11)).foregroundStyle(Theme.text2)
        }
    }

    // MARK: - Satır bileşenleri

    private var card: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.separator))
    }

    private func toggleRow(_ title: String, note: String,
                           isOn: Binding<Bool>, last: Bool = false) -> some View {
        row(title, note: note, last: last) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
        }
    }

    private func infoRow(_ title: String, note: String, last: Bool = false) -> some View {
        row(title, note: note, last: last) { EmptyView() }
    }

    private func row<Control: View>(_ title: String, note: String, last: Bool = false,
                                    @ViewBuilder control: () -> Control) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.ui(12.5)).foregroundStyle(Theme.text)
                    Text(note)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !last {
                Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 16)
            }
        }
    }
}
