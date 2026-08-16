import SwiftUI
import AppKit

/// Preferences window (⌘,). A single window; calling again brings it forward.
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
        panel.title = "Settings"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: SettingsView())
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = panel
    }
}

/// Two columns: sections on the left, that section's settings on the right. Each
/// row does one thing and says what it does in a sentence underneath.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = Updater.shared
    @State private var section: Section = .notifications

    private enum Section: String, CaseIterable, Identifiable {
        case notifications, terminal, sessions, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .notifications: return "Notifications & sound"
            case .terminal:      return "Terminal"
            case .sessions:      return "Sessions"
            case .about:         return "About"
            }
        }
        var icon: String {
            switch self {
            case .notifications: return "bell"
            case .terminal:      return "terminal"
            case .sessions:      return "bubble.left.and.bubble.right"
            case .about:         return "info.circle"
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

    // MARK: - Left column

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

    // MARK: - Right column

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(section.title)
                    .font(Theme.ui(16, .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.bottom, 18)

                switch section {
                case .notifications: notifications
                case .terminal:      terminal
                case .sessions:      sessions
                case .about:         about
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sections

    private var notifications: some View {
        VStack(spacing: 0) {
            toggleRow("Play a sound when Claude is waiting",
                      note: "One soft tone when a session hands the turn back to you.",
                      isOn: $settings.soundEnabled)
            toggleRow("Play a sound when a run finishes",
                      note: "For scheduled and background runs.",
                      isOn: $settings.soundOnRunFinish)

            row("Sound", note: "The chosen system sound is used in both cases.") {
                HStack(spacing: 8) {
                    Picker("", selection: $settings.soundName) {
                        ForEach(AppSettings.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    SmallButton(title: "Preview") { Notify.play(settings.soundName) }
                }
            }

            toggleRow("Show a notification banner",
                      note: "A short summary as a system notification.",
                      isOn: $settings.notifyEnabled)
            toggleRow("Badge the Dock icon",
                      note: "The number of sessions waiting for you appears on the Dock.",
                      isOn: $settings.badgeEnabled, last: true)
        }
        .background(card)
    }

    private var terminal: some View {
        VStack(spacing: 0) {
            row("Font size",
                note: "Terminals opened from now on use this size.") {
                HStack(spacing: 8) {
                    Text(String(format: "%.1f", settings.terminalFontSize))
                        .font(Theme.mono(12))
                        .frame(width: 34, alignment: .trailing)
                    Stepper("", value: $settings.terminalFontSize, in: 9...20, step: 0.5)
                        .labelsHidden()
                }
            }

            infoRow("Multi-line input",
                    note: "Press Shift+Enter or Option+Enter for a new line in Claude Code. The mapping is built into the app; `/terminal-setup` is not needed.",
                    last: true)
        }
        .background(card)
    }

    private var sessions: some View {
        VStack(spacing: 0) {
            toggleRow("Reattach to the last session on open",
                      note: "Close and reopen a project and you continue where you left off.",
                      isOn: $settings.autoAttachLastSession)

            infoRow("Persistence",
                    note: "Sessions live in tmux and outlive the app. Closing one keeps its record, so it reopens under the same name with the same conversation.",
                    last: true)
        }
        .background(card)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Studio")
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.text)
                Text("One screen for your projects: Claude sessions, skills, scheduled runs, services and terminals.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 16)

            row("Version \(updater.currentVersion)", note: updateNote) {
                updateControl
            }

            VStack(alignment: .leading, spacing: 6) {
                detail("Repository", "github.com/\(Updater.repository)")
                detail("tmux", Tmux.path ?? "not installed")
                detail("Support", Paths.appSupport.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private var updateNote: String {
        switch updater.state {
        case .idle:                      return "When a new version ships you can install it here."
        case .checking:                  return "Checking…"
        case .upToDate:                  return "You are on the latest version."
        case let .available(version, _, _): return "\(version) is available."
        case let .downloading(progress): return "Downloading… \(Int(progress * 100))%"
        case .installing:                return "Installing; the app will restart…"
        case let .failed(reason):        return reason
        }
    }

    @ViewBuilder private var updateControl: some View {
        switch updater.state {
        case .available:
            SmallButton(title: "Update", icon: "arrow.down.circle", prominent: true) {
                updater.install()
            }
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            SmallButton(title: "Check") { updater.check() }
        }
    }

    private func detail(_ key: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(key).font(Theme.ui(11.5)).foregroundStyle(Theme.text3).frame(width: 60, alignment: .leading)
            Text(value).font(Theme.mono(11)).foregroundStyle(Theme.text2)
        }
    }

    // MARK: - Row components

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
