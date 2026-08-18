import Foundation
import SwiftUI

/// The on-disk layer for skill runs: `<project>/.cs/runs/<skill>/`.
///
/// There is no separate database — **the reports themselves are the state**.
/// "Last run" is the newest report's `run_at`. So even when launchd produces a
/// report while the app is closed, opening it shows the right table with no
/// synchronisation at all.
enum Runs {

    /// Every run of a skill, newest first.
    static func list(project: Project, skill: String) -> [SkillRun] {
        let dir = Paths.runsDir(project, skill: skill)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap(parse)
            .sorted { a, b in
                switch (a.startedAt, b.startedAt) {
                case let (x?, y?): return x > y
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return a.fileStem > b.fileStem
                }
            }
    }

    static func latest(project: Project, skill: String) -> SkillRun? {
        list(project: project, skill: skill).first
    }

    static func parse(_ url: URL) -> SkillRun? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var run = SkillRun(url: url)
        let (fields, body) = Frontmatter.split(text)
        run.body = body
        if let fields {
            run.startedAt = Frontmatter.date(fields["run_at"])
            run.status = SkillRun.Status(raw: fields["status"])
            run.summary = fields["summary"]?.nilIfEmpty
            run.durationSec = fields["duration_sec"].flatMap(Double.init)
            run.trigger = fields["trigger"]?.nilIfEmpty
        }
        if run.startedAt == nil {
            run.startedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
        }
        return run
    }

    /// The tail of `.run.log` — what the runner is printing right now.
    ///
    /// Read whole and trimmed here rather than shelled out to `tail`: the runner caps
    /// the file at 500 lines when it finishes, so it never grows past a few hundred KB.
    static func logTail(project: Project, skill: String, lines: Int = 400) -> String {
        let url = Paths.runsDir(project, skill: skill).appendingPathComponent(".run.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }

    static func state(project: Project, skill: String) -> RunState? {
        guard let data = try? Data(contentsOf: Paths.runState(project, skill: skill)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RunState.self, from: data)
    }

    /// `2026-08-16-2312.md` — sortable and collision-free.
    static func fileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date) + ".md"
    }

    /// Environment handed to the skill. The previous report is included so the
    /// skill can compare if it wants to.
    static func environment(project: Project, skill: String, mode: String,
                            at date: Date = Date()) -> [String: String] {
        let dir = Paths.runsDir(project, skill: skill)
        let previous = latest(project: project, skill: skill)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        return [
            "CS_SKILL_NAME":   skill,
            "CS_PROJECT_PATH": project.path,
            "CS_PROJECT_NAME": project.name,
            "CS_RUN_DIR":      dir.path,
            "CS_REPORT_FILE":  dir.appendingPathComponent(fileName(at: date)).path,
            "CS_RUN_MODE":     mode,
            "CS_LAST_REPORT":  previous?.url.path ?? "",
            "CS_LAST_RUN_AT":  previous?.startedAt.map { iso.string(from: $0) } ?? "",
            "CS_LAST_STATUS":  previous?.status.rawValue ?? "",
            "CS_LAST_SUMMARY": previous?.summary ?? "",
        ]
    }
}

/// In-memory view of the open project's skill runs.
@MainActor
final class RunStore: ObservableObject {
    /// skill name → runs (newest first).
    @Published private(set) var runs: [String: [SkillRun]] = [:]
    /// Skills currently known to be running.
    @Published private(set) var running: Set<String> = []
    /// skill or command name → recorded uses (newest first).
    @Published private(set) var usage: [String: [UsageEvent]] = [:]

    private let project: Project
    private var pollTimer: Timer?

    init(project: Project) {
        self.project = project
    }

    func runs(for skill: String) -> [SkillRun] { runs[skill] ?? [] }
    func usage(for name: String) -> [UsageEvent] { usage[name] ?? [] }
    func latest(for skill: String) -> SkillRun? { runs[skill]?.first }
    func isRunning(_ skill: String) -> Bool { running.contains(skill) }

    /// Reads the given skills' runs in the background.
    func refresh(skills: [String]) {
        let project = self.project
        Task.detached(priority: .utility) {
            var out: [String: [SkillRun]] = [:]
            var used: [String: [UsageEvent]] = [:]
            var live: Set<String> = []
            for skill in skills {
                out[skill] = Runs.list(project: project, skill: skill)
                let events = Runs.usage(project: project, skill: skill)
                if !events.isEmpty { used[skill] = events }
                if let state = Runs.state(project: project, skill: skill), state.isRunning,
                   let started = state.startedAt, Date().timeIntervalSince(started) < 3600 {
                    live.insert(skill)
                }
            }
            let (result, active, usageResult) = (out, live, used)
            await MainActor.run {
                self.runs = result
                self.running = active
                self.usage = usageResult
            }
        }
    }

    func refresh(skill: String) {
        let project = self.project
        Task.detached(priority: .utility) {
            let list = Runs.list(project: project, skill: skill)
            let events = Runs.usage(project: project, skill: skill)
            let state = Runs.state(project: project, skill: skill)
            await MainActor.run {
                self.runs[skill] = list
                self.usage[skill] = events
                if let state, state.isRunning { self.running.insert(skill) }
                else { self.running.remove(skill) }
            }
        }
    }

    /// Low-frequency polling so scheduled runs are noticed: launchd fires
    /// independently of the app, and the list still refreshes.
    func startPolling(skills: @escaping () -> [String]) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in self.refresh(skills: skills()) }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Marks a skill as running before its state file exists. The runner writes that
    /// file itself, but only once zsh has started — until then the pane would show
    /// nothing at all after a press of "Run now".
    func markRunning(_ skill: String) { running.insert(skill) }

    /// Runs the skill silently in the background; announces when it finishes.
    func runInBackground(skill: String) {
        guard !running.contains(skill) else { return }
        running.insert(skill)
        Paths.ensure(Paths.runsDir(project, skill: skill))
        let script = Scheduler.writeRunnerScript(project: project, skill: skill,
                                                 prompt: Scheduler.promptFor(project: project, skill: skill))
        let project = self.project
        Shell.runAsync("/bin/zsh", [script.path]) { status, _ in
            Task { @MainActor in
                self.running.remove(skill)
                self.refresh(skill: skill)
                if status != 0 {
                    Notify.post(title: project.name, subtitle: skill,
                                body: "Run failed (exit \(status)).", sound: Notify.alertSound)
                }
            }
        }
    }
}
