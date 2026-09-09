import Foundation
import AppKit
import Combine

/// The one reader of the hook's session-state files, of tmux's pane titles and of
/// what the waiting sessions have on screen.
///
/// App-wide on purpose, for the same reason `UsageMonitor` is. All three sources
/// are GLOBAL — `session-state/` holds every project's sessions and `list-panes -a`
/// every project's panes — so a per-window poll did the identical work N times and
/// then drew the identical conclusion N times. With six windows open that was six
/// `tmux` forks and six full directory reads every 1.5 s, all on the main thread,
/// which is what made the app heavier with every window rather than with every
/// session.
///
/// It also owns the waiting announcement, and that is the fix for the notification
/// naming the wrong project: each window's engine used to announce whatever it read
/// out of the shared directory under ITS OWN `projectName`, so a session finishing in
/// project A was announced N times, once per open window, each time titled with that
/// window's project. The state file has carried `project` and `name` all along —
/// they are what the banner says now, and it is said once.
///
/// And it is where orange came to mean something. A hook says a session handed the
/// turn back; it cannot say whether that turn ended on a question. So the waiting
/// sessions' screens are read (`PaneReader`) and the two are combined: a question
/// stays orange until it is ANSWERED, a finished turn until it is SEEN. Everything
/// else — the island, the dock badge, the tab dots — reads the result rather than
/// the raw hook.
@MainActor
final class SessionStates: ObservableObject {
    static let shared = SessionStates()

    /// One live Claude session, wherever it belongs. This is what the island shows
    /// and what it needs to reach a window: the tab key to select, and the project
    /// path to open if no window has it.
    struct Live: Identifiable, Equatable {
        var key: String
        var tmux: String
        var name: String
        var project: String
        var projectPath: String
        var attention: Attention
        /// The question a selected numbered prompt is asking, when there is one.
        var question: String?
        /// The last thing the session said, for everything else.
        var detail: String?
        var at: Date

        var id: String { key }
        /// The one line worth showing under the name.
        var headline: String? { question?.nilIfEmpty ?? detail?.nilIfEmpty }
    }

    /// Tab key → Claude's live state.
    @Published private(set) var attention: [String: Attention] = [:]
    /// tmux session name → the live title Claude sets.
    @Published private(set) var paneTitles: [String: String] = [:]
    /// Tab key → Claude's own session id (for `--resume`).
    @Published private(set) var claudeSIDs: [String: String] = [:]
    /// Every Claude session the whole app knows about, most recent event first.
    @Published private(set) var live: [Live] = []

    /// The ones that are actually on the user: a question, or a finished turn
    /// nobody has looked at yet. Questions first — they are the ones that cannot
    /// be cleared by looking.
    var actionable: [Live] {
        live.filter { $0.attention.needsAttention }
            .sorted {
                if $0.attention.isQuestion != $1.attention.isQuestion {
                    return $0.attention.isQuestion
                }
                return $0.at > $1.at
            }
    }

    var actionableCount: Int { live.reduce(0) { $0 + ($1.attention.needsAttention ? 1 : 0) } }
    var workingCount: Int { live.reduce(0) { $0 + ($1.attention == .working ? 1 : 0) } }

    private var timer: Timer?
    private var ticking = false
    /// The first tick only records: every session that was already waiting when the
    /// app launched would otherwise announce itself at once.
    private var seeded = false
    /// Ticks since the last stale-file sweep.
    private var sweepCountdown = 0

    /// Finished turns the user has already looked at — tab key → the timestamp of
    /// the state that was seen.
    ///
    /// The TIMESTAMP is what makes this survive a relaunch honestly. Recording
    /// only the key would mean a session that finished again while the app was
    /// closed came back quietly, and that is the one case where it must not:
    /// what was seen is a particular finish, not the session. In memory the same
    /// job is done by clearing the entry when the session goes back to work; the
    /// file has to answer for the hours nobody was watching.
    private var seen: [String: Double] = [:]
    /// So the file is written when the answer changes and not once a poll.
    private var seenOnDisk: [String: Double] = [:]
    /// Which tab each window is currently showing. A finished turn on a tab that
    /// is on screen — with the app in front — has been seen by definition; waiting
    /// for a separate "mark as read" gesture would leave the dot orange while the
    /// user watched the answer arrive.
    private var visible: [ObjectIdentifier: String] = [:]

    /// The last poll's raw material, so a change in what is on screen can be
    /// re-resolved without waiting for (or forcing) another poll.
    private var lastStates: [String: HookBridge.State] = [:]
    private var lastScreens: [String: PaneReader.Screen] = [:]
    private var lastLive: Set<String>?

    private var activeObserver: Any?

    private init() {}

    func start() {
        guard timer == nil else { return }
        loadSeen()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        // Coming back to the app is the gesture that makes "I have seen it" true
        // for whatever was already on screen.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in self.recompute() } }
    }

    // MARK: - What is on screen

