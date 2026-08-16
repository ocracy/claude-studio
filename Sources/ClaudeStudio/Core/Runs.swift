import Foundation
import SwiftUI

/// Skill çalışmalarının disk katmanı: `<proje>/.cs/runs/<skill>/`.
///
/// Ayrı bir veritabanı yoktur — **raporların kendisi durumdur**. "Son çalışma"
/// en yeni raporun `run_at` alanıdır. Böylece uygulama kapalıyken launchd bir
/// rapor üretse bile, açılışta hiçbir senkronizasyon gerekmeden doğru tablo
/// görünür.
enum Runs {

    /// Bir skill'in tüm çalışmaları, yeniden eskiye.
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

    static func state(project: Project, skill: String) -> RunState? {
        guard let data = try? Data(contentsOf: Paths.runState(project, skill: skill)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RunState.self, from: data)
    }

    /// `2026-08-16-2312.md` — sıralanabilir, çakışmasız.
    static func fileName(at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date) + ".md"
    }

    /// Skill'e geçilecek ortam değişkenleri. Önceki rapor da verilir — skill
    /// isterse kıyaslama yapabilir.
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

/// Açık projedeki skill çalışmalarının bellekteki görünümü.
@MainActor
final class RunStore: ObservableObject {
    /// skill adı → çalışmalar (yeniden eskiye).
    @Published private(set) var runs: [String: [SkillRun]] = [:]
    /// Şu anda çalıştığı bilinen skill'ler.
    @Published private(set) var running: Set<String> = []

    private let project: Project
    private var pollTimer: Timer?

    init(project: Project) {
        self.project = project
    }

    func runs(for skill: String) -> [SkillRun] { runs[skill] ?? [] }
    func latest(for skill: String) -> SkillRun? { runs[skill]?.first }
    func isRunning(_ skill: String) -> Bool { running.contains(skill) }

    /// Verilen skill'lerin çalışmalarını arka planda okur.
    func refresh(skills: [String]) {
        let project = self.project
        Task.detached(priority: .utility) {
            var out: [String: [SkillRun]] = [:]
            var live: Set<String> = []
            for skill in skills {
                out[skill] = Runs.list(project: project, skill: skill)
                if let state = Runs.state(project: project, skill: skill), state.isRunning,
                   let started = state.startedAt, Date().timeIntervalSince(started) < 3600 {
                    live.insert(skill)
                }
            }
            let (result, active) = (out, live)
            await MainActor.run {
                self.runs = result
                self.running = active
            }
        }
    }

    func refresh(skill: String) {
        let project = self.project
        Task.detached(priority: .utility) {
            let list = Runs.list(project: project, skill: skill)
            let state = Runs.state(project: project, skill: skill)
            await MainActor.run {
                self.runs[skill] = list
                if let state, state.isRunning { self.running.insert(skill) }
                else { self.running.remove(skill) }
            }
        }
    }

    /// Zamanlanmış çalışmaları yakalamak için düşük frekanslı yoklama —
    /// launchd uygulamadan bağımsız tetiklediğinde de liste tazelenir.
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

    /// Skill'i arka planda (sessiz) çalıştırır; bitince ses + bildirim.
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
                                body: "Çalışma başarısız (çıkış \(status)).", sound: Notify.alertSound)
                }
            }
        }
    }
}
