import Foundation

// Claude Studio's project bridge: an MCP server that lets one project's Claude session
// see the projects it is linked to — their capabilities, their running services and
// terminals, and their files.
//
// It never starts a second Claude and never spends tokens: everything it answers is
// read from disk or from the app's tmux server. Code changes are made by the calling
// session itself, through the file access a writable link grants (see `LinkAccess`).
//
// Usage: claude-studio-bridge --project /path/to/the/calling/project

let arguments = CommandLine.arguments
var projectPath: String?
var index = 1
while index < arguments.count {
    if arguments[index] == "--project", index + 1 < arguments.count {
        projectPath = arguments[index + 1]
        index += 2
    } else {
        index += 1
    }
}

guard let projectPath else {
    FileHandle.standardError.write(Data("usage: claude-studio-bridge --project <path>\n".utf8))
    exit(2)
}

let owner = ProjectReader(path: (projectPath as NSString).expandingTildeInPath)

/// Links are re-read on every call, so linking or unlinking a project takes effect at
/// once — no session restart, unlike file access.
struct Link {
    let name: String
    let path: String
    let allowEdits: Bool
    /// What the project is, and when to reach for it — answered by the user when the
    /// link was made. Both may be empty; see `briefing`.
    let role: String
    let useWhen: String
}

func links() -> [Link] {
    let file = owner.url.appendingPathComponent(".cs/links.json")
    guard let data = try? Data(contentsOf: file),
          let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return [] }
    return array.compactMap { entry in
        guard let path = entry.string("path") else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let name = entry.string("name") ?? URL(fileURLWithPath: expanded).lastPathComponent
        return Link(name: name, path: expanded,
                    allowEdits: entry["allowEdits"] as? Bool ?? false,
                    role: entry.string("role") ?? "",
                    useWhen: entry.string("useWhen") ?? "")
    }
}

/// Resolves a tool's `project` argument against the links. With a single link the
/// argument may be omitted.
func reader(for arguments: [String: Any]) throws -> (ProjectReader, Bool) {
    let all = links()
    guard !all.isEmpty else {
        throw MCPServer.ToolError("No projects are linked to \(owner.name) yet. "
            + "Link one in Claude Studio: MCP servers → + → Link a Claude project.")
    }
    guard let wanted = arguments.string("project")?.nilIfEmpty else {
        guard all.count == 1 else {
            throw MCPServer.ToolError("Which project? Linked: "
                + all.map(\.name).joined(separator: ", "))
        }
        return (ProjectReader(path: all[0].path), all[0].allowEdits)
    }
    // Match on name first, then on path, then on a trailing path component.
    if let hit = all.first(where: { $0.name == wanted })
        ?? all.first(where: { $0.path == (wanted as NSString).expandingTildeInPath })
        ?? all.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent == wanted }) {
        return (ProjectReader(path: hit.path), hit.allowEdits)
    }
    throw MCPServer.ToolError("\(wanted) is not linked. Linked: "
        + all.map(\.name).joined(separator: ", "))
}

/// Resolves `project` for the tools that look at what is RUNNING, which — unlike the
/// rest — accept THIS project as well as the linked ones.
///
/// The asymmetry is deliberate. For files, a session already has Read and Grep over
/// its own project, so `read_file` pointing at itself would be a worse duplicate. For
/// running processes it has nothing: a service or a `tail -f` lives in a tmux pane
/// with no window onto it, and its own project's panes are exactly as invisible as a
/// linked project's. So these two tools answer for both, and an omitted `project`
/// means this one — "look at the frontend log" names no project because it does not
/// need to.
func runtimeReader(for arguments: [String: Any]) throws -> ProjectReader {
    guard let wanted = arguments.string("project")?.nilIfEmpty else { return owner }
    let expanded = (wanted as NSString).expandingTildeInPath
    if wanted == owner.name || expanded == owner.path
        || URL(fileURLWithPath: owner.path).lastPathComponent == wanted {
        return owner
    }
    let all = links()
    if let hit = all.first(where: { $0.name == wanted })
        ?? all.first(where: { $0.path == expanded })
        ?? all.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent == wanted }) {
        return ProjectReader(path: hit.path)
    }
    let known = ([owner.name] + all.map(\.name)).joined(separator: ", ")
    throw MCPServer.ToolError("\(wanted) is neither this project nor linked to it. "
        + "Available: \(known)")
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