    func setVisibleTab(_ key: String?, for owner: ObjectIdentifier) {
        let previous = visible[owner]
        if let key { visible[owner] = key } else { visible.removeValue(forKey: owner) }
        guard previous != visible[owner] else { return }
        // Deferred: selecting a tab happens inside a SwiftUI update, and
        // re-resolving publishes — which from there is the "publishing changes
        // from within view updates" that makes a window flicker.
        Task { @MainActor in self.recompute() }
    }

    func releaseVisible(for owner: ObjectIdentifier) {
        guard visible.removeValue(forKey: owner) != nil else { return }
        Task { @MainActor in self.recompute() }
    }

    /// Is this tab being looked at right now?
    private func isOnScreen(_ key: String) -> Bool {
        NSApp.isActive && visible.values.contains(key)
    }

    // MARK: - Polling

    private func tick() {
        // A slow tmux (or a slow disk) must not queue ticks up behind each other.
        guard !ticking else { return }
        ticking = true

        let sweeping = sweepCountdown <= 0
        if sweeping { sweepCountdown = 20 } else { sweepCountdown -= 1 }

        Task.detached(priority: .utility) {
            let states = HookBridge.readAll()
            let titles = Tmux.isAvailable ? Tmux.paneTitles() : [:]
            // Which sessions still exist, for the stale sweep — taken from the pane
            // list already in hand, NOT from `Tmux.sessions()`. That one lists only
            // sessions carrying `@cs_project`, and the tag is written 0.6 s after the
            // session is created: a session opened moments ago would have looked dead
            // and had its state file deleted out from under it.
            //
            // An empty result is never proof of anything — `paneTitles` returns `[:]`
            // for a tmux that failed as readily as for a tmux with nothing running, and
            // treating that as "everything is gone" would wipe every live session's
            // state.
            //
            // Read on EVERY tick, not only the sweeping one. The file is what the
            // hook left behind; the pane list is what is actually running, and
            // between the two there is a session that has been gone for up to half
            // a minute and is still being counted as waiting for you. That is not a
            // cosmetic lag: the island's rows are its own reason to exist, and a
            // row for a session that no longer exists opens a BRAND NEW one when it
            // is clicked. Deleting the file stays on the slow path — that is disk
            // work and can wait — but nothing dead is ever shown.
            let live: Set<String>? = Tmux.isAvailable && !titles.isEmpty
                ? Set(titles.keys) : nil
            if sweeping { HookBridge.sweepTemporaries() }

            // Only the sessions the hook says are waiting have anything worth
            // reading, and only ones tmux still knows about — a `capture-pane` on a
            // session that has gone away is an error in the middle of a chained
            // command, which would take the whole batch's output with it.
            let waiting = states.compactMap { key, state -> String? in
                guard state.state == "waiting",
                      let name = Self.tmuxName(ofTabKey: key),
                      titles[name] != nil else { return nil }
                return name
            }
            let screens = PaneReader.readAll(sessions: waiting)

            let readStates = states
            let readTitles = titles
            let readLive = live
            let readScreens = screens
            let readSweeping = sweeping
            await MainActor.run {
                self.lastStates = readStates
                self.lastScreens = readScreens
                self.lastLive = readLive
                self.apply(readStates, paneTitles: readTitles,
                           screens: readScreens, live: readLive, sweeping: readSweeping)
                self.ticking = false
            }
        }
    }

    /// Re-resolves the last poll's material. Used when what changed is not on disk
    /// — a tab was selected, or the app came forward.
    private func recompute() {
        guard seeded else { return }
        apply(lastStates, paneTitles: paneTitles, screens: lastScreens,
              live: lastLive, sweeping: false)
    }

