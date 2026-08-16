import Foundation

/// Oturumların kalıcılığı tmux ile sağlanır: Claude Studio kapansa da oturum
/// yaşamaya devam eder, tekrar açıldığında kaldığı yerden bağlanılır.
///
/// KRİTİK: her zaman sabit `-S <socket>` kullanılır, `-L` KULLANILMAZ — GUI
/// süreci ile login shell farklı `TMUX_TMPDIR` görür, `-L` ile iki ayrı sunucu
/// oluşur. Sabit soket yolu her çağıran için aynıdır.
enum Tmux {

    static let socketPath = "/tmp/claude-studio-\(getuid()).sock"

    static var path: String? { cachedPath }

    private static let cachedPath: String? = Shell.findExecutable([
        "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux",
        "/opt/local/bin/tmux", "/usr/bin/tmux",
    ]) ?? Shell.which("tmux")

    static var isAvailable: Bool { path != nil }

    /// Minimal config. `mouse off` şart: tmux fareyi yakalarsa terminaldeki
    /// metin seçimi bozulur — kaydırmayı uygulama kendisi copy-mode'a yönlendirir.
    static func ensureConfig() {
        let body = """
        set -g status off
        set -sg escape-time 0
        set -g default-terminal "screen-256color"
        set -as terminal-features ",*:RGB"
        set -g history-limit 50000
        set -g destroy-unattached off
        set -g mouse off
        set -g focus-events off
        set -g set-clipboard off
        set -g aggressive-resize off
        """
        try? body.write(to: Paths.tmuxConfig, atomically: true, encoding: .utf8)
        if run(["list-sessions"]).status == 0 {
            _ = run(["source-file", Paths.tmuxConfig.path])
        }
    }

    // MARK: - Oturumlar

    struct Session {
        let name: String
        let projectID: String
        let title: String?
        let claudeSID: String?
        let attached: Bool
        let lastUsed: Date?
    }

    /// Claude Studio'ya ait tüm oturumlar (`@cs_project` etiketi dolu olanlar).
    static func sessions(projectID: String? = nil) -> [Session] {
        let fmt = "#{session_name}\t#{@cs_project}\t#{@cs_title}\t#{@cs_sid}\t#{session_attached}\t#{@cs_used}"
        let r = run(["list-sessions", "-F", fmt])
        guard r.status == 0 else { return [] }
        return r.out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 5, !f[1].isEmpty else { return nil }
            if let projectID, f[1] != projectID { return nil }
            let used = f.count > 5 ? TimeInterval(f[5]) : nil
            return Session(name: f[0],
                           projectID: f[1],
                           title: f[2].nilIfEmpty,
                           claudeSID: f[3].nilIfEmpty,
                           attached: f[4] != "0",
                           lastUsed: used.map { Date(timeIntervalSince1970: $0) })
        }
    }

    static func exists(_ name: String) -> Bool {
        run(["has-session", "-t", name]).status == 0
    }

    static func kill(_ name: String) {
        _ = run(["kill-session", "-t", name])
    }

    static func setOption(_ session: String, _ key: String, _ value: String) {
        _ = run(["set-option", "-t", session, key, value])
    }

    static func touch(_ session: String) {
        setOption(session, "@cs_used", String(Int(Date().timeIntervalSince1970)))
    }

    /// Pencere başlıkları — Claude kendi başlığını OSC ile yazar, oturum
    /// adlarını canlı tutmak için okunur.
    static func paneTitles() -> [String: String] {
        let r = run(["list-panes", "-a", "-F", "#{session_name}\t#{pane_title}"])
        guard r.status == 0 else { return [:] }
        var out: [String: String] = [:]
        for line in r.out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 2 else { continue }
            out[f[0]] = f[1]
        }
        return out
    }

    /// Geçmişte gezinme: `copy-mode -e` en alta inince kendiliğinden çıkar.
    static func scroll(_ session: String, lines: Int, up: Bool) {
        guard lines > 0 else { return }
        if up {
            _ = run(["copy-mode", "-e", "-t", session, ";",
                     "send-keys", "-t", session, "-X", "-N", "\(lines)", "scroll-up"])
        } else {
            _ = run(["send-keys", "-t", session, "-X", "-N", "\(lines)", "scroll-down"])
        }
    }

    // MARK: - Bağlanma komutu

    /// `-A -D`: oturum varsa ona bağlan (eski istemciyi düşür), yoksa `inner`
    /// komutuyla yenisini yarat. Tek çağrı hem "devam et" hem "başlat" demek.
    static func attachCommand(session: String, cols: Int, rows: Int,
                              env: [String: String], inner: String?) -> String {
        var parts = [
            "exec", Shell.quoted(path ?? "tmux"),
            "-S", Shell.quoted(socketPath),
            "-f", Shell.quoted(Paths.tmuxConfig.path),
            "new-session", "-A", "-D",
            "-s", Shell.quoted(session),
            "-x", "\(cols)", "-y", "\(rows)",
        ]
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            parts.append("-e")
            parts.append("\(k)=\(Shell.quoted(v))")
        }
        if let inner { parts.append(Shell.quoted(inner)) }
        return parts.joined(separator: " ")
    }

    // MARK: - Private

    @discardableResult
    private static func run(_ args: [String]) -> (status: Int32, out: String) {
        guard let tmux = path else { return (-1, "") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-S", socketPath] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
