import Foundation

/// Installing phone access, with no repository and no terminal.
///
/// The bridge is a launchd agent rather than part of this process — sessions stay
/// reachable from the phone while the app is closed — but everything it takes to GET
/// there is the app's job. It used to be a shell script inside the git checkout, which
/// meant: an installed copy of Claude Studio could not offer the feature at all, and
/// for the people who did have the checkout, moving or deleting it killed the agent
/// silently, because launchd simply kept retrying a path that was no longer there.
///
/// So the bridge ships in the bundle, is copied into Application Support and is run
/// from THERE — the same discipline `ProjectBridge` uses for the MCP helper, and for
/// the same reason: an update replaces the whole bundle, and the user may move the app,
/// while a launchd plist records an absolute path.
///
/// Every step reports into a log the sheet shows live. `brew install ttyd` is minutes
/// of silence otherwise, which is indistinguishable from a hang by the person who
/// pressed the button.
@MainActor
enum PhoneInstaller {

    static let label = "com.claudestudio.bridge"

    /// Where the staged copy ended up, or why it did not.
    enum Staged {
        case success(String)
        case failure(String)
    }

    /// A step's outcome, in the words the sheet uses.
    struct Step {
        var title: String
        var ok: Bool
        var detail: String
    }

    // MARK: - Where things are

    nonisolated static var stagedDir: URL { Paths.phoneBridgeDir }
    nonisolated static var serverFile: URL { stagedDir.appendingPathComponent("server.mjs") }
    nonisolated static var runnerFile: URL { Paths.runnersDir.appendingPathComponent("\(label).sh") }
    nonisolated static var plistFile: URL { Paths.launchAgentsDir.appendingPathComponent("\(label).plist") }
    nonisolated static var logFile: URL { Paths.appSupport.appendingPathComponent("bridge.log") }
    nonisolated private static var stampFile: URL { stagedDir.appendingPathComponent(".version") }

