import Foundation

/// Running a linked project's skill — on purpose, and never by accident.
///
/// A linked project's skills are deliberately absent from this session's skill list
/// (see `LinkAccess`), because a skill picked by name alone cannot be told apart from
/// this project's own. So there has to be a way to run one deliberately, and this is
/// it. Two properties make it safe where a shared skill list is not:
///
/// * The project is **named**, never inferred. `run_skill` takes a project and a
///   skill; there is no name to guess wrong and no nearest match to fall back on.
/// * Nothing runs until the user presses a button. A request from a session lands
///   here as `pending` and stays there. The app asks; a person answers.
///
/// The skill then runs **in the project that owns it** — `cd`'d into its directory,
/// under its own `CLAUDE.md` and settings — through exactly the runner `Scheduler`
/// writes for a scheduled run. Same script, same report, same `.state.json`. The tab
/// is opened in the window you are already in, so you can watch it, and answer it if
/// it asks something, without leaving what you were doing.
///
/// The request file is written from two processes — the bridge appends, the app
/// updates status — so both re-read it immediately before writing, the same
/// discipline `.cs/sessions.json` needs for the phone.
struct SkillRequest: Identifiable, Hashable, Codable {
    enum Status: String, Codable {
        /// Waiting for the user. Nothing has run.
        case pending
        /// The user approved it; the runner is in a tab.
        case running
        /// The runner exited. `exitCode` and `reportFile` are filled in.
        case finished
        /// The user said no.
        case declined
        /// It could not be started at all (the skill or project went missing).
        case failed
    }

    var id: String
    /// The project that owns the skill — always the linked one, never the caller.
    var projectPath: String
    var projectName: String
    var skill: String
    /// Extra instructions appended to the runner's prompt. May be empty.
    var prompt: String
    var requestedAt: Date
    var status: Status
    /// Which session asked, for the confirmation to name it. Empty when a person
    /// started it from the sidebar or the palette.
    var requestedBy: String
    var exitCode: Int?
    var reportFile: String?
    var note: String?

    var project: Project { Project(path: projectPath, name: projectName) }

    init(project: Project, skill: String, prompt: String = "", requestedBy: String = "") {
        self.id = UUID().uuidString
        self.projectPath = project.path
        self.projectName = project.name
        self.skill = skill
        self.prompt = prompt
        self.requestedAt = Date()
        self.status = .pending
        self.requestedBy = requestedBy
    }

    /// Decoded by hand for the reason every record in this app is: the synthesized
    /// decoder throws on a key an older (or hand-written) file lacks, and one bad
    /// entry must not take the whole queue down.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id          = value(.id, UUID().uuidString)
        projectPath = value(.projectPath, "")
        projectName = value(.projectName,
                            URL(fileURLWithPath: projectPath).lastPathComponent)
        skill       = value(.skill, "")
        prompt      = value(.prompt, "")
        requestedAt = value(.requestedAt, Date())
        status      = Status(rawValue: value(.status, "pending")) ?? .pending
        requestedBy = value(.requestedBy, "")
        exitCode    = value(.exitCode, nil as Int?)
        reportFile  = value(.reportFile, nil as String?)
        note        = value(.note, nil as String?)
    }
}

@MainActor
enum LinkedRuns {

    // MARK: - The queue

    static func read(_ project: Project) -> [SkillRequest] {
        guard let data = try? Data(contentsOf: Paths.skillRequests(project)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SkillRequest].self, from: data)) ?? []
    }

    static func write(_ requests: [SkillRequest], to project: Project) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(requests) else { return }
        Paths.writeAtomically(data, to: Paths.skillRequests(project))
    }

    /// Re-reads before writing: the bridge appends to this file from another process,
    /// and starting from a stale in-memory copy would erase a request it just made.
    static func update(_ id: String, in project: Project,
                       _ change: (inout SkillRequest) -> Void) {
        var all = read(project)
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        write(all, to: project)
    }

    /// Drops everything settled and older than a day, so the file cannot grow forever.
    static func prune(_ project: Project) {
        let cutoff = Date().addingTimeInterval(-86_400)
        let kept = read(project).filter {
            $0.status == .pending || $0.status == .running || $0.requestedAt > cutoff
        }
        write(kept, to: project)
    }

    // MARK: - What a linked project offers

    /// The skills a linked project defines, read straight from its `.claude/skills`.
    /// Scanned on demand rather than watched: this list is opened by a person, and a
    /// watcher per link would be a file descriptor per link for a menu.
    static func skills(of link: ProjectLink) -> [Skill] {
        SkillStore.discover(in: Paths.projectSkillsDir(link.asProject), scope: .project)
    }
}

extension ProjectLink {
    var asProject: Project { Project(path: path, name: name) }
}
