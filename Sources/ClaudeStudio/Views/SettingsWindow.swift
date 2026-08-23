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
    @ObservedObject private var bridge = PhoneBridge.shared
    /// The walkthrough is collapsed by default — it is six paragraphs nobody needs
    /// to read twice, and it opens by itself while the setup is incomplete.
    @State private var guideOpen = false
    @State private var section: Section = .notifications
    @State private var showToken = false
    @State private var copied = false
    @State private var installSheet = false

    private enum Section: String, CaseIterable, Identifiable {
        case notifications, terminal, sessions, phone, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .notifications: return "Notifications & sound"
            case .terminal:      return "Terminal"
            case .sessions:      return "Sessions"
            case .phone:         return "Phone"
            case .about:         return "About"
            }
        }
        var icon: String {
            switch self {
            case .notifications: return "bell"
            case .terminal:      return "terminal"
            case .sessions:      return "bubble.left.and.bubble.right"
            case .phone:         return "iphone"
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
                case .phone:         phone
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

    // MARK: - Phone

    /// Point the phone's camera at the code and it is set up — no address to
    /// type, no token to copy. The phone runs nothing; it types into the
    /// sessions already running here.
    private var phone: some View {
        VStack(alignment: .leading, spacing: 18) {
            meshCard
            bridgeCard
            guideCard
        }
        .onAppear {
            bridge.refresh()
            // Look properly, not just at the files: the mesh is the thing that is
            // usually wrong, and its state is not visible anywhere else in the app.
            bridge.check()
            // Open the walkthrough by itself while something is still missing: that
            // is exactly when someone needs it, and it is also when they have the
            // least idea that it exists.
            if !bridge.mesh.isConnected || !bridge.isInstalled { guideOpen = true }
        }
        .sheet(isPresented: $installSheet) {
            PhoneInstallSheet(bridge: bridge) { installSheet = false }
        }
    }

    // MARK: The private network

    /// The phone reaches this Mac over a private mesh network and nothing else — the
    /// bridge binds to that address alone. Its state belongs at the top of this
    /// screen: when it is down everything below it is dead, and the reason is not
    /// visible from anywhere else in the app.
    private var meshCard: some View {
        VStack(spacing: 0) {
            row(meshTitle, note: meshNote, last: checkAnswer == nil) {
                HStack(spacing: 8) {
                    if bridge.mesh.isInstalled && !bridge.mesh.isConnected {
                        SmallButton(title: "Sign in", icon: "person.badge.key",
                                    prominent: true) { bridge.connectMesh() }
                    }
                    if !bridge.mesh.isInstalled {
                        SmallButton(title: "Netbird", icon: "arrow.up.forward") {
                            NSWorkspace.shared.open(URL(string: "https://netbird.io/download")!)
                        }
                        SmallButton(title: "Tailscale", icon: "arrow.up.forward") {
                            NSWorkspace.shared.open(URL(string: "https://tailscale.com/download")!)
                        }
                    }
                    if bridge.checkState == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        SmallButton(title: "Check") { bridge.check() }
                    }
                }
            }

            // The answer, in the tool's own words. Without it, checking while
            // signed out changes nothing on screen — which is what made the
            // button look broken exactly when it was the only thing to press.
            if let answer = checkAnswer {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: bridge.mesh.isConnected
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(bridge.mesh.isConnected ? Theme.running : Theme.warning)
                    Text(answer)
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(card)
    }

    private var checkAnswer: String? {
        if case .done(let message) = bridge.checkState { return message }
        return nil
    }

    private var meshTitle: String {
        guard let tool = bridge.mesh.tool else { return "Private network — not set up" }
        return bridge.mesh.isConnected
            ? "\(tool.name) is connected"
            : "\(tool.name) is installed but signed out"
    }

    private var meshNote: String {
        guard let tool = bridge.mesh.tool else {
            return "Your phone and this Mac have to sit on the same private network. "
                 + "Install Netbird or Tailscale here and the matching app on your phone, "
                 + "then sign both into one account: this Mac gets a fixed private address "
                 + "the phone can reach from anywhere, with no port opened on your router."
        }
        if let address = bridge.mesh.address {
            var note = "This Mac is \(address) on your \(tool.name) network. Everything the "
                     + "phone sends travels inside that tunnel; nothing is exposed to the internet."
            if tool == .netbird {
                note += " Netbird sessions expire after a day or so — if the phone suddenly "
                      + "stops connecting, this is almost always why. Sign in again here."
            }
            return note
        }
        return "Sign in to bring the tunnel up. It opens \(tool.name)'s sign-in page in your "
             + "browser; once the network is up the bridge starts by itself within half a minute."
    }

    // MARK: The bridge service

    private var bridgeCard: some View {
        VStack(spacing: 0) {
            row(bridgeTitle, note: bridgeNote) {
                if bridge.isInstalled {
                    Toggle("", isOn: Binding(get: { bridge.isEnabled },
                                             set: { bridge.setEnabled($0) }))
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .labelsHidden()
                } else {
                    // One button, and it does the whole thing. What used to be
                    // here was a paragraph asking for a shell script inside a git
                    // checkout that an installed app does not have.
                    SmallButton(title: "Install", icon: "arrow.down.circle",
                                prominent: true) {
                        installSheet = true
                        bridge.install()
                    }
                }
            }

            if bridge.isInstalled {
                let missing = bridge.missingRequirements
                if !missing.isEmpty {
                    row("Missing: \(missing.map(\.name).joined(separator: ", "))",
                        note: "The service cannot run without \(missing.count == 1 ? "it" : "them"). "
                            + missing.map { "\($0.name) \($0.why)" }.joined(separator: "; ") + ".") {
                        SmallButton(title: "Install", prominent: true) {
                            installSheet = true
                            bridge.install()
                        }
                    }
                }
            }

            if bridge.isInstalled && bridge.mesh.isConnected && !bridge.isRunning {
                row("The service is not listening",
                    note: "The agent waits 30 seconds between attempts, so it lags behind the "
                        + "network coming back. Restart it instead of waiting.") {
                    SmallButton(title: "Restart", icon: "arrow.clockwise", prominent: true) {
                        bridge.restart()
                    }
                }
            }

            if let url = bridge.connectURL, bridge.isRunning {
                VStack(spacing: 12) {
                    if let code = bridge.qrImage(side: 180) {
                        Image(nsImage: code)
                            .interpolation(.none)          // keep the modules crisp
                            .frame(width: 180, height: 180)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.white))
                    }

                    VStack(spacing: 3) {
                        Text("Scan with your phone's camera, then add it to the Home Screen.")
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.text3)
                        // Which Mac, and by what name. On a phone that carries two
                        // of these, the name IS the difference between them — and
                        // it is also why the app survives a changed address.
                        Text("\(PhoneInstaller.machineName) · \(bridge.mesh.host ?? "—")")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.text3)
                    }

                    HStack(spacing: 8) {
                        SmallButton(title: showToken ? "Hide link" : "Show link") {
                            showToken.toggle()
                        }
                        SmallButton(title: copied ? "Copied" : "Copy link",
                                    icon: copied ? "checkmark" : "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                    }

                    if showToken {
                        Text(url)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.text2)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)

                Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 16)
            }

            row("New link",
                note: "Replaces the token and restarts the service. Use it if a phone is lost — every device has to scan again.",
                last: true) {
                SmallButton(title: "Replace") { bridge.rotateToken(); showToken = false }
                    .disabled(!bridge.isInstalled)
            }
        }
        .background(card)
    }

    // MARK: How to set it up

    /// The whole path, in order. Every step of it happens somewhere else — a browser,
    /// a terminal, the phone's own Settings app — and none of those places can tell
    /// you what the next one is.
    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Setting this up, step by step")
                    .font(Theme.ui(12.5, .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                SmallButton(title: guideOpen ? "Hide" : "Show") { guideOpen.toggle() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if guideOpen {
                Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 16)

                VStack(alignment: .leading, spacing: 14) {
                    step(1, "Put both devices on one private network",
                         "Install Netbird (netbird.io) or Tailscale (tailscale.com) on this Mac "
                       + "and the matching app on your phone, then sign both into the same "
                       + "account. Either one gives this Mac a fixed private address the phone "
                       + "can reach from any network, without opening a port on your router. "
                       + "Pick one — you do not need both.")

                    step(2, "Press Install above",
                         "Everything on this Mac happens there: what the bridge needs is "
                       + "installed through Homebrew, an access token is generated and a "
                       + "background service is registered, so your sessions stay reachable "
                       + "even while this app is closed. Pressing it again later is safe and "
                       + "keeps the token every phone already scanned.")

                    step(3, "Scan the QR code above with the phone's camera",
                         "The code carries the address and the token together, so there is "
                       + "nothing to type. It lands on a setup page served over plain HTTP — "
                       + "that page exists only to hand over the certificate in the next step.")

                    step(4, "Trust the certificate, once",
                         "Tap the link on the setup page to download the root certificate. "
                       + "On iOS: Settings → Profile Downloaded → Install, then Settings → "
                       + "General → About → Certificate Trust Settings and turn it on. "
                       + "On Android: Settings → Security → Encryption & credentials → "
                       + "Install a certificate → CA certificate. Notifications, offline use "
                       + "and installing as an app all need HTTPS, which is what this unlocks.")

                    step(5, "Add it to the Home Screen",
                         "iOS: Share → Add to Home Screen, from Safari — Chrome cannot do it. "
                       + "Android: the browser offers \"Install app\". This is not cosmetic: "
                       + "iOS delivers push notifications only to a web app on the Home Screen, "
                       + "so without this step the phone stays silent.")

                    step(6, "Turn notifications on inside the phone app",
                         "Open its menu → Notifications & settings, enable them, and send the "
                       + "test notification to confirm. After that you get a push the moment a "
                       + "session finishes and hands the turn back to you.")

                    step(7, "A second Mac? Repeat it there",
                         "Each Mac publishes under its own private name, so the phone installs "
                       + "it as a second app — named after that machine and tinted a different "
                       + "colour — alongside the first. Both keep working; neither replaces the "
                       + "other. You will be asked to trust that Mac's certificate once too.")

                    Text("If the phone ever stops connecting, check the private network first — "
                       + "a signed-out mesh is what almost every failure turns out to be.")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(card)
    }

    private func step(_ number: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(Theme.mono(10.5, .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accent.opacity(0.22)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(Theme.text)
                Text(body)
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
    }

    private var bridgeTitle: String {
        bridge.isRunning ? "Reachable from your phone" : "Phone access"
    }

    private var bridgeNote: String {
        if !bridge.isInstalled {
            return "One button: it installs what the bridge needs (node, ttyd, tmux, through "
                 + "Homebrew), registers a background service that starts with this Mac, and "
                 + "hands you a QR code. Your sessions stay reachable even while this app is closed."
        }
        if bridge.mesh.host == nil {
            return "There is no private address to serve on, so the service exits and retries. It starts by itself once the network above is up."
        }
        if !bridge.isRunning {
            return "The service is stopped. Turn it on to open your sessions to the phone."
        }
        return "Serving as \(bridge.mesh.host ?? "—"):\(PhoneBridge.port) on your private network "
             + "and nowhere else. Your Claude subscription on this Mac does the work; the phone "
             + "only sends keystrokes."
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

// MARK: - Installing phone access

/// What the Install button opens.
///
/// It shows the work rather than a spinner, for one concrete reason: the slow step
/// is `brew install ttyd`, which is minutes long the first time and looks exactly
/// like a hang. Seeing Homebrew's own output is the difference between waiting and
/// force-quitting — and when something does fail, the reason is already on screen
/// instead of buried in a log file nobody was told about.
struct PhoneInstallSheet: View {
    @ObservedObject var bridge: PhoneBridge
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(bridge.installing ? "Setting up phone access…" : "Phone access")
                    .font(Theme.ui(15, .semibold))
                    .foregroundStyle(Theme.text)
                if bridge.installing { ProgressView().controlSize(.small) }
                Spacer()
                Text(PhoneInstaller.machineName)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text3)
            }
            .padding(.bottom, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(bridge.installLog.isEmpty ? "Starting…" : bridge.installLog)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.text2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: bridge.installLog) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.separator)))

            if !bridge.installing {
                Text(bridge.isInstalled
                     ? "Installed. It starts with this Mac; scan the QR code with your phone."
                     : "Not installed. Nothing else on this Mac was changed.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(bridge.isInstalled ? Theme.running : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            HStack(spacing: 10) {
                SmallButton(title: "Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bridge.installLog, forType: .string)
                }
                Spacer()
                SmallButton(title: bridge.installing ? "Hide" : "Done",
                            prominent: !bridge.installing, action: onDismiss)
            }
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.bg)
    }
}
