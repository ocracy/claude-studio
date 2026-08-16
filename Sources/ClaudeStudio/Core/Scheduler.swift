import Foundation

/// Zamanlanmış skill çalışmalarının launchd katmanı.
///
/// Uygulama kapalıyken de çalışabilmesi için her zamanlama bir LaunchAgent'a
/// bağlanır. Job doğrudan `claude` çağırmaz; Claude Studio'nun yazdığı bir zsh
/// script'ini çalıştırır — script ortamı kurar, raporu ürettirir, durumu
/// `.state.json`'a yazar ve bitince bildirim + ses verir.
///
/// KRİTİK: launchd süreçlere minimal PATH verir. Bu yüzden `Shell.userPath`
/// snapshot'ı script'e GÖMÜLÜ yazılır; `#!/bin/zsh -l`'in `.zshrc`'yi okuyacağına
/// güvenilmez.
enum Scheduler {

    // MARK: - Kimlik

    /// `com.claudestudio.<projeKısaKimliği>.<skill>`
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

    // MARK: - Skill'e verilen yönerge

    /// Claude'a verilen komut. Skill'i kendi adıyla çağırır ve raporun nereye,
    /// hangi biçimde yazılacağını söyler — böylece çıktı uygulamada tablo olur.
    static func promptFor(project: Project, skill: String, extra: String = "") -> String {
        var prompt = """
        \(skill) skill'ini çalıştır.

        Bitirince raporu `$CS_REPORT_FILE` yoluna yaz. Dosya şu frontmatter ile başlasın:

        ---
        run_at: <ISO 8601 zaman>
        status: ok | warning | failed
        summary: <tek satır, en fazla 90 karakter>
        duration_sec: <sayı>
        trigger: $CS_RUN_MODE
        ---

        Ardından bulguları kısa markdown olarak yaz. Önceki rapor `$CS_LAST_REPORT` \
        yolunda; anlamlı bir değişiklik varsa belirt.
        """
        if let e = extra.nilIfEmpty {
            prompt += "\n\nEk yönerge:\n\(e)"
        }
        return prompt
    }

    // MARK: - Runner script

    /// Skill'i başsız (headless) çalıştıran zsh script'ini yazar ve yolunu döner.
    /// Hem launchd hem "arka planda çalıştır" bunu kullanır — tek kod yolu.
    @discardableResult
    static func writeRunnerScript(project: Project, skill: String, prompt: String) -> URL {
        let url = scriptURL(project: project, skill: skill)
        let runDir = Paths.runsDir(project, skill: skill).path
        let stateFile = Paths.runState(project, skill: skill).path

        let script = """
        #!/bin/zsh
        # Claude Studio — zamanlanmış skill çalıştırıcı.
        # Otomatik üretildi; elle yapılan değişiklikler üzerine yazılır.
        # Skill: \(skill)   Proje: \(project.name)

        # İlk çalışmada rapor klasörü boştur; eşleşmeyen glob zsh'te hata verir.
        setopt NULL_GLOB

        # launchd minimal PATH verir — giriş kabuğundan alınan gerçek PATH enjekte edilir.
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

        # Önceki çalışma bağlamı — bu koşu hariç en yeni rapor.
        LAST=$(ls -1t "$CS_RUN_DIR"/*.md 2>/dev/null | grep -v "^$CS_REPORT_FILE$" | head -1)
        export CS_LAST_REPORT="${LAST:-}"
        if [[ -n "$LAST" ]]; then
          export CS_LAST_RUN_AT=$(grep -m1 '^run_at:' "$LAST" | sed 's/^run_at:[[:space:]]*//')
          export CS_LAST_STATUS=$(grep -m1 '^status:' "$LAST" | sed 's/^status:[[:space:]]*//' | sed 's/[[:space:]]*#.*$//')
          export CS_LAST_SUMMARY=$(grep -m1 '^summary:' "$LAST" | sed 's/^summary:[[:space:]]*//')
        else
          export CS_LAST_RUN_AT=""; export CS_LAST_STATUS=""; export CS_LAST_SUMMARY=""
        fi

        STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        print -r -- "{\\"startedAt\\":\\"$STARTED\\",\\"reportFile\\":\\"$CS_REPORT_FILE\\"}" > "$STATE"

        cd "$CS_PROJECT_PATH" || exit 1
        claude -p \(Shell.quoted(prompt)) --permission-mode acceptEdits \\
          >> "$CS_RUN_DIR/.run.log" 2>&1
        CODE=$?

        FINISHED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        print -r -- "{\\"startedAt\\":\\"$STARTED\\",\\"finishedAt\\":\\"$FINISHED\\",\\"exitCode\\":$CODE,\\"reportFile\\":\\"$CS_REPORT_FILE\\"}" > "$STATE"

        # Log sınırsız büyümesin.
        tail -n 500 "$CS_RUN_DIR/.run.log" > "$CS_RUN_DIR/.run.log.tmp" 2>/dev/null \\
          && mv "$CS_RUN_DIR/.run.log.tmp" "$CS_RUN_DIR/.run.log"

        # Ad-hoc imzalı uygulamada UNUserNotificationCenter çalışmaz — osascript kullanılır.
        TITLE=\(Shell.quoted(applescriptSafe("\(project.name) — \(skill)")))
        if [[ $CODE -eq 0 && -f "$CS_REPORT_FILE" ]]; then
          SUMMARY=$(grep -m1 '^summary:' "$CS_REPORT_FILE" | sed 's/^summary:[[:space:]]*//' | tr -d '"\\\\')
          osascript -e "display notification \\"${SUMMARY:-Rapor hazır}\\" with title \\"$TITLE\\" sound name \\"Glass\\"" >/dev/null 2>&1
        else
          osascript -e "display notification \\"Çalışma başarısız (çıkış $CODE)\\" with title \\"$TITLE\\" sound name \\"Basso\\"" >/dev/null 2>&1
        fi

        exit $CODE
        """

        Paths.ensure(url.deletingLastPathComponent())
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// osascript → zsh → Swift üç katmanlı kaçış zinciri kırılgandır; başlıktaki
    /// tırnak ve ters bölü tamamen elenir.
    private static func applescriptSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: " ")
         .replacingOccurrences(of: "\"", with: " ")
         .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Kurulum

    /// Job'ı kurar (script + plist + bootstrap). Zamanlama kapalıysa kaldırır —
    /// çağıranın ayrıca kontrol etmesi gerekmez.
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

        // `load/unload` kullanımdan kalktı. Aynı label ikinci kez bootstrap
        // edilirse hata verir → önce koşulsuz bootout (yoksa da zararsız).
        Shell.runAsync("/bin/launchctl", ["bootout", "gui/\(uid)/\(jobLabel)"]) { _, _ in
            Shell.runAsync("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist.path]) { status, out in
                if status != 0 {
                    NSLog("[Scheduler] bootstrap başarısız (%d) %@: %@", status, jobLabel, out)
                }
            }
        }
    }

    /// Job'ı kaldırır ve plist'i siler. Runner script'i kalır — "arka planda
    /// çalıştır" onu kullanmaya devam eder.
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
