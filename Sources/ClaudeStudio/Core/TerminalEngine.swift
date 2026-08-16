import Foundation
import Combine
import Darwin
import AppKit
import SwiftTerm

/// tmux destekli terminaller işaretlenir: kaydırma tekerleği tmux copy-mode'a
/// yönlendirilir, çünkü geçmiş tmux'ta durur — SwiftTerm yalnız tmux'un çizdiği
/// tek ekranı görür.
final class StudioTerminalView: LocalProcessTerminalView {
    var tmuxSession: String?
}

/// Uygulamanın çalışma zamanı çekirdeği: terminal görünümü önbelleği, süreç
/// yaşam döngüsü, tmux oturumları ve Claude dikkat göstergeleri.
///
/// Terminal görünümleri **burada yaşar**, görünüm katmanında değil. Sekme
/// değiştirmek yalnız hangi NSView'ın ekleneceğini seçmektir; süreç, kaydırma
/// konumu ve tampon dokunulmadan kalır — geçişin anında olmasının sebebi budur.
@MainActor
final class TerminalEngine: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {

    /// Servis kimliği → durum.
    @Published var serviceStatus: [UUID: ServiceStatus] = [:]
    /// Oturum adı → Claude'un anlık durumu (hook köprüsünden).
    @Published var attention: [String: Attention] = [:]
    /// tmux oturum adı → Claude'un yazdığı canlı başlık.
    @Published var paneTitles: [String: String] = [:]
    /// Sekme anahtarı → Claude'un kendi oturum kimliği (`--resume` için).
    @Published var claudeSIDs: [String: String] = [:]

    private var views: [String: StudioTerminalView] = [:]
    /// Spawn çağrıldı ama süreç henüz `running` değil — çift spawn koruması.
    private var starting: Set<String> = []
    /// Görünmez çalışan komutlar (bitince ses çıkarır).
    private var backgroundKeys: [String: String] = [:]
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var lastScrollSend = Date.distantPast
    private var pollTimer: Timer?

    private lazy var baseEnvironment: [String] = Self.buildEnvironment()
    /// Bildirim metinleri için bağlam; `StudioModel` doldurur.
    var projectName = ""
    var sessionTitles: [String: String] = [:]

    override init() {
        super.init()
        Tmux.ensureConfig()
        HookBridge.installIfNeeded()
        installScrollMonitor()
        installKeyMonitor()
        startPolling()
    }

    // MARK: - Görünüm önbelleği

