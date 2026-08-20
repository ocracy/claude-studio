import Foundation

/// The launchd layer behind scheduled skill runs.
///
/// So that runs happen even while the app is closed, every schedule is bound to a
/// LaunchAgent. The job does not invoke `claude` directly; it runs a zsh script
/// written by Claude Studio — the script sets up the environment, produces the
/// report, records state in `.state.json` and notifies when done.
///
/// CRITICAL: launchd hands processes a minimal PATH, so the `Shell.userPath`
/// snapshot is EMBEDDED in the script; `#!/bin/zsh -l` cannot be trusted to read
/// `.zshrc`.
enum Scheduler {

    // MARK: - Identity

    /// `com.claudestudio.<projectShortID>.<skill>`
    static func label(project: Project, skill: String) -> String {
        "com.claudestudio.\(sanitize(project.shortID)).\(sanitize(skill))"
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    static func plistURL(project: Project, skill: String) -> URL {
        Paths.launchAgentsDir.appendingPathComponent("\(label(project: project, skill: skill)).plist")
    }

    static func scriptURL(project: Project, skill: String) -> URL {
        Paths.runnersDir.appendingPathComponent("\(label(project: project, skill: skill)).sh")
    }

    private static var uid: String { String(getuid()) }

    // MARK: - The instruction handed to the skill

    /// What the prompt's placeholders resolve to for one particular run.
    ///
    /// A visible run knows all of it up front; the runner script does not — the
    /// report's file name carries a stamp only zsh produces — so there the
    /// substitution happens in the script instead (see `writeRunnerScript`).
    struct RunContext {
        var reportFile: String
        var runMode: String
        var lastRunAt: String
        var lastReport: String
    }

    /// The prompt handed to Claude. It invokes the skill by name and states
    /// where and in what shape the report must be written, so the output becomes
    /// a readable table in the app.
    ///
    /// The report path is INLINED, never left as `$CS_REPORT_FILE`: in print mode
    /// (`claude -p`) a Bash call cannot be approved, so the one way to read that
    /// variable back is closed and the model is left guessing a path — which is
    /// exactly how a run ends with an answer on screen and nothing in the run list.
    /// The previous report is inlined for the same reason: a path costs a Read the
    /// run may skip, the text costs nothing.
    ///
    /// With no `context` the placeholders (`@@REPORT_FILE@@` …) survive verbatim,
    /// which is what the runner script substitutes at run time.
    static func promptFor(project: Project, skill: String, extra: String = "",
                          context: RunContext? = nil) -> String {
        var prompt = """
        /\(skill) bu skilli çalıştır. Skill sonucunu markdown formatında bir rapor \
        gibi ver.

        Bu skilli en son çalıştırma zamanı: @@LAST_RUN_AT@@

        Son skillin raporu:
        @@LAST_REPORT@@
        """
        if let e = extra.nilIfEmpty {
            prompt += "\n\nEk talimatlar:\n\(e)"
        }
        prompt += """


        Raporu şu dosyaya yaz — bu mutlak yolu aynen kullan, başka bir yere yazma:
        @@REPORT_FILE@@

        Dosya şu frontmatter ile başlasın (alan adları aynen İngilizce kalsın):

        ---
        run_at: <ISO 8601 zaman damgası>
        status: ok | warning | failed
        summary: <tek satır, en fazla 90 karakter>
        duration_sec: <sayı>
        trigger: @@RUN_MODE@@
        ---

        Ardından bulguları kısa markdown olarak yaz; önceki rapora göre anlamlı bir
        değişiklik varsa açıkça belirt. Rapor dosyasını yazmadan işi bitirme.
        """
        guard let c = context else { return prompt }
        return prompt
            .replacingOccurrences(of: "@@RUN_MODE@@", with: c.runMode)
            .replacingOccurrences(of: "@@REPORT_FILE@@", with: c.reportFile)
            .replacingOccurrences(of: "@@LAST_RUN_AT@@",
                                  with: c.lastRunAt.nilIfEmpty ?? "daha önce çalıştırılmadı")
            .replacingOccurrences(of: "@@LAST_REPORT@@",
                                  with: c.lastReport.nilIfEmpty ?? "(önceki rapor yok)")
    }

    // MARK: - Runner script

    /// Writes the zsh script that runs the skill headlessly and returns its path.
    /// Both launchd and "run in background" use it — a single code path.
    @discardableResult
    static func writeRunnerScript(project: Project, skill: String, prompt: String) -> URL {
        let url = scriptURL(project: project, skill: skill)
        let runDir = Paths.runsDir(project, skill: skill).path
        let stateFile = Paths.runState(project, skill: skill).path

        // The heredoc must not end early on a line the prompt itself contains.
        var delim = "CS_PROMPT_EOF"
        while prompt.contains(delim) { delim += "X" }

        let script = """
        #!/bin/zsh
        # Claude Studio — scheduled skill runner.
        # Generated automatically; manual edits are overwritten.
        # Skill: \(skill)   Project: \(project.name)

        # The run directory is empty on the first run; an unmatched glob errors in zsh.
        setopt NULL_GLOB

        # launchd hands us a minimal PATH — inject the real one from the login shell.
        export PATH=\(Shell.quoted(Shell.userPath))

        export CS_SKILL_NAME=\(Shell.quoted(skill))
        export CS_PROJECT_PATH=\(Shell.quoted(project.path))
        export CS_PROJECT_NAME=\(Shell.quoted(project.name))
        export CS_RUN_DIR=\(Shell.quoted(runDir))
        export CS_RUN_MODE="${CS_RUN_MODE:-scheduled}"

        mkdir -p "$CS_RUN_DIR"

        STATE=\(Shell.quoted(stateFile))
        STAMP=$(date +%Y-%m-%d-%H%M)
        export CS_REPORT_FILE="$CS_RUN_DIR/$STAMP.md"

        # The conversation id is CHOSEN here, not read back afterwards: `claude -p`
        # reveals its session id only in `--output-format json`, and this stream has
        # to stay the readable thing the tab shows. Fixed in advance, every report
        # gets a `<stamp>.session` sidecar next to it — that is what makes "continue"
        # able to reopen the very conversation that wrote the report.
        SID=$(uuidgen | tr 'A-Z' 'a-z')
        export CS_RUN_SESSION_ID="$SID"
        print -r -- "$SID" > "$CS_RUN_DIR/$STAMP.session"

        # Previous run context — the newest report other than this one.
        LAST=$(ls -1t "$CS_RUN_DIR"/*.md 2>/dev/null | grep -v "^$CS_REPORT_FILE$" | head -1)
        export CS_LAST_REPORT="${LAST:-}"
        if [[ -n "$LAST" ]]; then
          export CS_LAST_RUN_AT=$(grep -m1 '^run_at:' "$LAST" | sed 's/^run_at:[[:space:]]*//')
          export CS_LAST_STATUS=$(grep -m1 '^status:' "$LAST" | sed 's/^status:[[:space:]]*//' | sed 's/[[:space:]]*#.*$//')
          export CS_LAST_SUMMARY=$(grep -m1 '^summary:' "$LAST" | sed 's/^summary:[[:space:]]*//')
        else
          export CS_LAST_RUN_AT=""; export CS_LAST_STATUS=""; export CS_LAST_SUMMARY=""
        fi

        # The previous report's TEXT, not only its path: a path costs a Read the run
        # may skip, the text costs nothing. Capped, or a long report crowds out the
        # instructions that follow it.
        LAST_BODY=""
        if [[ -n "$LAST" ]]; then
          LAST_BODY=$(tail -c 8000 "$LAST")
        fi

        # The prompt is assembled HERE rather than baked in by Swift: the report path
        # carries a stamp only this script knows. A QUOTED heredoc keeps the template
        # inert — a `$` or a backtick in the user's own instructions must reach Claude,
        # not the shell — and the placeholders are substituted afterwards. The previous
        # report goes in LAST, so its own text is never scanned for placeholders.
        PROMPT=$(cat <<'\(delim)'
        \(prompt)
        \(delim)
        )
        LAST_AT_TEXT="${CS_LAST_RUN_AT:-daha önce çalıştırılmadı}"
        LAST_BODY_TEXT="${LAST_BODY:-(önceki rapor yok)}"
        PROMPT="${PROMPT//@@RUN_MODE@@/$CS_RUN_MODE}"
        PROMPT="${PROMPT//@@REPORT_FILE@@/$CS_REPORT_FILE}"
        PROMPT="${PROMPT//@@LAST_RUN_AT@@/$LAST_AT_TEXT}"
        PROMPT="${PROMPT//@@LAST_REPORT@@/$LAST_BODY_TEXT}"

        STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        SECONDS=0
        print -r -- "{\\"startedAt\\":\\"$STARTED\\",\\"reportFile\\":\\"$CS_REPORT_FILE\\",\\"sessionId\\":\\"$SID\\"}" > "$STATE"

        cd "$CS_PROJECT_PATH" || exit 1
        # `tee`, not a plain redirect: a manual run watches this script in a tab, and
        # output that goes only to the log leaves that tab looking dead for minutes.
        # `--verbose` is what makes the stream worth watching — without it print mode
        # says nothing until the very end. `$CODE` must come from `pipestatus`, since
        # `$?` after a pipe is tee's.
        # `.last-output.txt` is truncated first and then written by the same `tee`:
        # it is what the fallback report below is made of, and appending would make
        # every run inherit the last one's text.
        : > "$CS_RUN_DIR/.last-output.txt"
        claude -p "$PROMPT" --session-id "$SID" --permission-mode acceptEdits --verbose 2>&1 \\
          | tee -a "$CS_RUN_DIR/.run.log" "$CS_RUN_DIR/.last-output.txt"
        CODE=${pipestatus[1]}
        ELAPSED=$SECONDS

        # A run that answered on screen but wrote no report used to vanish: the reports
        # ARE the state, so no file meant no row in the run list and no way to tell a
        # skipped write from a job that never fired. Write one instead — `warning`,
        # because the run happened and only the report is missing.
        if [[ ! -f "$CS_REPORT_FILE" ]]; then
          if [[ $CODE -eq 0 ]]; then
            FB_STATUS="warning"
            FB_SUMMARY="Skill çalıştı ama rapor dosyası yazılmadı — çıktı aşağıda"
          else
            FB_STATUS="failed"
            FB_SUMMARY="Çalışma başarısız (çıkış $CODE)"
          fi
          {
            print -r -- "---"
            print -r -- "run_at: $STARTED"
            print -r -- "status: $FB_STATUS"
            print -r -- "summary: $FB_SUMMARY"
            print -r -- "duration_sec: $ELAPSED"
            print -r -- "trigger: $CS_RUN_MODE"
            print -r -- "---"
            print -r -- ""
            print -r -- "# $CS_SKILL_NAME"
            print -r -- ""
            print -r -- "Rapor dosyası yazılmadı; aşağıdaki metin çalışmanın çıktısıdır."
            print -r -- ""
            print -r -- '```'
            tail -n 200 "$CS_RUN_DIR/.last-output.txt" 2>/dev/null
            print -r -- '```'
          } > "$CS_REPORT_FILE"
        fi

        FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        print -r -- "{\\"startedAt\\":\\"$STARTED\\",\\"finishedAt\\":\\"$FINISHED\\",\\"exitCode\\":$CODE,\\"reportFile\\":\\"$CS_REPORT_FILE\\",\\"sessionId\\":\\"$SID\\"}" > "$STATE"

        # Keep the log from growing without bound.
        tail -n 500 "$CS_RUN_DIR/.run.log" > "$CS_RUN_DIR/.run.log.tmp" 2>/dev/null \\
          && mv "$CS_RUN_DIR/.run.log.tmp" "$CS_RUN_DIR/.run.log"

        # UNUserNotificationCenter does not work in an ad-hoc signed app — use osascript.
        TITLE=\(Shell.quoted(applescriptSafe("\(project.name) — \(skill)")))
        if [[ $CODE -eq 0 && -f "$CS_REPORT_FILE" ]]; then
          SUMMARY=$(grep -m1 '^summary:' "$CS_REPORT_FILE" | sed 's/^summary:[[:space:]]*//' | tr -d '"\\\\')
          osascript -e "display notification \\"${SUMMARY:-Report ready}\\" with title \\"$TITLE\\" sound name \\"Glass\\"" >/dev/null 2>&1
        else
          osascript -e "display notification \\"Run failed (exit $CODE)\\" with title \\"$TITLE\\" sound name \\"Basso\\"" >/dev/null 2>&1
        fi

        exit $CODE
        """

        Paths.ensure(url.deletingLastPathComponent())
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The osascript → zsh → Swift escaping chain is brittle; quotes and
    /// backslashes are stripped from the title entirely.
    private static func applescriptSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: " ")
         .replacingOccurrences(of: "\"", with: " ")
         .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Installation

    /// Installs the job (script + plist + bootstrap). If the schedule is disabled
    /// it uninstalls instead, so callers need no extra check.
    static func install(project: Project, schedule: Schedule) {
        guard schedule.enabled else {
            uninstall(project: project, skill: schedule.skill)
            return
        }
        Paths.ensure(Paths.runsDir(project, skill: schedule.skill))
        writeRunnerScript(project: project, skill: schedule.skill,
                          prompt: promptFor(project: project, skill: schedule.skill,
                                            extra: schedule.prompt))

        let jobLabel = label(project: project, skill: schedule.skill)
        let plist = plistURL(project: project, skill: schedule.skill)
        let scriptPath = scriptURL(project: project, skill: schedule.skill).path
        let logDir = Paths.runsDir(project, skill: schedule.skill).path

        var interval = "        <key>Minute</key>\n        <integer>\(schedule.minute)</integer>\n"
        if schedule.frequency != .hourly {
            interval += "        <key>Hour</key>\n        <integer>\(schedule.hour)</integer>\n"
        }
        if schedule.frequency == .weekly {
            interval += "        <key>Weekday</key>\n        <integer>\(schedule.weekday)</integer>\n"
        }

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(jobLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/bin/zsh</string>
                <string>\(xmlEscape(scriptPath))</string>
            </array>
            <key>StartCalendarInterval</key>
            <dict>
        \(interval)    </dict>
            <key>RunAtLoad</key>
            <false/>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(logDir))/.launchd.log</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(logDir))/.launchd.log</string>
        </dict>
        </plist>
        """

        Paths.ensure(Paths.launchAgentsDir)
        try? xml.write(to: plist, atomically: true, encoding: .utf8)

        // `load/unload` is deprecated. Bootstrapping the same label twice fails,
        // so bootout unconditionally first (harmless if it is not loaded).
        Shell.runAsync("/bin/launchctl", ["bootout", "gui/\(uid)/\(jobLabel)"]) { _, _ in
            Shell.runAsync("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist.path]) { status, out in
                if status != 0 {
                    NSLog("[Scheduler] bootstrap failed (%d) %@: %@", status, jobLabel, out)
                }
            }
        }
    }

    /// Removes the job and its plist. The runner script stays — "run in
    /// background" keeps using it.
    static func uninstall(project: Project, skill: String) {
        let jobLabel = label(project: project, skill: skill)
        let plist = plistURL(project: project, skill: skill)
        Shell.runAsync("/bin/launchctl", ["bootout", "gui/\(uid)/\(jobLabel)"]) { _, _ in
            try? FileManager.default.removeItem(at: plist)
        }
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