    /// The bridge inside the bundle, or — running from a build directory during
    /// development — the `Bridge/` folder of the checkout next to the executable.
    private static var bundledDir: URL? {
        var candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Bridge"),
        ]
        // `.build/debug/ClaudeStudio` → the repository root is three levels up.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
        candidates.append(executable.appendingPathComponent("../../Bridge")
            .standardizedFileURL)
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("server.mjs").path)
        }
    }

    static var isStaged: Bool {
        FileManager.default.fileExists(atPath: serverFile.path)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistFile.path) && isStaged
    }

    // MARK: - Requirements

    /// What the bridge needs on the machine, and whether it is there.
    struct Requirement: Identifiable {
        var id: String { name }
        var name: String
        var path: String?
        var why: String
        var installable: Bool
        var isPresent: Bool { path != nil }
    }

    static func requirements() -> [Requirement] {
        [
            Requirement(name: "node", path: Shell.which("node"),
                        why: "runs the bridge itself", installable: true),
            Requirement(name: "ttyd", path: Shell.which("ttyd"),
                        why: "serves the terminal to the phone", installable: true),
            Requirement(name: "tmux", path: Shell.which("tmux"),
                        why: "holds the sessions the phone attaches to", installable: true),
        ]
    }

    static var homebrew: String? {
        Shell.findExecutable(["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
            ?? Shell.which("brew")
    }

    /// This Mac's name — what the phone calls it once two of these are installed.
    ///
    /// Read once: `scutil` is a process spawn and this is read from a view body,
    /// which redraws far more often than a Mac is renamed.
    nonisolated static let machineName: String = {
        let name = Shell.run("/usr/sbin/scutil", ["--get", "ComputerName"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.nilIfEmpty ?? ProcessInfo.processInfo.hostName
    }()

    // MARK: - Install

    /// Installs, or repairs, phone access. Runs off the main thread and reports each
    /// line as it happens; the completion carries the steps for the summary.
    static func install(log: @escaping @Sendable (String) -> Void,
                        completion: @escaping @Sendable ([Step]) -> Void) {
        let machine = machineName
        let brew = homebrew
        let missing = requirements().filter { !$0.isPresent }

        Task.detached(priority: .userInitiated) {
            var steps: [Step] = []
            func say(_ line: String) { log(line) }

            // 1 — the bridge itself.
            say("→ installing the bridge files…")
            let staged = await MainActor.run { stage() }
            switch staged {
            case .success(let path):
                say("  \(path)")
                steps.append(Step(title: "Bridge files", ok: true, detail: path))
            case .failure(let message):
                say("  ✗ \(message)")
                steps.append(Step(title: "Bridge files", ok: false, detail: message))
                completion(steps)
                return
            }

            // 2 — what it needs to run. Homebrew is the only automated route on
            // macOS; without it the honest answer is the command to paste.
            if missing.isEmpty {
                steps.append(Step(title: "node, ttyd, tmux", ok: true, detail: "already installed"))
            } else if let brew {
                let names = missing.map(\.name)
                say("→ installing \(names.joined(separator: ", ")) with Homebrew…")
                say("  (first time only — this can take a few minutes)")
                let status = Shell.runStreaming(brew, ["install"] + names) { say("  \($0)") }
                let stillMissing = await MainActor.run {
                    requirements().filter { !$0.isPresent }.map(\.name)
                }
                let ok = status == 0 && stillMissing.isEmpty
                say(ok ? "  ✓ installed" : "  ✗ \(stillMissing.joined(separator: ", ")) still missing")
                steps.append(Step(title: names.joined(separator: ", "), ok: ok,
                                  detail: ok ? "installed with Homebrew"
                                             : "brew exited \(status)"))
                if !ok { completion(steps); return }
            } else {
                let names = missing.map(\.name).joined(separator: " ")
                let detail = "Homebrew is not installed. Install it from brew.sh, then "
                    + "run: brew install \(names)"
                say("  ✗ \(detail)")
                steps.append(Step(title: names, ok: false, detail: detail))
                completion(steps)
                return
            }

            // 3 — the token. Generated in one place only: the app builds the QR code
            // from this file, and two writers would eventually disagree.
            let token = await MainActor.run { PhoneBridge.ensureToken() }
            steps.append(Step(title: "Access token", ok: token != nil,
                              detail: token == nil ? "could not be generated"
                                                   : Paths.bridgeToken.path))
            say(token == nil ? "  ✗ no token" : "→ token ready")
            guard token != nil else { completion(steps); return }

            // 4 — the runner and the launchd job.
            say("→ registering the background service…")
            let registered = await MainActor.run { writeRunner(machine: machine) && bootstrap() }
            say(registered ? "  ✓ registered as \(label)"
                           : "  ✗ launchctl refused the job — see \(logFile.path)")
            steps.append(Step(title: "Background service", ok: registered,
                              detail: registered ? "starts with the Mac" : "launchctl failed"))

            say("")
            say(registered
                ? "Done. Scan the QR code with your phone."
                : "Something went wrong; nothing else was changed.")
            completion(steps)
        }
    }

    /// Copies the bundled bridge into Application Support when it is missing or stale.
    @discardableResult
    static func stage() -> Staged {
        guard let source = bundledDir else {
            return .failure("The bridge is missing from the app bundle.")
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let installed = (try? String(contentsOf: stampFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if isStaged, installed == version { return .success(stagedDir.path) }

        do {
            // Replaced wholesale rather than merged: a file dropped in a later
            // version has to disappear, and the only state that lives in here is
            // regenerated on the next start (the icons) — everything durable is
            // outside, in Application Support proper.
            try? FileManager.default.removeItem(at: stagedDir)
            Paths.ensure(stagedDir.deletingLastPathComponent())
            try FileManager.default.copyItem(at: source, to: stagedDir)
            for script in ["cs-attach.sh", "make-cert.sh"] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: stagedDir.appendingPathComponent(script).path)
            }
            try? version.write(to: stampFile, atomically: true, encoding: .utf8)
            return .success(stagedDir.path)
        } catch {
            return .failure("\(error.localizedDescription)")
        }
    }

    /// Re-stages after an app update and rewrites the runner, so an installed agent
    /// picks up a new bridge without anybody pressing anything. Called at launch.
    static func refreshInstalled() {
        guard isInstalled else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let installed = (try? String(contentsOf: stampFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard installed != version else { return }
        guard case .success = stage() else { return }
        _ = writeRunner(machine: machineName)
        // The running agent is still executing the previous copy; restart it into
        // the new one rather than leaving the update to the next reboot.
        Shell.runAsync("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
    }

    // MARK: - The runner

    /// Writes the script launchd runs.
    ///
    /// CRITICAL, and the reason this is generated rather than shipped: the PATH is
    /// EMBEDDED. launchd hands an agent a minimal environment and `#!/bin/zsh -l`
    /// cannot be trusted to read `.zshrc`, so `node`, `ttyd` and `tmux` would all be
    /// invisible to it.
    @discardableResult
    static func writeRunner(machine: String) -> Bool {
        Paths.ensure(Paths.runnersDir)
        let dir = stagedDir.path

        let script = """
        #!/bin/zsh
        # Claude Studio — phone bridge runner.
        # Generated by the app; manual edits are overwritten on the next update.

        export PATH=\(Shell.quoted(Shell.userPath))

        support=\(Shell.quoted(Paths.appSupport.path))
        bridge=\(Shell.quoted(dir))
        export CS_BRIDGE_NAME=\(Shell.quoted(machine))

        token="$(cat \(Shell.quoted(Paths.bridgeToken.path)) 2>/dev/null)"
        [[ -n "$token" ]] || { print -u2 "cs-bridge: no token"; exit 1 }

        # Bind to the private mesh address and nothing else routable. Netbird and
        # Tailscale are equally good — both hand this Mac a stable address the phone
        # can reach — so whichever is up wins. If neither is, there is no address to
        # bind to: exit and let launchd retry, and NEVER fall back to 0.0.0.0.
        #
        # The NAME matters as much as the address. An installed web app is bound to
        # its origin, and a mesh address can change; the name does not.
        mesh_ip=""
        mesh_fqdn=""
        nb_status="$(netbird status 2>/dev/null || true)"
        if [[ -n "$nb_status" ]]; then
          mesh_ip="$(print -r -- "$nb_status" | awk '/NetBird IP:/ { print $3 }' | cut -d/ -f1)"
          mesh_fqdn="$(print -r -- "$nb_status" | awk '/FQDN:/ { print $2 }')"
        fi
        if [[ -z "$mesh_ip" ]]; then
          # The Mac App Store build of Tailscale keeps its CLI inside the bundle and
          # puts nothing on PATH, which is why the app path is tried at all.
          for candidate in tailscale /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \\
                           "/Applications/Tailscale.app/Contents/MacOS/Tailscale"; do
            mesh_ip="$("$candidate" ip -4 2>/dev/null | head -1)"
            [[ -n "$mesh_ip" ]] || continue
            mesh_fqdn="$("$candidate" status --json 2>/dev/null |
                         awk -F'"' '/"DNSName"/ { print $4; exit }' | sed 's/\\.$//')"
            break
          done
        fi

        [[ -n "$mesh_ip" ]] || {
          print -u2 "cs-bridge: no private network (Netbird/Tailscale) is connected; retrying later"
          exit 1
        }

        # TLS for whatever address and name the mesh handed out this time. The root is
        # created once and reused; only the leaf follows the address. Without HTTPS the
        # phone gets a terminal but no notifications and no install.
        "$bridge/make-cert.sh" "$mesh_ip" "$mesh_fqdn" \\
          || print -u2 "cs-bridge: certificate step failed; continuing on HTTP only"

        # The icons carry this Mac's colour so two bridges on one phone are not the
        # same picture twice. Regenerated only when the name changes — it is a second
        # of pixel work, not something to repeat on every restart.
        if [[ "$(cat "$bridge/web/.icon-name" 2>/dev/null)" != "$CS_BRIDGE_NAME" ]]; then
          node "$bridge/make-icons.mjs" "$CS_BRIDGE_NAME" >/dev/null 2>&1 \\
            && print -r -- "$CS_BRIDGE_NAME" > "$bridge/web/.icon-name"
        fi

        # ttyd stays on loopback; the phone reaches it only through the bridge's /term
        # proxy, so there is a single externally reachable port.
        ttyd --port 7789 --interface lo0 --base-path /term \\
             --credential "cs:$token" --url-arg --writable \\
             --terminal-type xterm-256color \\
             --client-option 'fontSize=13' \\
             --client-option 'scrollback=10000' \\
             "$bridge/cs-attach.sh" &
        ttyd_pid=$!
        trap 'kill $ttyd_pid 2>/dev/null' EXIT INT TERM

        CS_BRIDGE_HOST="$mesh_ip" exec node "$bridge/server.mjs"
        """

        do {
            try script.write(to: runnerFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: runnerFile.path)
            return true
        } catch {
            NSLog("[PhoneInstaller] could not write the runner: %@", "\(error)")
            return false
        }
    }

    /// Writes the plist and loads the job. `bootout` first: bootstrapping a label
    /// twice fails, and it is harmless when nothing is loaded.
    @discardableResult
    static func bootstrap() -> Bool {
        Paths.ensure(Paths.launchAgentsDir)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>/bin/zsh</string>
            <string>\(runnerFile.path)</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <!-- The mesh may come up after login; a slow retry lets the agent wait it
               out without spinning. -->
          <key>ThrottleInterval</key><integer>30</integer>
          <key>StandardOutPath</key><string>\(logFile.path)</string>
          <key>StandardErrorPath</key><string>\(logFile.path)</string>
        </dict>
        </plist>
        """
        do {
            try xml.write(to: plistFile, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        let uid = getuid()
        Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(label)"])
        return Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plistFile.path]).status == 0
    }

    /// Removes the agent and the plist; the token, the certificates and the staged
    /// files stay, so reinstalling does not ask every phone to trust a new root.
    static func uninstall() {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistFile)
    }

    /// The tail of the agent's log — the one place a failed start explains itself.
    static func logTail(lines: Int = 80) -> String {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }
}