let projectArgument: [String: Any] = [
    "project": ["type": "string",
                "description": "Name or path of a linked project. Optional when only one is linked."],
]

/// For the runtime tools, where the default is THIS project rather than a link.
let runtimeProjectArgument: [String: Any] = [
    "project": ["type": "string",
                "description": "Name or path of a project — this one or any linked to "
                    + "it. Omit for this project."],
]

/// What the session is told about the linked projects the moment this server connects.
///
/// The tools alone are not enough. A session can LIST a linked project's skills, but a
/// skill's own description says when it fires inside its own project — not whether
/// reaching across a link is the right move here. Nothing on disk answers that, so
/// Claude Studio asks when the link is made and the answer is delivered here, in the
/// server's instructions, which arrive without a tool call. A capability nobody knows
/// the occasion for is a capability that never gets used, or gets used at the wrong
/// moment; both are failures of the same missing sentence.
///
/// A link with nothing written about it falls back to the strict reading — by name
/// only — because that is the safe half of the ambiguity.
func briefing() -> String {
    let all = links()
    guard !all.isEmpty else {
        // Not a failure any more: the bridge is connected for this project's own sake
        // as often as for a link's, and the tools above work with nothing linked.
        return "No other project is linked to \(owner.name), so the linked-project tools "
            + "have nothing to answer. Everything about this project still works. A link "
            + "is made in Claude Studio: MCP servers → + → Link a Claude project."
    }
    var lines = ["Projects linked to \(owner.name), and when to reach for them:"]
    for link in all {
        let reader = ProjectReader(path: link.path)
        var line = "\n• \(link.name) — \(link.role.nilIfEmpty ?? "no description given")"
        line += "\n  path: \(link.path)\(link.allowEdits ? " (you may edit its files)" : " (read-only)")"
        line += "\n  use it: " + (link.useWhen.nilIfEmpty
            ?? "only when the user asks for this project by name")
        // Names, not descriptions: the occasion is the sentence above, and a dozen
        // frontmatter blurbs here would bury it.
        let skills = reader.skills().map(\.name)
        if !skills.isEmpty {
            let shown = skills.prefix(12).joined(separator: ", ")
            line += "\n  skills: \(shown)"
                + (skills.count > 12 ? " (+\(skills.count - 12) more)" : "")
        }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

let server = MCPServer(
    name: "claude-studio-bridge",
    version: "1.0",
    instructions: """
    Claude Studio is the workspace this project is open in. This server is how you \
    reach the parts of it a file read cannot answer — what is running, what has been \
    run, and the projects this one is linked to.

    THIS PROJECT. `project_runtime` and `read_output` are the only way to see any of \
    it: services, terminals and sessions run in tmux panes that nothing else here can \
    read — a dev server's log, a `tail -f` left open in a tab, a build that just \
    failed. When something is broken, look at what is actually running before guessing \
    from the source. `project_runtime` names the panes; `read_output` reads one. \
    `control_service` starts, stops and restarts a service — through the app, which \
    owns the tmux session, so the sidebar and the status keep telling the truth; do \
    that rather than starting a dev server in Bash where nothing tracks it. \
    `define_service` and `define_script` write `.cs/services.json` and \
    `.cs/scripts.json`, which is how a project gains a "npm run dev" button or a \
    "migrate" one. `skill_runs` reads what a scheduled skill reported — status, \
    summary, the whole report — and `run_skill` naming THIS project is "run now". \
    Omit `project` and every one of these means this one.

    LINKED PROJECTS. `linked_projects` lists them; `project_capabilities` says what \
    each can do.

    \(briefing())

    Links marked `allow_edits` are already in your working directories, so edit their \
    files with your normal tools. For read-only links use `read_file` and `search_files`.

    A linked project's skills are deliberately NOT in your skill list — they belong to \
    that project, and a skill picked by name alone cannot be told apart from this \
    project's own. To run one, use `run_skill` with the project named explicitly, then \
    `wait_for_skill_run` for the result: it runs in the project that owns it, under \
    that project's own configuration, after the user confirms. Never carry out a linked \
    project's deploy, release or migration by reading its SKILL.md and following the \
    steps here — that runs another project's operation in this project's session, with \
    the wrong configuration and no record. Reading one to ANSWER a question about it is \
    fine. Do not expect `/command` to resolve either — those belong to that project's \
    own sessions.
    """,
    tools: [
        // MARK: linked_projects
        MCPServer.Tool(
            name: "linked_projects",
            title: "List linked projects",
            description: "The local Claude projects this project is linked to, with their "
                + "absolute paths, whether you may edit them, and where their CLAUDE.md is.",
            inputSchema: ["type": "object", "properties": [:] as [String: Any],
                          "additionalProperties": false]
        ) { _ in
            let all = links()
            guard !all.isEmpty else {
                return "No projects are linked to \(owner.name). Link one in Claude Studio: "
                    + "MCP servers → + → Link a Claude project."
            }
            return jsonText(all.map { link -> [String: Any] in
                let reader = ProjectReader(path: link.path)
                var out: [String: Any] = [
                    "name": link.name,
                    "path": link.path,
                    "allow_edits": link.allowEdits,
                    "exists": reader.exists,
                    // Answered by the user when the link was made — the occasion for
                    // reaching across it, which no file in either project records.
                    "role": link.role,
                    "use_when": link.useWhen.nilIfEmpty
                        ?? "only when the user asks for this project by name",
                ]
                if let claude = reader.claudeMarkdown { out["claude_md"] = claude }
                return out
            })
        },

        // MARK: project_capabilities
        MCPServer.Tool(
            name: "project_capabilities",
            title: "What a linked project can do",
            description: "The skills, slash commands, scripts and services defined in a linked "
                + "project. Skills and commands include the markdown file to read if you want "
                + "to follow their instructions yourself.",
            inputSchema: ["type": "object", "properties": projectArgument,
                          "additionalProperties": false]
        ) { arguments in
            let (reader, _) = try reader(for: arguments)
            guard reader.exists else {
                throw MCPServer.ToolError("\(reader.path) no longer exists on disk.")
            }
            return jsonText([
                "project": reader.name,
                "path": reader.path,
                "claude_md": reader.claudeMarkdown ?? "",
                "skills": reader.skills().map(\.json),
                "commands": reader.commands().map(\.json),
                "scripts": reader.scripts(),
                "services": reader.services(),
                "terminals": reader.terminals(),
            ])
        },

        // MARK: project_runtime
        MCPServer.Tool(
            name: "project_runtime",
            title: "What a project is running",
            description: "Live state inside Claude Studio of THIS project or one linked to "
                + "it: its Claude sessions, terminals and services, whether each is alive "
                + "or has exited (with its exit code), the directory it runs in and any "
                + "ports it listens on. Use it to find the name of a service or terminal "
                + "before reading its output. Omit `project` for this one.",
            inputSchema: ["type": "object", "properties": runtimeProjectArgument,
                          "additionalProperties": false]
        ) { arguments in
            let reader = try runtimeReader(for: arguments)
            guard Tmux.path != nil else {
                throw MCPServer.ToolError("tmux is not installed, so nothing is running "
                    + "under Claude Studio's control.")
            }
            let panes = reader.panes()
            guard !panes.isEmpty else {
                return "Nothing of \(reader.name) is running right now."
            }
            return jsonText(panes.map { pane -> [String: Any] in
                var out: [String: Any] = [
                    "name": pane.title,
                    "kind": pane.kind,
                    "state": pane.dead ? "exited" : "running",
                    // A dead pane reports no directory; the project's own is the truth.
                    "cwd": pane.cwd.nilIfEmpty ?? reader.path,
                    "target": pane.session,
                ]
                if let code = pane.exitCode { out["exit_code"] = code }
                if !pane.dead, let pid = pane.pid {
                    let ports = reader.listeningPorts(pid: pid)
                    if !ports.isEmpty { out["listening_ports"] = ports }
                }
                return out
            })
        },

        // MARK: read_output
        MCPServer.Tool(
            name: "read_output",
            title: "Read what a service or terminal printed",
            description: "The recent output of a service, terminal or Claude session — in "
                + "THIS project or one linked to it — including what an exited service "
                + "printed before it died. This is how you read a dev server's log, a "
                + "`tail -f` someone left open, or a build that failed: they run in tmux "
                + "panes you have no other way to see, your own project's included. Name "
                + "the target as `project_runtime` reports it; omit `project` for this one.",
            inputSchema: ["type": "object",
                          "properties": runtimeProjectArgument.merging([
                              "name": ["type": "string",
                                       "description": "Service, terminal or session name."],
                              "lines": ["type": "integer",
                                        "description": "How many lines to read (default 200)."],
                          ]) { a, _ in a },
                          "required": ["name"],
                          "additionalProperties": false]
        ) { arguments in
            let reader = try runtimeReader(for: arguments)
            guard let wanted = arguments.string("name")?.nilIfEmpty else {
                throw MCPServer.ToolError("Which service or terminal? Give its name.")
            }
            let panes = reader.panes()
            guard let pane = panes.first(where: { $0.title == wanted })
                ?? panes.first(where: { $0.session == wanted })
                ?? panes.first(where: { $0.title.localizedCaseInsensitiveContains(wanted) })
            else {
                let known = panes.map(\.title).joined(separator: ", ")
                throw MCPServer.ToolError(known.isEmpty
                    ? "Nothing of \(reader.name) is running right now."
                    : "\(reader.name) has no \"\(wanted)\". Running: \(known)")
            }
            let lines = arguments.int("lines") ?? 200
            // tmux pads the capture to the pane height; the blank tail is noise.
            let text = Tmux.capture(pane.session, lines: min(max(lines, 10), 5000))
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let header = "\(pane.kind) \(pane.title) · "
                + (pane.dead ? "exited\(pane.exitCode.map { " (\($0))" } ?? "")" : "running")
            return text.nilIfEmpty.map { "\(header)\n\n\($0)" }
                ?? "\(header)\n\n(no output captured)"
        },

        // MARK: run_skill
        MCPServer.Tool(
            name: "run_skill",
            title: "Run a skill through Claude Studio",
            description: "Runs a skill the way a scheduled run does — headless, in the "
                + "project that owns it, writing a report you can read back. Name THIS "
                + "project to run one of its own skills (that is \"run now\", and it starts "
                + "immediately); name a LINKED project and Claude Studio asks the user to "
                + "confirm first, with nothing running until they do. Returns a request id: "
                + "pass it to `wait_for_skill_run`. The project is required either way — "
                + "there is no default and no nearest match.",
            inputSchema: ["type": "object",
                          "properties": projectArgument.merging([
                              "skill": ["type": "string",
                                        "description": "Skill name, as `project_capabilities` reports it."],
                              "prompt": ["type": "string",
                                         "description": "Optional extra instructions for the run."],
                          ]) { a, _ in a },
                          "required": ["project", "skill"],
                          "additionalProperties": false]
        ) { arguments in
            // Resolved against this project as well as the links — but `project` stays
            // REQUIRED in the schema. What made a shared skill list dangerous was a
            // skill name that could belong to either project; a required argument with
            // no default cannot reintroduce it, while an optional one would.
            let target = try runtimeReader(for: arguments)
            let isOwn = target.path == owner.path
            guard target.exists else {
                throw MCPServer.ToolError("\(target.path) no longer exists on disk.")
            }
            guard let skill = arguments.string("skill")?.nilIfEmpty else {
                throw MCPServer.ToolError("Which skill? Give its name.")
            }
            // Checked here so a typo is a clear error now, rather than a confirmation
            // the user approves for a skill that turns out not to exist.
            guard let match = target.skills().first(where: { $0.name == skill }) else {
                let known = target.skills().map(\.name).joined(separator: ", ")
                throw MCPServer.ToolError(known.isEmpty
                    ? "\(target.name) defines no skills."
                    : "\(target.name) has no skill \"\(skill)\". It has: \(known)")
            }

            let id = UUID().uuidString
            let stamp = ISO8601DateFormatter().string(from: Date())
            try owner.appendRequest([
                "id": id,
                "projectPath": target.path,
                "projectName": target.name,
                "skill": match.name,
                "prompt": arguments.string("prompt") ?? "",
                "requestedAt": stamp,
                "status": "pending",
                "requestedBy": ProcessInfo.processInfo.environment["CS_TAB_NAME"] ?? "",
            ])
            return jsonText([
                "request_id": id,
                "status": "pending",
                "project": target.name,
                "skill": match.name,
                "next": isOwn
                    ? "Claude Studio starts this on its next poll — a few seconds — in a tab "
                      + "of this project's window, and it needs that window to be open. Call "
                      + "wait_for_skill_run with this request_id for the report."
                    : "Claude Studio is asking \(owner.name)'s window to confirm this "
                      + "run. Call wait_for_skill_run with this request_id to wait for the "
                      + "result. Nothing has run yet.",
            ])
        },

        // MARK: wait_for_skill_run
        MCPServer.Tool(
            name: "wait_for_skill_run",
            title: "Wait for a linked skill run to finish",
            description: "Waits for a run started by `run_skill` and returns its outcome: "
                + "the exit code and the report the skill wrote. Returns early — without "
                + "failing — if the user has not confirmed yet or the run is still going, "
                + "so a long deploy is polled rather than blocked on.",
            inputSchema: ["type": "object",
                          "properties": [
                              "request_id": ["type": "string",
                                             "description": "The id `run_skill` returned."],
                              "timeout_sec": ["type": "integer",
                                              "description": "How long to wait (default 120, max 600)."],
                          ] as [String: Any],
                          "required": ["request_id"],
                          "additionalProperties": false]
        ) { arguments in
            guard let id = arguments.string("request_id")?.nilIfEmpty else {
                throw MCPServer.ToolError("Which request? Give the id run_skill returned.")
            }
            let limit = min(max(arguments.int("timeout_sec") ?? 120, 5), 600)
            let deadline = Date().addingTimeInterval(TimeInterval(limit))

            var current: [String: Any]?
            repeat {
                guard let found = owner.request(id: id) else {
                    throw MCPServer.ToolError("No request \(id) in \(owner.name).")
                }
                current = found
                let status = found.string("status") ?? "pending"
                if status != "pending", status != "running" { break }
                if Date() >= deadline { break }
                // Polling, not a watcher: this process is a short-lived stdio server
                // and the app writes the answer through an atomic replace anyway.
                Thread.sleep(forTimeInterval: 2)
            } while true

            guard let request = current else {
                throw MCPServer.ToolError("No request \(id) in \(owner.name).")
            }
            let status = request.string("status") ?? "pending"
            let target = ProjectReader(path: request.string("projectPath") ?? "")
            let skill = request.string("skill") ?? ""

            var out: [String: Any] = ["request_id": id, "status": status,
                                      "project": target.name, "skill": skill]
            if let note = request.string("note") { out["note"] = note }

            switch status {
            case "finished":
                let code = request.int("exitCode") ?? 0
                out["exit_code"] = code
                out["result"] = code == 0 ? "success" : "failed"
                if let report = target.latestReport(skill: skill) { out["report"] = report }
            case "declined":
                out["result"] = "The user declined this run. Do not ask again unless they "
                    + "bring it up; nothing was run."
            case "failed":
                out["result"] = "The run could not be started."
            case "pending":
                out["result"] = "Still waiting for the user to confirm in Claude Studio. "
                    + "Nothing has run. Call again to keep waiting, or tell them it is "
                    + "waiting for them."
            default:
                out["result"] = "Still running in a tab in \(owner.name)'s window. If it is "
                    + "asking a question it is waiting for the user there. Call again to "
                    + "keep waiting."
            }
            return jsonText(out)
        },

        // MARK: skill_runs
        MCPServer.Tool(
            name: "skill_runs",
            title: "Read what a scheduled skill reported",
            description: "The reports a skill's runs have written — scheduled or manual — "
                + "newest first: when each ran, the status and summary it recorded, and the "
                + "report file. Give `run` to read one in full (a stamp as this tool lists "
                + "them, or \"latest\"). Omit `skill` to see which skills have runs at all. "
                + "Works for THIS project and for linked ones; omit `project` for this one.",
            inputSchema: ["type": "object",
                          "properties": runtimeProjectArgument.merging([
                              "skill": ["type": "string",
                                        "description": "Skill name. Omit to list the skills that have runs."],
                              "run": ["type": "string",
                                      "description": "A run stamp, or \"latest\", to read that report in full."],
                              "limit": ["type": "integer",
                                        "description": "How many runs to list (default 10)."],
                          ]) { a, _ in a },
                          "additionalProperties": false]
        ) { arguments in
            let reader = try runtimeReader(for: arguments)
            guard let skill = arguments.string("skill")?.nilIfEmpty else {
                let all = reader.skillsWithRuns()
                return all.isEmpty
                    ? "No skill of \(reader.name) has produced a run report yet."
                    : jsonText(["project": reader.name, "skills_with_runs": all])
            }
            let all = reader.runs(skill: skill)
            guard !all.isEmpty else {
                return "\(skill) has no run reports in \(reader.name)."
            }

            if let wanted = arguments.string("run")?.nilIfEmpty {
                let hit = wanted.lowercased() == "latest"
                    ? all.first
                    : all.first { $0.stamp == wanted }
                        ?? all.first { $0.stamp.hasPrefix(wanted) }
                guard let hit else {
                    throw MCPServer.ToolError("\(skill) has no run \"\(wanted)\". "
                        + "It has: \(all.prefix(10).map(\.stamp).joined(separator: ", "))")
                }
                let text = (try? String(contentsOf: hit.file, encoding: .utf8)) ?? ""
                return "\(reader.name) · \(skill) · \(hit.stamp)\n\n\(text)"
            }

            let limit = min(max(arguments.int("limit") ?? 10, 1), 100)
            return jsonText(["project": reader.name, "skill": skill,
                             "runs": all.prefix(limit).map(\.json)])
        },

        // MARK: define_service
        MCPServer.Tool(
            name: "define_service",
            title: "Add, change or remove a service",
            description: "Writes this project's `.cs/services.json` — the long-running "
                + "processes Claude Studio starts and watches (a dev server, a queue worker). "
                + "Defining one does not start it; use `control_service` for that. Only this "
                + "project, never a linked one.",
            inputSchema: ["type": "object",
                          "properties": [
                              "name": ["type": "string",
                                       "description": "Service name. Identifies it for every other tool."],
                              "action": ["type": "string", "enum": ["add", "update", "remove"],
                                         "description": "Default \"add\", which updates one that already exists."],
                              "command": ["type": "string",
                                          "description": "Shell command to run, e.g. `npm run dev`."],
                              "cwd": ["type": "string",
                                      "description": "Where it runs. Relative to the project root, or absolute. Default: the root."],
                              "port": ["type": "integer",
                                       "description": "The port it listens on, if any — shown in the sidebar and used for its status."],
                              "auto_start": ["type": "boolean",
                                             "description": "Start it when the project window opens."],
                          ] as [String: Any],
                          "required": ["name"],
                          "additionalProperties": false]
        ) { arguments in
            guard let name = arguments.string("name")?.nilIfEmpty else {
                throw MCPServer.ToolError("Which service? Give its name.")
            }
            let action = arguments.string("action")?.lowercased() ?? "add"
            var all = owner.rawCS("services.json")
            let index = all.firstIndex { $0.string("name") == name }

            if action == "remove" {
                guard let index else {
                    throw MCPServer.ToolError("\(owner.name) has no service \"\(name)\".")
                }
                all.remove(at: index)
                try owner.writeCS("services.json", all)
                return "Removed the service \(name) from \(owner.name). If it was running, "
                    + "it is still running — nothing was stopped."
            }
            if action == "update", index == nil {
                throw MCPServer.ToolError("\(owner.name) has no service \"\(name)\" to update.")
            }

            var entry = index.map { all[$0] } ?? ["id": UUID().uuidString, "name": name]
            if let command = arguments.string("command") { entry["command"] = command }
            if let cwd = arguments.string("cwd") { entry["cwd"] = cwd }
            if let port = arguments.int("port") { entry["port"] = port }
            if let auto = arguments["auto_start"] as? Bool { entry["autoStart"] = auto }
            guard (entry.string("command")?.nilIfEmpty) != nil else {
                throw MCPServer.ToolError("A service needs a command to run.")
            }
            if let index { all[index] = entry } else { all.append(entry) }
            try owner.writeCS("services.json", all)
            return "\(index == nil ? "Added" : "Updated") the service \(name) in \(owner.name): "
                + "`\(entry.string("command") ?? "")`. It appears in the sidebar at once; "
                + "start it with control_service."
        },

        // MARK: define_script
        MCPServer.Tool(
            name: "define_script",
            title: "Add, change or remove a script",
            description: "Writes this project's `.cs/scripts.json` — the one-shot commands "
                + "the sidebar keeps a button for (build, test, migrate). A script is not a "
                + "service: it runs once in its own tab and shows its exit code. Only this "
                + "project, never a linked one.",
            inputSchema: ["type": "object",
                          "properties": [
                              "name": ["type": "string", "description": "Script name."],
                              "action": ["type": "string", "enum": ["add", "update", "remove"],
                                         "description": "Default \"add\", which updates one that already exists."],
                              "command": ["type": "string", "description": "Shell command to run."],
                              "cwd": ["type": "string",
                                      "description": "Where it runs. Relative to the project root, or absolute. Default: the root."],
                          ] as [String: Any],
                          "required": ["name"],
                          "additionalProperties": false]
        ) { arguments in
            guard let name = arguments.string("name")?.nilIfEmpty else {
                throw MCPServer.ToolError("Which script? Give its name.")
            }
            let action = arguments.string("action")?.lowercased() ?? "add"
            var all = owner.rawCS("scripts.json")
            let index = all.firstIndex { $0.string("name") == name }

            if action == "remove" {
                guard let index else {
                    throw MCPServer.ToolError("\(owner.name) has no script \"\(name)\".")
                }
                all.remove(at: index)
                try owner.writeCS("scripts.json", all)
                return "Removed the script \(name) from \(owner.name)."
            }
            if action == "update", index == nil {
                throw MCPServer.ToolError("\(owner.name) has no script \"\(name)\" to update.")
            }

            var entry = index.map { all[$0] } ?? ["id": UUID().uuidString, "name": name]
            if let command = arguments.string("command") { entry["command"] = command }
            if let cwd = arguments.string("cwd") { entry["cwd"] = cwd }
            guard (entry.string("command")?.nilIfEmpty) != nil else {
                throw MCPServer.ToolError("A script needs a command to run.")
            }
            if let index { all[index] = entry } else { all.append(entry) }
            try owner.writeCS("scripts.json", all)
            return "\(index == nil ? "Added" : "Updated") the script \(name) in \(owner.name): "
                + "`\(entry.string("command") ?? "")`."
        },

        // MARK: control_service
        MCPServer.Tool(
            name: "control_service",
            title: "Start, stop or restart a service",
            description: "Starts, stops or restarts one of THIS project's services. Claude "
                + "Studio does it, not this tool: a service is a tmux session the app owns "
                + "and watches, and starting one behind its back would leave the app calling "
                + "it stopped while it serves requests. Needs the project's window to be "
                + "open. Read what it then printed with `read_output`.",
            inputSchema: ["type": "object",
                          "properties": [
                              "name": ["type": "string",
                                       "description": "Service name, as `project_capabilities` or `project_runtime` reports it."],
                              "action": ["type": "string", "enum": ["start", "stop", "restart"],
                                         "description": "Default \"start\"."],
                              "timeout_sec": ["type": "integer",
                                              "description": "How long to wait for Claude Studio to act (default 20, max 120)."],
                          ] as [String: Any],
                          "required": ["name"],
                          "additionalProperties": false]
        ) { arguments in
            guard let name = arguments.string("name")?.nilIfEmpty else {
                throw MCPServer.ToolError("Which service? Give its name.")
            }
            let action = arguments.string("action")?.lowercased() ?? "start"
            guard ["start", "stop", "restart"].contains(action) else {
                throw MCPServer.ToolError("action must be start, stop or restart.")
            }
            let defined = owner.services().compactMap { $0.string("name") }
            guard defined.contains(where: { $0 == name }) else {
                throw MCPServer.ToolError(defined.isEmpty
                    ? "\(owner.name) defines no services. Add one with define_service."
                    : "\(owner.name) has no service \"\(name)\". It has: "
                      + defined.joined(separator: ", "))
            }

            let id = UUID().uuidString
            try owner.appendControl([
                "id": id,
                "action": action,
                "target": name,
                "requestedAt": ISO8601DateFormatter().string(from: Date()),
                "status": "pending",
            ])

            // The app consumes the queue on its four-second poll, so this waits rather
            // than reporting a request nobody has read yet.
            let limit = min(max(arguments.int("timeout_sec") ?? 20, 5), 120)
            let deadline = Date().addingTimeInterval(TimeInterval(limit))
            var settled: [String: Any]?
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 1.5)
                guard let current = owner.controlRequest(id: id) else { break }
                if current.string("status") != "pending" { settled = current; break }
            }

            guard let settled else {
                return "Asked Claude Studio to \(action) \(name), but nothing has picked the "
                    + "request up. That means no window is open for \(owner.name) — the app "
                    + "acts on these, and it is not running this project. The request stays "
                    + "queued and will run when the project is opened."
            }
            if settled.string("status") == "failed" {
                throw MCPServer.ToolError(settled.string("note") ?? "Claude Studio refused it.")
            }

            // "Done" means the app acted: a stop is Ctrl-C first and a kill three
            // seconds later, so the pane is what says whether it is really gone.
            Thread.sleep(forTimeInterval: action == "start" ? 1.5 : 3.5)
            let pane = owner.panes().first { $0.kind == "service" && $0.title == name }
            var out: [String: Any] = ["service": name, "action": action,
                                      "project": owner.name]
            if let pane {
                out["state"] = pane.dead ? "exited" : "running"
                if let code = pane.exitCode { out["exit_code"] = code }
                if !pane.dead, let pid = pane.pid {
                    let ports = owner.listeningPorts(pid: pid)
                    if !ports.isEmpty { out["listening_ports"] = ports }
                }
            } else {
                out["state"] = action == "stop" ? "stopped" : "no pane yet"
            }
            out["next"] = "Read what it printed with read_output(name: \"\(name)\")."
            return jsonText(out)
        },

        // MARK: read_file
        MCPServer.Tool(
            name: "read_file",
            title: "Read a file from a linked project",
            description: "Reads a file inside a linked project. Use this for read-only links; "
                + "when a link allows edits the project is in your working directories and your "
                + "normal Read tool is better.",
            inputSchema: ["type": "object",
                          "properties": projectArgument.merging([
                              "path": ["type": "string",
                                       "description": "Path relative to the project root."],
                              "from_line": ["type": "integer", "description": "First line (1-based)."],
                              "lines": ["type": "integer", "description": "How many lines."],
                          ]) { a, _ in a },
                          "required": ["path"],
                          "additionalProperties": false]
        ) { arguments in
            let (reader, _) = try reader(for: arguments)
            guard let path = arguments.string("path")?.nilIfEmpty else {
                throw MCPServer.ToolError("Which file? Give a path relative to the project root.")
            }
            return try reader.readFile(path, from: arguments.int("from_line"),
                                       lines: arguments.int("lines"))
        },

        // MARK: search_files
        MCPServer.Tool(
            name: "search_files",
            title: "Search a linked project",
            description: "Greps a linked project for a pattern, skipping .git, node_modules, "
                + "vendor and .build. Returns file:line:text.",
            inputSchema: ["type": "object",
                          "properties": projectArgument.merging([
                              "pattern": ["type": "string", "description": "Pattern to grep for."],
                              "limit": ["type": "integer",
                                        "description": "Maximum matches to return (default 100)."],
                          ]) { a, _ in a },
                          "required": ["pattern"],
                          "additionalProperties": false]
        ) { arguments in
            let (reader, _) = try reader(for: arguments)
            guard let pattern = arguments.string("pattern")?.nilIfEmpty else {
                throw MCPServer.ToolError("What should I search for?")
            }
            let matches = reader.search(pattern, limit: arguments.int("limit") ?? 100)
            return matches.nilIfEmpty ?? "No matches for \(pattern) in \(reader.name)."
        },
    ]
)

server.log("serving \(owner.name) (\(owner.path)), \(links().count) link(s)")
server.run()
