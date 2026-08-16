import Foundation

/// Süreç çalıştırma yardımcıları.
///
/// KRİTİK: GUI uygulamaları launchd'den minimal bir PATH alır — kullanıcının
/// `node`, `claude`, `tmux` kurulumları görünmez. Bu yüzden gerçek PATH bir kez
/// login + interactive zsh'ten alınır (`userPath`) ve spawn edilen her sürece
/// enjekte edilir. `-i` şart: PATH çoğu kurulumda `.zshrc`'de yazar.
enum Shell {

    static let userPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-i", "-c", "print -rn -- $PATH"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                return path
            }
        } catch {}
        return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    /// Adaylardan ilk çalıştırılabilir olanı.
    static func findExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// PATH üzerinden arar (kullanıcının gerçek PATH'i ile).
    static func which(_ name: String) -> String? {
        let r = run("/usr/bin/env", ["sh", "-c", "command -v \(name)"], env: ["PATH": userPath])
        guard r.status == 0 else { return nil }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Tek tırnakla sarar; içteki `'` → `'\''`.
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Senkron çalıştırır; stdout + stderr birleşik döner.
    @discardableResult
    static func run(_ launchPath: String, _ args: [String],
                    env: [String: String]? = nil) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let env {
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            p.environment = merged
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        // waitUntilExit'ten ÖNCE oku — pipe dolarsa süreç bloklanır.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func runAsync(_ launchPath: String, _ args: [String],
                         completion: (@Sendable (Int32, String) -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let r = run(launchPath, args)
            completion?(r.status, r.output)
        }
    }

    /// Çıktısı umursanmayan, beklenmeyen komut.
    static func runDetached(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Portu dinleyen bir süreç var mı? (servis hazırlık kontrolü)
    static func portIsListening(_ port: Int) -> Bool {
        let r = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return r.status == 0 && !r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Portu tutan süreçleri öldürür (dışarıdan başlatılmış servisi durdurmak için).
    static func killPort(_ port: Int) {
        runDetached("lsof -nP -iTCP:\(port) -sTCP:LISTEN -t | xargs -r kill -TERM")
    }
}
