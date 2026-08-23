import Foundation

/// Process helpers.
///
/// CRITICAL: GUI apps inherit a minimal PATH from launchd — the user's `node`,
/// `claude` and `tmux` installs are invisible. The real PATH is therefore
/// captured once from a login + interactive zsh (`userPath`) and injected into
/// every spawned process. `-i` is required: most setups export PATH in `.zshrc`.
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

    /// First executable candidate.
    static func findExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Looks the binary up on PATH (using the user's real PATH).
    static func which(_ name: String) -> String? {
        let r = run("/usr/bin/env", ["sh", "-c", "command -v \(name)"], env: ["PATH": userPath])
        guard r.status == 0 else { return nil }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Wraps in single quotes; inner `'` becomes `'\''`.
    static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs synchronously; returns stdout and stderr combined.
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
        // Read BEFORE waitUntilExit — a full pipe would block the child.
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

    /// Runs a command and reports its output line by line as it arrives.
    ///
    /// `run` hands everything back at the end, which is fine for a status probe
    /// and useless for `brew install ttyd`: that is minutes of silence in front
    /// of someone who pressed a button and has no way to tell it apart from a
    /// hang. Blocking, so callers stay off the main thread — the installer runs
    /// its steps in order and needs each one's exit code before the next.
    @discardableResult
    static func runStreaming(_ launchPath: String, _ args: [String],
                             env: [String: String]? = nil,
                             onLine: @escaping (String) -> Void) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        var merged = ProcessInfo.processInfo.environment
        merged["PATH"] = userPath
        for (k, v) in env ?? [:] { merged[k] = v }
        p.environment = merged

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            onLine("\(error)")
            return -1
        }

        // Read to EOF in chunks rather than `readabilityHandler`: this runs on a
        // background queue already, and a handler would need the same buffering
        // for partial lines with a run loop to keep it alive.
        var buffer = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let index = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer[..<index], encoding: .utf8) ?? ""
                buffer.removeSubrange(...index)
                onLine(line)
            }
        }
        if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty {
            onLine(tail)
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Fire-and-forget command; output is discarded.
    static func runDetached(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Is something listening on the port? (service readiness check)
    static func portIsListening(_ port: Int) -> Bool {
        let r = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return r.status == 0 && !r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Kills whatever holds the port (used to stop externally started services).
    static func killPort(_ port: Int) {
        runDetached("lsof -nP -iTCP:\(port) -sTCP:LISTEN -t | xargs -r kill -TERM")
    }
}
