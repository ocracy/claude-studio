import Foundation

@MainActor
final class PlanUsage: ObservableObject {
    static let shared = PlanUsage()

    struct Limit: Identifiable, Equatable {
        enum Kind: Equatable { case session, weekly, scoped(String) }

        var kind: Kind
        var percent: Int
        var resetsAt: Date?

        var id: String {
            switch kind {
            case .session:          return "session"
            case .weekly:           return "weekly"
            case .scoped(let name): return "scoped:\(name)"
            }
        }

        var title: String {
            switch kind {
            case .session:          return "Session (5h)"
            case .weekly:           return "Week"
            case .scoped(let name): return "\(name) this week"
            }
        }

        func remaining(from now: Date = Date()) -> String? {
            guard let resetsAt else { return nil }
            let minutes = max(0, Int(resetsAt.timeIntervalSince(now) / 60))
            let days = minutes / 1440, hours = (minutes % 1440) / 60, rest = minutes % 60
            if days > 0 { return "\(days)d \(hours)h" }
            if hours > 0 { return "\(hours)h \(rest)m" }
            return "\(rest)m"
        }
    }

    @Published private(set) var limits: [Limit] = []
    @Published private(set) var fetchedAt: Date?

    private var timer: Timer?
    private var lastModified: Date?
    private static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")

    private init() {}

    var peak: Int { limits.map(\.percent).max() ?? 0 }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        let modified = (try? Self.file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != lastModified else {
            objectWillChange.send()
            return
        }
        lastModified = modified
        let file = Self.file
        Task.detached(priority: .utility) {
            let parsed = Self.read(file)
            await MainActor.run {
                if self.limits != parsed.limits { self.limits = parsed.limits }
                self.fetchedAt = parsed.fetchedAt
            }
        }
    }

    nonisolated private static func read(_ file: URL) -> (limits: [Limit], fetchedAt: Date?) {
        guard let data = try? Data(contentsOf: file) else { return ([], nil) }
        return parse(data)
    }

    nonisolated static func parse(_ data: Data) -> (limits: [Limit], fetchedAt: Date?) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cache["utilization"] as? [String: Any],
              let entries = utilization["limits"] as? [[String: Any]]
        else { return ([], nil) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return formatter.date(from: text) ?? plain.date(from: text)
        }

        let limits = entries.compactMap { entry -> Limit? in
            let percent = (entry["percent"] as? NSNumber)?.intValue ?? 0
            let resetsAt = date(entry["resets_at"])
            switch entry["kind"] as? String {
            case "session":
                return Limit(kind: .session, percent: percent, resetsAt: resetsAt)
            case "weekly_all":
                return Limit(kind: .weekly, percent: percent, resetsAt: resetsAt)
            case "weekly_scoped":
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                guard let name = (model?["display_name"] as? String)?.nilIfEmpty else { return nil }
                return Limit(kind: .scoped(name), percent: percent, resetsAt: resetsAt)
            default:
                return nil
            }
        }
        let fetchedAt = (cache["fetchedAtMs"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return (limits, fetchedAt)
    }
}
