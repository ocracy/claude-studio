import Foundation

/// Diskteki sabit yollar.
///
/// İki katman vardır:
/// - **Uygulama katmanı** (`~/Library/Application Support/Claude Studio/`):
///   son açılan projeler, hook durum dosyaları, runner script'leri — makineye ait.
/// - **Proje katmanı** (`<proje>/.cs/`): servisler, terminaller, zamanlamalar,
///   çalışma raporları — projeye ait, taşınabilir ve versiyonlanabilir.
enum Paths {

    // MARK: - Uygulama katmanı

    static let appSupport: URL = {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let recentsFile = appSupport.appendingPathComponent("recents.json")

    static let tmuxConfig = appSupport.appendingPathComponent("tmux.conf")

    /// Hook script'inin yazdığı `<sekmeKimliği>.json` durum dosyaları.
    static let sessionStateDir: URL = {
        let url = appSupport.appendingPathComponent("session-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// launchd job'larının çalıştırdığı zsh script'leri.
    static let runnersDir: URL = {
        let url = appSupport.appendingPathComponent("runners", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let launchAgentsDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

    static let hookScript = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/hooks/claude-studio-hook.sh")

    static let claudeSettings = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/settings.json")

    static let globalSkillsDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/skills", isDirectory: true)

    // MARK: - Proje katmanı (.cs)

    /// `<proje>/.cs` — Visual Studio'nun `.vs`'i gibi, proje özelinde ayarlar.
    static func csDir(_ project: Project) -> URL {
        project.url.appendingPathComponent(".cs", isDirectory: true)
    }

    /// `.cs` altındaki dosyalar — her bölüm kendi dosyasında.
    static func services(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("services.json")
    }

    static func terminals(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("terminals.json")
    }

    static func schedules(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("schedules.json")
    }

    static func sessions(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("sessions.json")
    }

    static func settings(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("settings.json")
    }

    /// Tek dosyalı eski biçim; açılışta bir kez okunup bölünür.
    static func legacyConfig(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("config.json")
    }

    /// Skill çalışma raporları: `.cs/runs/<skill>/<zaman>.md`.
    static func runsDir(_ project: Project, skill: String) -> URL {
        csDir(project)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(skill, isDirectory: true)
    }

    static func runState(_ project: Project, skill: String) -> URL {
        runsDir(project, skill: skill).appendingPathComponent(".state.json")
    }

    static func projectSkillsDir(_ project: Project) -> URL {
        project.url.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    @discardableResult
    static func ensure(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Atomik JSON yazımı (tmp + move) — yarım yazılmış dosya asla kalmaz.
    static func writeAtomically(_ data: Data, to dest: URL) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            let tmp = dest.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            NSLog("[Paths] yazma başarısız %@: %@", dest.path, "\(error)")
        }
    }
}
