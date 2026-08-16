import Foundation

/// Installs the Claude Code hooks: they bridge a session's working/waiting state
/// into a per-session file that Claude Studio watches.
///
/// Hooks inherit the `claude` process environment, into which `CS_TAB_ID` is
/// injected when a session starts. Outside Claude Studio that variable is unset,
/// so the script is a no-op — zero effect on the user's other Claude sessions.
enum HookBridge {

    private static let events: [(event: String, state: String)] = [
        ("UserPromptSubmit", "working"),
        ("PreToolUse",       "working"),
        ("PostToolUse",      "working"),
        ("SessionStart",     "working"),
        ("Stop",             "waiting"),
        ("Notification",     "waiting"),
        ("SessionEnd",       "end"),
    ]

    static func installIfNeeded() {
        writeScript()
        mergeSettings()
    }

    // MARK: - Script

    private static func writeScript() {
        let url = Paths.hookScript
        Paths.ensure(url.deletingLastPathComponent())
        do {
            try scriptBody.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        } catch {
            NSLog("[HookBridge] failed to write script: %@", "\(error)")
        }
    }

    private static let scriptBody = """
    #!/bin/sh
    # Claude Studio <-> Claude Code bridge. Managed by the app — do not edit.
    # Writes the session's working/waiting state (and its session_id, for resume)
    # to a file the app watches. No-op outside Claude Studio (CS_TAB_ID unset).
    state="$1"

    # Claude pipes the event JSON on stdin; read it so its write never blocks.
    input=$(cat 2>/dev/null)

    [ -z "$CS_TAB_ID" ] && exit 0

    dir="$HOME/Library/Application Support/Claude Studio/session-state"
    file="$dir/$CS_TAB_ID.json"

    if [ "$state" = "end" ]; then
      rm -f "$file" 2>/dev/null
      exit 0
    fi

    mkdir -p "$dir" 2>/dev/null
    esc() { printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }
    sid=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\\([0-9a-fA-F-]*\\)".*/\\1/p' | head -1)
    name=$(esc "$CS_TAB_NAME")
    project=$(esc "$CS_PROJECT")
    ts=$(date +%s)
    tmp="$file.$$.tmp"
    printf '{"state":"%s","name":"%s","project":"%s","sid":"%s","ts":%s}' \\
      "$state" "$name" "$project" "$sid" "$ts" > "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null
    exit 0
    """

    // MARK: - settings.json merge

    /// Idempotent merge into `~/.claude/settings.json`. A file that cannot be
    /// parsed is left untouched — the user's settings are never corrupted.
    private static func mergeSettings() {
        let url = Paths.claudeSettings
        Paths.ensure(url.deletingLastPathComponent())

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[HookBridge] could not parse settings.json — merge skipped")
                return
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let scriptPath = Paths.hookScript.path
        var changed = false

        for (event, state) in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let installed = entries.contains { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains {
                    ($0["command"] as? String)?.contains("claude-studio-hook.sh") == true
                }
            }
            if installed { continue }

            entries.append([
                "matcher": "",
                "hooks": [["type": "command",
                           "command": "\(scriptPath) \(state)",
                           "timeout": 5,
                           "async": true]],
            ])
            hooks[event] = entries
            changed = true
        }

        guard changed else { return }
        root["hooks"] = hooks
        do {
            let data = try JSONSerialization.data(withJSONObject: root,
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[HookBridge] failed to write settings.json: %@", "\(error)")
        }
    }

    // MARK: - Reading state

    struct State: Decodable {
        var state: String
        var name: String?
        var sid: String?
        var ts: Double?
    }

    /// Reads every session state file: `sessionName → state`.
    static func readAll() -> [String: State] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: Paths.sessionStateDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [:] }
        var out: [String: State] = [:]
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(State.self, from: data) else { continue }
            out[url.deletingPathExtension().lastPathComponent] = decoded
        }
        return out
    }

    static func clearState(_ key: String) {
        try? FileManager.default.removeItem(
            at: Paths.sessionStateDir.appendingPathComponent("\(key).json"))
    }
}
