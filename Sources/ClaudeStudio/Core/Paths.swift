import Foundation

/// Fixed on-disk locations.
///
/// Two layers:
/// - **Application layer** (`~/Library/Application Support/Claude Studio/`):
///   recent projects, hook state files, runner scripts — belongs to the machine.
/// - **Project layer** (`<project>/.cs/`): services, terminals, schedules and run
///   reports — belongs to the project, so it travels and can be versioned.
enum Paths {

    // MARK: - Application layer

    static let appSupport: URL = {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let recentsFile = appSupport.appendingPathComponent("recents.json")

    static let tmuxConfig = appSupport.appendingPathComponent("tmux.conf")

    /// `<tabID>.json` state files written by the hook script.
    static let sessionStateDir: URL = {
        let url = appSupport.appendingPathComponent("session-state", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Raw hook events waiting to be read: one file per event, so a reader never sees
    /// a half-written record and no offset bookkeeping is needed.
    static let eventsDir: URL = {
        let url = appSupport.appendingPathComponent("events", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// zsh scripts executed by launchd jobs.
    static let runnersDir: URL = {
        let url = appSupport.appendingPathComponent("runners", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Helper binaries copied out of the bundle so their paths survive an update.
    static let binDir: URL = {
        let url = appSupport.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let launchAgentsDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

    /// Shared secret for phone access. Created by `Bridge/install.sh`; the app
    /// reads it to build the QR code and rewrites it only when the user asks
    /// for a new one.
    static let bridgeToken = appSupport.appendingPathComponent("bridge-token")

    static let hookScript = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/hooks/claude-studio-hook.sh")

    static let claudeSettings = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/settings.json")

    static let globalSkillsDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/skills", isDirectory: true)

    static let globalCommandsDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/commands", isDirectory: true)

    // MARK: - Projectct layer (.cs)

    /// `<project>/.cs` — project-scoped settings, like Visual Studio's `.vs`.
    static func csDir(_ project: Project) -> URL {
        project.url.appendingPathComponent(".cs", isDirectory: true)
    }

    /// Files under `.cs` — each section in its own file.
    static func services(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("services.json")
    }

    static func scripts(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("scripts.json")
    }

    /// Superseded by `scripts.json`; read once and migrated.
    static func legacyCommands(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("commands.json")
    }

    static func links(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("links.json")
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

    /// Legacy single-file format; read once on open and split.
    static func legacyConfig(_ project: Project) -> URL {
        csDir(project).appendingPathComponent("config.json")
    }

    /// Skill run reports: `.cs/runs/<skill>/<timestamp>.md`.
    static func runsDir(_ project: Project, skill: String) -> URL {
        csDir(project)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(skill, isDirectory: true)
    }

    /// Skill and command usage, one JSON object per line, beside that skill's reports.
    static func usageFile(_ project: Project, skill: String) -> URL {
        runsDir(project, skill: skill).appendingPathComponent("usage.jsonl")
    }

    static func runState(_ project: Project, skill: String) -> URL {
        runsDir(project, skill: skill).appendingPathComponent(".state.json")
    }

    static func projectSkillsDir(_ project: Project) -> URL {
        project.url.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// Claude slash commands.
    static func projectCommandsDir(_ project: Project) -> URL {
        project.url.appendingPathComponent(".claude/commands", isDirectory: true)
    }

    @discardableResult
    static func ensure(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Atomic JSON write (tmp + move) — a half-written file is never left behind.
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
            NSLog("[Paths] write failed %@: %@", dest.path, "\(error)")
        }
    }
}