    private func apply(_ states: [String: HookBridge.State],
                       paneTitles titles: [String: String],
                       screens: [String: PaneReader.Screen],
                       live alive: Set<String>?,
                       sweeping: Bool) {
        var next: [String: Attention] = [:]
        var sids: [String: String] = [:]
        var rows: [Live] = []

        for (key, state) in states {
            // A session whose tmux session is gone left its state file behind: the
            // `SessionEnd` hook only runs when Claude exits cleanly, and a killed
            // client never gets there. Left alone the file keeps a dead session
            // "waiting" forever — it inflates the Dock badge and shows a status for
            // something that is not running.
            let tmux = Self.tmuxName(ofTabKey: key)
            if let alive, let tmux, !alive.contains(tmux) {
                // Gone: skip it now, delete the file on the slow path.
                if sweeping { HookBridge.clearState(key) }
                seen.removeValue(forKey: key)
                continue
            }

            let screen = tmux.flatMap { screens[$0] }
            let resolved = resolve(key: key, state: state, screen: screen)
            next[key] = resolved
            if resolved == .seen { seen[key] = max(seen[key] ?? 0, state.ts ?? 0) }
            if resolved == .working { seen.removeValue(forKey: key) }
            if let sid = state.sid, !sid.isEmpty { sids[key] = sid }

            guard let tmux else { continue }
            rows.append(Live(key: key,
                             tmux: tmux,
                             name: state.name?.nilIfEmpty
                                ?? titles[tmux].flatMap(Self.cleanPaneTitle) ?? "Claude",
                             project: state.project?.nilIfEmpty ?? "Claude",
                             projectPath: state.ppath ?? "",
                             attention: resolved,
                             question: screen?.question,
                             detail: screen?.lastLine,
                             at: Date(timeIntervalSince1970: state.ts ?? 0)))
        }

        // Announce on the TRANSITION into needing you, once, named by the state
        // file's own project and session — not by whichever window happened to read
        // it.
        //
        // A key seen for the first time counts as a transition after the first tick.
        // It is a real one: the poll is 1.5 s and a short turn can start and finish
        // inside a single interval, so requiring a previously recorded `working` was
        // exactly how the quickest answers announced nothing at all.
        if seeded {
            for row in rows where row.attention.needsAttention
            && !(attention[row.key]?.needsAttention ?? false) {
                AppSettings.shared.announceWaiting(
                    session: row.name, project: row.project,
                    question: row.attention.isQuestion ? row.question : nil)
            }
        }
        seeded = true

        // Publishing an unchanged value still invalidates every view that reads it.
        // At 1.5 s intervals that was a full SwiftUI pass — and a repaint of every
        // tab bar, sidebar row and terminal chrome — twice a second, forever, whether
        // or not anything had happened.
        rows.sort { $0.at > $1.at }
        if next != attention { attention = next }
        if titles != paneTitles { paneTitles = titles }
        if rows != live { live = rows }
        if !sids.isEmpty {
            var merged = claudeSIDs
            merged.merge(sids) { _, new in new }
            if merged != claudeSIDs { claudeSIDs = merged }
        }

        // Counted off the same rows the island lists, so the two can never disagree
        // about how many things are on you.
        if AppSettings.shared.badgeEnabled {
            Notify.badge(rows.reduce(0) { $0 + ($1.attention.needsAttention ? 1 : 0) })
        }

        // A key with no state file left is a session that is gone; keeping its mark
        // would grow the file forever. Only written when the answer actually moved.
        if !states.isEmpty { seen = seen.filter { states[$0.key] != nil } }
        saveSeenIfNeeded()
    }

    // MARK: - Remembering what has been seen

    private func loadSeen() {
        guard let data = try? Data(contentsOf: Paths.seenSessionsFile),
              let stored = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return }
        seen = stored
        seenOnDisk = stored
    }

    private func saveSeenIfNeeded() {
        guard seen != seenOnDisk else { return }
        seenOnDisk = seen
        guard let data = try? JSONEncoder().encode(seen) else { return }
        Paths.writeAtomically(data, to: Paths.seenSessionsFile)
    }

    /// The whole point, in one place.
    ///
    /// `working` is green and clears any memory of having been read. A session that
    /// handed the turn back is a QUESTION when its screen holds a selected numbered
    /// prompt — that is the authority, because the prompt is drawn there and
    /// vanishes the moment it is answered. Only when the screen cannot be read at
    /// all does the hook get a say, and even then the sixty-second idle reminder is
    /// refused: it fires on every finished turn left alone for a minute, and taking
    /// it for a question would put every one of them back into orange forever.
    private func resolve(key: String, state: HookBridge.State,
                         screen: PaneReader.Screen?) -> Attention {
        switch state.state {
        case "working":
            return .working
        case "waiting":
            let asking = screen?.isAsking ?? state.hookSuggestsQuestion
            if asking { return .waiting }
            if let at = seen[key], at >= (state.ts ?? 0) { return .seen }
            return isOnScreen(key) ? .seen : .done
        default:
            return .idle
        }
    }

    /// `session:<tmux name>` → `<tmux name>`; `nil` for anything that is not a
    /// session key, which must never be swept.
    nonisolated private static func tmuxName(ofTabKey key: String) -> String? {
        key.hasPrefix("session:") ? String(key.dropFirst("session:".count)) : nil
    }

    /// Claude's own title for the conversation, with the spinner glyph it prefixes
    /// while it is thinking removed.
    ///
    /// `nil` for anything that is not a conversation title: a pane nobody has run
    /// Claude in yet reports the hostname, and naming a session after the machine
    /// it is running on says even less than "Claude 209".
    static func cleanPaneTitle(_ raw: String) -> String? {
        var text = raw
        while let first = text.first, !first.isLetter, !first.isNumber {
            text.removeFirst()
        }
        let clean = text.trimmingCharacters(in: .whitespaces)
        guard clean.count > 3, clean.count < 120 else { return nil }
        if clean.hasSuffix(".local") || clean.hasSuffix(".lan") { return nil }
        let lower = clean.lowercased()
        for reject in ["zsh", "bash", "claude", "tmux", "login", "node"] where lower == reject {
            return nil
        }
        if clean == Host.current().localizedName { return nil }
        return clean
    }

    /// Forgets a key immediately, so a closed tab's status does not linger for a tick.
    func forget(_ key: String) {
        seen.removeValue(forKey: key)
        guard attention[key] != nil else { return }
        attention.removeValue(forKey: key)
        live.removeAll { $0.key == key }
    }
}
