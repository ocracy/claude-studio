import Foundation

/// Things only the app can do, asked for by a session through the bridge.
///
/// Most of what the bridge offers is a file read away, so it answers by itself. Two
/// things are not: **starting and stopping a service**. A service is a tmux session
/// the app created, whose lifetime is tied to the window (`StudioModel.stop` kills
/// them) and whose status the engine polls. A second process starting the same
/// session behind the app's back would produce a service the sidebar calls stopped
/// while it serves requests, and a "stop" that leaves the engine holding a corpse.
///
/// So the bridge asks and the app acts, through the same queue-file discipline
/// `LinkedRuns` uses: append here, the app picks it up on its poll and writes the
/// answer back. Unlike a linked run this needs no confirmation — it acts on the
/// session's OWN project, on a service that project already defines, and a session
/// that can run `npm run dev` in Bash is not being handed anything new. What it gets
/// is the app's bookkeeping instead of a process nothing is tracking.
///
/// With no window open for the project nothing consumes the queue: the request stays
/// `pending` and the bridge reports that Claude Studio is not running, which is the
/// truth and not a failure.
struct ControlRequest: Identifiable, Hashable, Codable {
    enum Action: String, Codable {
        case start, stop, restart
    }

    enum Status: String, Codable {
        case pending, done, failed
    }

    var id: String
    var action: Action
    /// The service's name, as `.cs/services.json` spells it.
    var target: String
    var requestedAt: Date
    var status: Status
    var note: String?

    init(action: Action, target: String) {
        self.id = UUID().uuidString
        self.action = action
        self.target = target
        self.requestedAt = Date()
        self.status = .pending
    }

    /// Decoded by hand for the reason every record in this app is: the synthesized
    /// decoder throws on a key a hand-written or older file lacks, and one bad entry
    /// must not take the whole queue down.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? box.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        id          = value(.id, UUID().uuidString)
        action      = Action(rawValue: value(.action, "start")) ?? .start
        target      = value(.target, "")
        requestedAt = value(.requestedAt, Date())
        status      = Status(rawValue: value(.status, "pending")) ?? .pending
        note        = value(.note, nil as String?)
    }
}

@MainActor
enum Control {

    static func read(_ project: Project) -> [ControlRequest] {
        guard let data = try? Data(contentsOf: Paths.controlRequests(project)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ControlRequest].self, from: data)) ?? []
    }

    static func write(_ requests: [ControlRequest], to project: Project) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(requests) else { return }
        Paths.writeAtomically(data, to: Paths.controlRequests(project))
    }

    /// Re-reads before writing: the bridge appends from another process, and starting
    /// from a stale copy would erase the request it just made.
    static func settle(_ id: String, in project: Project,
                       status: ControlRequest.Status, note: String) {
        var all = read(project)
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].status = status
        all[index].note = note
        // Settled entries older than an hour are the ones nobody will read back.
        let cutoff = Date().addingTimeInterval(-3_600)
        write(all.filter { $0.status == .pending || $0.requestedAt > cutoff }, to: project)
    }
}