    func view(for key: String) -> StudioTerminalView {
        if let existing = views[key] { return existing }
        // Cömert başlangıç çerçevesi: SwiftTerm ilk spawn'da PTY boyutunu
        // buradan hesaplar, layout öncesi 0×0'a düşmesin.
        let v = StudioTerminalView(frame: NSRect(x: 0, y: 0, width: 1200, height: 720))
        v.processDelegate = self
        v.font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(AppSettings.shared.terminalFontSize), weight: .regular)
        v.nativeBackgroundColor = Theme.nsTermBG
        v.nativeForegroundColor = Theme.nsTermFG
        v.getTerminal().changeScrollback(10_000)
        views[key] = v
        return v
    }

    func isLive(_ key: String) -> Bool { views[key]?.process?.running == true }

    func hasView(_ key: String) -> Bool { views[key] != nil }

    /// Görünümü ve sürecini tamamen bırakır (sekme kapatıldığında).
    func discard(_ key: String) {
        guard let v = views.removeValue(forKey: key) else { return }
        if v.process?.running == true { kill(v.process.shellPid, SIGTERM) }
        v.removeFromSuperview()
        HookBridge.clearState(key)
    }

    // MARK: - Claude oturumu (tmux ile kalıcı)

    /// Oturuma bağlanır; yoksa yaratır. `-A -D` sayesinde tek çağrı hem
    /// "kaldığın yerden devam et" hem "yeni başlat" anlamına gelir.
    func startSession(key: String, session: String, project: Project,
                      title: String, resumeSID: String? = nil,
                      initialPrompt: String? = nil, autoRun: Bool = false,
                      extraEnv: [String: String] = [:]) {
        guard !starting.contains(key) else { return }
        let v = view(for: key)
        if v.process?.running == true { return }
        starting.insert(key)

        let cols = max(80, v.getTerminal().cols)
        let rows = max(24, v.getTerminal().rows)

        // Hook ortamı hem PTY'ye hem tmux oturumuna geçer — oturum yeniden
        // yaratılsa bile bağlam korunur.
        var hookEnv = ["CS_TAB_ID": key, "CS_TAB_NAME": title, "CS_PROJECT": project.name]
        for (k, v) in extraEnv { hookEnv[k] = v }

        var env = baseEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")
        for (k, value) in hookEnv { env.append("\(k)=\(value)") }

        let trimmed = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let claudeCommand: String
        if let sid = resumeSID {
            claudeCommand = "claude --resume \(Shell.quoted(sid))"
        } else if let prompt = trimmed, !prompt.isEmpty, autoRun {
            claudeCommand = "claude \(Shell.quoted(prompt))"
        } else {
            claudeCommand = "claude"
        }
        let inner = "cd \(Shell.quoted(project.path)) && exec \(claudeCommand)"

        let wrapped: String
        if Tmux.isAvailable {
            v.tmuxSession = session
            wrapped = Tmux.attachCommand(session: session, cols: cols, rows: rows,
                                         env: hookEnv, inner: inner)
        } else {
            // tmux yoksa kalıcı olmayan düz spawn — uygulama yine çalışır.
            wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; \(inner)"
        }

        v.startProcess(executable: "/bin/zsh", args: ["-l", "-i", "-c", wrapped],
                       environment: env, execName: nil)
        after(1.0) { [weak self] in self?.starting.remove(key) }

        if Tmux.isAvailable {
            after(0.6) {
                Tmux.setOption(session, "@cs_project", project.shortID)
                Tmux.setOption(session, "@cs_title", title)
                Tmux.touch(session)
            }
        }

        // Otomatik çalıştırma kapalıysa komut kutuya yazılır, gönderilmez —
        // kullanıcı görüp kendi onaylar.
        if resumeSID == nil, !autoRun, let prompt = trimmed, !prompt.isEmpty {
            after(1.6) { [weak self] in self?.send(key: key, text: prompt) }
        }
    }

    /// Elle açılan kabuk. tmux varsa o da kalıcıdır — uygulama kapanıp açılınca
    /// aynı dizinde, aynı geçmişle geri gelir.
    func startShell(key: String, session: String, project: Project, cwd: String, title: String) {
        guard !starting.contains(key) else { return }
        let v = view(for: key)
        if v.process?.running == true { return }
        starting.insert(key)

        let expanded = (cwd as NSString).expandingTildeInPath
        let cols = max(80, v.getTerminal().cols)
        let rows = max(24, v.getTerminal().rows)
        var env = baseEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")

        let inner = "cd \(Shell.quoted(expanded)) && exec /bin/zsh -l -i"
        let wrapped: String
        if Tmux.isAvailable {
            v.tmuxSession = session
            wrapped = Tmux.attachCommand(session: session, cols: cols, rows: rows,
                                         env: [:], inner: inner)
        } else {
            wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; \(inner)"
        }
        v.startProcess(executable: "/bin/zsh", args: ["-l", "-i", "-c", wrapped],
                       environment: env, execName: nil)
        after(1.0) { [weak self] in self?.starting.remove(key) }
        if Tmux.isAvailable {
            after(0.6) {
                Tmux.setOption(session, "@cs_project", project.shortID)
                Tmux.setOption(session, "@cs_title", title)
                Tmux.setOption(session, "@cs_kind", "shell")
            }
        }
    }

    // MARK: - Servisler (doğrudan PTY)

    func startService(_ service: Service, project: Project) {
        let key = service.id.uuidString
        let v = view(for: key)
        if v.process?.running == true { return }

        serviceStatus[service.id] = .starting
        let cwd = service.resolvedCwd(projectPath: project.path)
        feed(key: key, "\r\n\u{1B}[2m— başlatılıyor: \(service.command)  (\(cwd)) —\u{1B}[0m\r\n")

        let cols = max(80, v.getTerminal().cols)
        let rows = max(24, v.getTerminal().rows)
        // stty: ilk spawn'da PTY boyutunu içeriden damgalar; SwiftTerm'in
        // layout sonrası TIOCSWINSZ'i yine kazanır.
        let wrapped = "stty cols \(cols) rows \(rows) 2>/dev/null; "
            + "cd \(Shell.quoted(cwd)) && \(service.command)"

        var env = baseEnvironment
        env.append("COLUMNS=\(cols)")
        env.append("LINES=\(rows)")
        v.startProcess(executable: "/bin/zsh", args: ["-l", "-i", "-c", wrapped],
                       environment: env, execName: nil)

        if let port = service.port {
            checkReadiness(service.id, port: port, attempt: 0)
        } else {
            after(1.2) { [weak self] in
                guard let self, self.serviceStatus[service.id] == .starting else { return }
                self.serviceStatus[service.id] = self.isLive(key) ? .running : .crashed
            }
        }
    }

    /// Kibar durdurma: PTY'ye Ctrl-C → 3 sn → SIGTERM → 3 sn → SIGKILL.
    func stopService(_ service: Service) {
        let key = service.id.uuidString
        if let v = views[key], v.process?.running == true {
            serviceStatus[service.id] = .stopping
            let pid = v.process.shellPid
            v.process.send(data: ArraySlice([0x03]))
            after(3) { [weak self] in
                guard let self, self.views[key]?.process?.running == true else { return }
                kill(pid, SIGTERM)
                self.after(3) { [weak self] in
                    guard let self, self.views[key]?.process?.running == true else { return }
                    kill(pid, SIGKILL)
                }
            }
            return
        }
        // Dışarıdan başlatılmış servis: portu boşalt.
        if serviceStatus[service.id] == .external, let port = service.port {
            serviceStatus[service.id] = .stopping
            Shell.killPort(port)
            after(1.5) { [weak self] in self?.refreshExternalStatuses([service]) }
        }
    }

    func restartService(_ service: Service, project: Project) {
        stopService(service)
        after(1.0) { [weak self] in self?.startService(service, project: project) }
    }

    /// Uygulama başlatmadığı hâlde portu dinleyen servisleri işaretler.
    func refreshExternalStatuses(_ services: [Service]) {
        let probes = services.compactMap { s -> (UUID, Int)? in
            guard let port = s.port else { return nil }
            let status = serviceStatus[s.id] ?? .stopped
            return (status == .stopped || status == .external || status == .stopping)
                ? (s.id, port) : nil
        }
        guard !probes.isEmpty else { return }
        Task.detached(priority: .utility) {
            var live: [UUID: Bool] = [:]
            for (id, port) in probes { live[id] = Shell.portIsListening(port) }
            let result = live
            await MainActor.run {
                for (id, listening) in result {
                    let current = self.serviceStatus[id] ?? .stopped
                    guard current == .stopped || current == .external || current == .stopping
                    else { continue }
                    self.serviceStatus[id] = listening ? .external : .stopped
                }
            }
        }
    }

    private func checkReadiness(_ id: UUID, port: Int, attempt: Int) {
        guard attempt < 40 else { return }
        after(0.5) { [weak self] in
            guard let self, self.serviceStatus[id] == .starting else { return }
            Task.detached(priority: .utility) {
                let up = Shell.portIsListening(port)
                await MainActor.run {
                    guard self.serviceStatus[id] == .starting else { return }
                    if up { self.serviceStatus[id] = .running }
                    else { self.checkReadiness(id, port: port, attempt: attempt + 1) }
                }
            }
        }
    }

    // MARK: - Tek seferlik komut

    /// Komutu görünmez bir PTY'de çalıştırır; bitince ses + bildirim verir.
    func runInBackground(name: String, command: String, cwd: String) {
        let key = "bg:\(UUID().uuidString)"
        backgroundKeys[key] = name
        let v = view(for: key)
        let expanded = (cwd as NSString).expandingTildeInPath
        var env = baseEnvironment
        env.append("COLUMNS=120")
        env.append("LINES=40")
        v.startProcess(executable: "/bin/zsh",
                       args: ["-l", "-i", "-c", "cd \(Shell.quoted(expanded)) && \(command)"],
                       environment: env, execName: nil)
    }

    // MARK: - Girdi

    func send(key: String, text: String, enter: Bool = false) {
        guard let v = views[key], v.process?.running == true else { return }
        var bytes = Array(text.utf8)
        if enter { bytes.append(0x0D) }
        v.process.send(data: ArraySlice(bytes))
    }

    func feed(key: String, _ ansi: String) {
        view(for: key).getTerminal().feed(text: ansi)
    }

    /// Ekranı temizler ama geçmişi silmez (`reset()` geçmişi siler — kullanma).
    func clear(key: String) {
        guard let v = views[key] else { return }
        v.getTerminal().softReset()
        v.getTerminal().feed(text: "\u{1B}[2J\u{1B}[H")
        v.needsDisplay = true
    }

    // MARK: - İzleme

    /// Hook durum dosyalarını ve tmux başlıklarını düşük frekansla yoklar.
    /// Dosya izleyicisi yerine yoklama: launchd/tmux tarafı uygulamadan bağımsız
    /// yazar, 1,5 sn'lik tur hem ucuz hem yeterince canlı.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in self.poll() }
        }
    }

    private func poll() {
        let states = HookBridge.readAll()
        var next: [String: Attention] = [:]
        var sids: [String: String] = [:]
        for (key, state) in states {
            switch state.state {
            case "working": next[key] = .working
            case "waiting": next[key] = .waiting
            default:        next[key] = .idle
            }
            if let sid = state.sid, !sid.isEmpty { sids[key] = sid }
        }

        // Bekleyen duruma GEÇİŞTE tek bildirim — her turda değil.
        for (key, value) in next where value == .waiting && attention[key] != .waiting {
            if attention[key] != nil {
                AppSettings.shared.announceWaiting(session: sessionTitles[key] ?? "Claude",
                                                  project: projectName)
            }
        }
        attention = next
        claudeSIDs.merge(sids) { _, new in new }

        if AppSettings.shared.badgeEnabled {
            Notify.badge(next.values.filter { $0 == .waiting }.count)
        }

        guard Tmux.isAvailable else { return }
        Task.detached(priority: .utility) {
            let titles = Tmux.paneTitles()
            await MainActor.run { self.paneTitles = titles }
        }
    }

    /// Fare tekerleği: tmux destekli terminallerde geçmiş tmux'ta durduğu için
    /// olay copy-mode'a çevrilir ve YUTULUR — SwiftTerm'in kendi (boş) kaydırması
    /// çalışırsa ekran yerinde titrer.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self,
                      event.scrollingDeltaY != 0,
                      let hit = event.window?.contentView?.hitTest(event.locationInWindow),
                      let terminal = Self.enclosingTerminal(hit),
                      let session = terminal.tmuxSession
                else { return false }

                let now = Date()
                if now.timeIntervalSince(self.lastScrollSend) >= 0.03 {
                    self.lastScrollSend = now
                    let up = event.scrollingDeltaY > 0
                    DispatchQueue.global(qos: .userInteractive).async {
                        Tmux.scroll(session, lines: 3, up: up)
                    }
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    /// Claude Code'da çok satırlı girdi: Shift+Enter → `\` + CR, Option+Enter →
    /// ESC + CR. tmux içinde `/terminal-setup` çalışamadığından bu eşleme
    /// uygulamanın kendisinde yapılır.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let view = NSApp.keyWindow?.firstResponder as? LocalProcessTerminalView,
                      event.keyCode == 36 || event.keyCode == 76,   // Return / Enter
                      view.process?.running == true
                else { return false }

                if event.modifierFlags.contains(.shift) {
                    view.process.send(data: ArraySlice([0x5C, 0x0D]))
                    return true
                }
                if event.modifierFlags.contains(.option) {
                    view.process.send(data: ArraySlice([0x1B, 0x0D]))
                    return true
                }
                return false
            }
            return consumed ? nil : event
        }
    }

    /// Verilen görünümden yukarı doğru ilk terminal görünümü.
    private static func enclosingTerminal(_ view: NSView) -> StudioTerminalView? {
        var node: NSView? = view
        while let current = node {
            if let terminal = current as? StudioTerminalView { return terminal }
            node = current.superview
        }
        return nil
    }

    // MARK: - Delegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // LocalProcessTerminalView TIOCSWINSZ'i kendisi uygular.
    }

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard let view = source as? StudioTerminalView,
                  let key = self.views.first(where: { $0.value === view })?.key else { return }

            if let name = self.backgroundKeys.removeValue(forKey: key) {
                let ok = (exitCode ?? 0) == 0
                AppSettings.shared.announceFinished(
                    title: name,
                    detail: ok ? "Tamamlandı." : "Başarısız (çıkış \(exitCode ?? -1)).",
                    ok: ok)
                self.views.removeValue(forKey: key)
                return
            }

            if let id = UUID(uuidString: key) {
                let previous = self.serviceStatus[id] ?? .stopped
                let code = exitCode ?? 0
                if previous == .stopping || code == 0 {
                    self.serviceStatus[id] = .stopped
                } else {
                    self.serviceStatus[id] = .crashed
                    self.feed(key: key, "\r\n\u{1B}[31m— süreç \(code) koduyla sonlandı —\u{1B}[0m\r\n")
                    AppSettings.shared.announceFinished(title: "Servis durdu",
                                                        detail: "Çıkış kodu \(code).", ok: false)
                }
            }
        }
    }

    // MARK: - Yardımcılar

    private func after(_ seconds: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(block) }
    }

    /// Spawn edilecek süreçlerin ortamı: kullanıcının gerçek PATH'i + terminal
    /// yetenek bildirimleri.
    private static func buildEnvironment() -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        env.removeAll { $0.hasPrefix("PATH=") }
        env.append("PATH=\(Shell.userPath)")
        env.append("TERM_PROGRAM=ClaudeStudio")
        env.append("COLORTERM=truecolor")
        // Claude Code'un çizim titremesini kapatan bayrak — Deck'te de böyle.
        env.append("CLAUDE_CODE_NO_FLICKER=0")
        if let lang = ProcessInfo.processInfo.environment["LANG"] {
            env.removeAll { $0.hasPrefix("LANG=") }
            env.append("LANG=\(lang)")
        } else {
            env.append("LANG=en_US.UTF-8")
        }
        return env
    }
}
