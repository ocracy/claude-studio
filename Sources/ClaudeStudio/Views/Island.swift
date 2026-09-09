import SwiftUI
import AppKit
import Combine

/// The island: every project's Claude sessions, on top of everything else.
///
/// The problem it answers is not one Claude Studio could solve inside its own
/// window. A session that hands the turn back does so while you are somewhere
/// else entirely — that is the point of it running in the background — and the
/// only thing that reached you there was a banner, which is gone a second later
/// and names one session at a time. Meanwhile the answer to "which of these
/// eighteen wants something?" lived behind bringing a window forward per project.
///
/// So it lives IN the menu bar strip, flush with the top of the screen, and on a
/// Mac with a notch it wears the notch: collapsed, it is exactly as tall as the
/// camera housing and wide enough to show a badge on either side of it, so the
/// black it draws reads as part of the hardware rather than as a window. Below the
/// menu bar was the wrong place and obviously so — it sat on top of whatever was
/// being read, which is the one thing a status surface must never do.
///
/// Hovering opens it downward into the list. A row is `project › session` with the
/// last thing that session said underneath; clicking it goes there — to the window
/// if one is open, and by opening the project if not.
@MainActor
final class Island: ObservableObject {
    static let shared = Island()

    /// Open, because the pointer is on it.
    @Published fileprivate var expanded = false

    private var panel: NSPanel?
    private var hosting: IslandHost?
    private var observers: [AnyCancellable] = []
    /// Runs only while the island is open. See `checkPointer`.
    private var hoverPoll: Timer?
    private var outsideTicks = 0
    /// Open because something is asking, not because the pointer is here.
    private var pinned = false
    /// Questions already noticed, so opening happens once per question.
    private var announcedQuestions: Set<String> = []
    private var noticedOnce = false
    /// Has the pointer been over the island since it opened itself?
    private var pinAcknowledged = false
    /// The frame the panel is currently laid out for, so an unchanged tick does
    /// not restart the animation.
    private var currentFrame: NSRect = .zero

    /// Where the top of the screen actually is, and how much of it the camera
    /// takes. Cached rather than read per layout so the window frame and the view
    /// inside it can never be laid out against two different answers.
    @Published fileprivate private(set) var top = TopGeometry.current()

    // Geometry. Fixed row heights are not a shortcut: the window frame is what
    // gets animated, so AppKit has to know the height before SwiftUI lays out.
    /// Each badge beside the notch. Constant, so the collapsed strip does not
    /// change width every time a count gains a digit.
    fileprivate static let lobeWidth: CGFloat = 62
    fileprivate static let expandedWidth: CGFloat = 470
    /// Two lines of text under the name, not one: the point of the row is what
    /// the session is saying, and a single truncated line was a hint rather than
    /// a message.
    fileprivate static let rowHeight: CGFloat = 60
    fileprivate static let optionHeight: CGFloat = 30
    /// Claude's prompts run to three or four; past that the island is a dialog.
    fileprivate static let maxOptions = 4
    /// The mesh alert. Its own constant for the same reason every other height here
    /// is one: the frame is animated, so AppKit needs the number before SwiftUI runs.
    fileprivate static let alertHeight: CGFloat = 38
    /// The settings row. It moved down here to give the header's right lobe to
    /// the filter — which is the thing you reach for while looking at the list,
    /// and settings is not.
    fileprivate static let footerHeight: CGFloat = 30
    fileprivate static let maxExpandedHeight: CGFloat = 460
    fileprivate static let maxRows = 12

    private init() {}

    func start() {
        observers.append(SessionStates.shared.objectWillChange.sink { [weak self] _ in
            // The publish has not happened yet at this point; the next runloop turn
            // is when the values are readable.
            Task { @MainActor in
                self?.noticeQuestions()
                self?.sync()
            }
        })
        observers.append(AppSettings.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.sync() }
        })
        // Without this the alert row would only appear the next time something else
        // happened to publish — and "nothing else is happening" is precisely the
        // state a dead tunnel produces.
        observers.append(PhoneBridge.shared.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.sync() }
        })
        // A different display, a resolution change, the menu bar auto-hiding: all
        // of them move the one place this window is allowed to be.
        observers.append(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.sync(force: true) } })
        sync(force: true)
    }

    /// Puts the panel where it belongs, at the size the current content needs —
    /// or takes it away.
    func sync(force: Bool = false) {
        guard AppSettings.shared.islandEnabled else { teardown(); return }
        let panel = panel ?? makePanel()
        // The view redraws itself: it observes `SessionStates` directly, and
        // replacing `rootView` on every poll would rebuild the whole tree twice a
        // second for a list that usually has not moved.
        let frame = targetFrame()
        // A shadow belongs to something that floats above what is behind it. The
        // collapsed strip is meant to BE the notch, and a soft grey halo down its
        // sides is exactly the seam that gives it away — so it only casts one once
        // it has opened into a panel.
        if panel.hasShadow != expanded { panel.hasShadow = expanded }
        guard force || frame != currentFrame else { return }
        currentFrame = frame
        if panel.isVisible && !force {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: {
                panel.invalidateShadow()
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            panel.invalidateShadow()
        }
    }

    private func teardown() {
        hoverPoll?.invalidate()
        hoverPoll = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        currentFrame = .zero
        expanded = false
    }

    // MARK: - Hover

    /// Opening is driven by the tracking area; STAYING open is not.
    ///
    /// Enter and exit alone cannot work here, and the symptom is unmistakable: the
    /// window itself is what grows, so opening changes the very rect the tracking
    /// area is derived from, AppKit re-evaluates it mid-animation and synthesises
    /// an exit for a pointer that never moved — which collapses the window, which
    /// synthesises an enter, at whatever rate the machine can animate. So the exit
    /// is not believed at all. Once open, the pointer's actual location is compared
    /// against the panel, and it takes two consecutive misses to close: one miss is
    /// what an edge sliding past a stationary pointer looks like.
    fileprivate func pointerEntered() {
        guard !expanded, pointerIsInside(margin: 6) else { return }
        expanded = true
        outsideTicks = 0
        sync()
        startHoverPoll()
    }

    private func checkPointer() {
        guard expanded else { stopHoverPoll(); return }
        let inside = pointerIsInside(margin: 10)
        if inside { pinAcknowledged = true }
        // Held open by a question: it opened itself, so a pointer that never asked
        // for it must not be what takes it away. The hold ends when the question
        // does — or the moment it has been LOOKED at, which is the whole thing it
        // was trying to achieve; after that it is an ordinary panel again.
        if pinned {
            let stillAsking = SessionStates.shared.actionable
                .contains { $0.attention.isQuestion }
            if !stillAsking || pinAcknowledged { pinned = false }
        }
        if pinned { outsideTicks = 0; return }
        if inside { outsideTicks = 0; return }
        outsideTicks += 1
        guard outsideTicks >= 2 else { return }
        stopHoverPoll()
        expanded = false
        sync()
    }

    /// Opens itself when a session starts asking something.
    ///
    /// A question is the one state that cannot clear itself: it waits until it is
    /// answered, and until then that session is doing nothing at all. A banner
    /// says so once and is gone; a dot in a strip has to be noticed. So the island
    /// opens, and stays open until the question is answered — the pointer is not
    /// what put it there and must not be what takes it away.
    private func noticeQuestions() {
        let asking = Set(SessionStates.shared.actionable
            .filter { $0.attention.isQuestion }.map(\.key))
        let seeding = !noticedOnce
        noticedOnce = true
        defer { announcedQuestions = asking }
        // The first reading only records. A question that was already waiting when
        // the app launched is not news, and having the island fling itself open on
        // every start is how a thing that opens itself stops being trusted.
        guard !seeding, AppSettings.shared.islandEnabled,
              !asking.subtracting(announcedQuestions).isEmpty
        else { return }
        pinned = true
        pinAcknowledged = false
        guard !expanded else { sync(); return }
        expanded = true
        outsideTicks = 0
        sync()
        startHoverPoll()
    }

    private func startHoverPoll() {
        hoverPoll?.invalidate()
        hoverPoll = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
            Task { @MainActor in self.checkPointer() }
        }
    }

    /// Answers a numbered prompt without opening anything.
    ///
    /// Straight to tmux, which takes the keystroke whether or not a terminal is
    /// attached — so a question in a project with no window open is answerable
    /// from here too. WITHOUT Enter: Claude's prompts act on the keypress itself.
    fileprivate func answer(_ live: SessionStates.Live, option index: Int) {
        let session = live.tmux
        let digit = String(index + 1)
        Task.detached(priority: .userInitiated) { Tmux.sendKey(session, digit) }
        pinned = false
    }

    private func stopHoverPoll() {
        hoverPoll?.invalidate()
        hoverPoll = nil
        outsideTicks = 0
    }

    private func pointerIsInside(margin: CGFloat) -> Bool {
        guard let panel else { return false }
        var rect = panel.frame.insetBy(dx: -margin, dy: -margin)
        // Everything between the panel and the top of the screen counts as inside.
        // The panel is already flush, so this is normally nothing — but the pointer
        // can be reported a point or two above the screen's edge, and that must not
        // read as leaving.
        rect.size.height += max(0, top.frame.maxY - rect.maxY)
        return rect.contains(NSEvent.mouseLocation)
    }

    private func makePanel() -> NSPanel {
        let host = IslandHost(rootView: IslandView(island: self))
        host.onEnter = { [weak self] in self?.pointerEntered() }
        hosting = host

        let panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 26),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.contentView = host
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Switched on only while open (see `sync`). AppKit derives the shadow from
        // the content's alpha, so the open panel casts a correctly rounded one —
        // a SwiftUI shadow would be clipped away at the window's edge, which is
        // exactly where the panel ends.
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        // Above the windows of every app, on every space, and never in ⌘-tab.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        self.panel = panel
        return panel
    }

    // MARK: - Geometry

    /// What the list is narrowed to. Questions and unread finishes first, then
    /// whatever is still running — the order is the same whichever filter is on,
    /// so a row does not move when one is picked.
    fileprivate var rows: [SessionStates.Live] {
        let states = SessionStates.shared
        // WORKING FIRST. What is running is what you came to look at — it is the
        // only part of the list that changes while you watch it, and the rows
        // below are, by definition, not going anywhere.
        let working = states.live.filter { $0.attention == .working }
            .sorted { $0.at > $1.at }
        let waiting = states.actionable
        let all: [SessionStates.Live]
        switch AppSettings.shared.islandFilter {
        case "attention": all = waiting
        case "working":   all = working
        default:          all = working + waiting
        }
        return Array(all.prefix(Self.maxRows))
    }

    /// Rows carry their options with them, so a row is as tall as what it has to
    /// say. AppKit animates the window frame and therefore needs the total before
    /// SwiftUI lays anything out — which is why this is arithmetic rather than a
    /// measurement.
    fileprivate static func height(of row: SessionStates.Live) -> CGFloat {
        guard !row.options.isEmpty else { return rowHeight }
        return rowHeight + CGFloat(min(row.options.count, maxOptions)) * optionHeight + 6
    }

    fileprivate var filter: String {
        get { AppSettings.shared.islandFilter }
        set {
            guard newValue != AppSettings.shared.islandFilter else { return }
            AppSettings.shared.islandFilter = newValue
            objectWillChange.send()
            sync()
        }
    }

    private func targetFrame() -> NSRect {
        let geometry = TopGeometry.current()
        if geometry != top { top = geometry }

        // Both sizes start at the very top of the screen. The collapsed one is
        // exactly the height of the camera housing — any less and the black strip
        // stops short of the notch and stops reading as one thing with it.
        let size = expanded
            ? NSSize(width: Self.expandedWidth,
                     height: min(Self.maxExpandedHeight,
                                 geometry.strip + 16 + Self.footerHeight
                                 + (meshIsBroken ? Self.alertHeight : 0)
                                 + (rows.isEmpty ? Self.rowHeight
                                    : rows.reduce(0) { $0 + Self.height(of: $1) })))
            : NSSize(width: collapsedWidth, height: geometry.strip)

        return NSRect(x: geometry.frame.midX - size.width / 2,
                      y: geometry.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// The notch plus a badge on either side of it.
    ///
    /// Fixed, not sized to its text: the strip sits in the menu bar, and a black
    /// bar that grows and shrinks up there every time a session finishes is
    /// movement in the corner of the eye all day. With no notch the two badges
    /// simply sit next to each other.
    fileprivate var collapsedWidth: CGFloat { top.notchWidth + Self.lobeWidth * 2 }

    /// Phone access is switched on and the tunnel it needs is down.
    ///
    /// The island is where this belongs. A notification says it once and is gone a
    /// second later; this stays, in the one place that is visible while Claude Studio
    /// is not the app in front — which, for something you were about to reach for
    /// your phone to do, is every time it matters.
    fileprivate var meshIsBroken: Bool { PhoneBridge.shared.isBroken }

    fileprivate var summary: String {
        let states = SessionStates.shared
        let waiting = states.actionableCount
        let working = states.workingCount
        if waiting > 0 {
            let questions = states.actionable.filter { $0.attention.isQuestion }.count
            if questions > 0 && questions < waiting {
                return "\(questions) asking · \(waiting - questions) done"
            }
            return questions > 0 ? "\(waiting) asking" : "\(waiting) to read"
        }
        if working > 0 { return "\(working) working" }
        // Only once there is nothing to say about the sessions: a session asking a
        // question outranks a tunnel, and "all clear" is the one summary that would
        // be a lie while the phone cannot reach this Mac.
        if meshIsBroken { return "phone offline" }
        return "all clear"
    }

    fileprivate var summaryColor: Color {
        let states = SessionStates.shared
        if states.actionableCount > 0 { return Theme.waiting }
        if states.workingCount > 0 { return Theme.running }
        if meshIsBroken { return Theme.warning }
        return Color.white.opacity(0.35)
    }

    // MARK: - Going there

    fileprivate func open(_ live: SessionStates.Live) {
        stopHoverPoll()
        expanded = false
        sync()
        WindowManager.shared.reveal(live)
    }

    /// Settings are the application's, not a project's — but the gear lived in a
    /// project window's top bar, which meant reaching a global preference required
    /// first choosing a project it has nothing to do with. The island belongs to no
    /// window either, so it is the right place for it, and the only one that is
    /// there when every window is showing something else.
    fileprivate func openSettings() {
        stopHoverPoll()
        expanded = false
        sync()
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.show()
    }
}

/// The top of the screen, measured rather than assumed.
///
/// `safeAreaInsets.top` is the camera housing's height on the Macs that have one
/// and zero on the rest, so the menu bar's own thickness is the floor. The WIDTH
/// is not exposed anywhere, but the two areas beside it are
/// (`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`) and what they do not cover
/// is the notch.
///
/// The screen is chosen by whether it HAS a notch, not by which one is active: the
/// notch is on the built-in display, and an island that hops to whichever external
/// monitor happens to hold the key window would be in the right place roughly half
/// the time.
fileprivate struct TopGeometry: Equatable {
    var frame: NSRect
    /// The camera housing's height, or the menu bar's.
    var inset: CGFloat
    /// Zero on a Mac with no notch.
    var notchWidth: CGFloat

    /// A point taller than the housing. Stopping exactly at `inset` leaves a
    /// hairline of desktop between the black and the notch, and a hairline is all
    /// it takes for the strip to read as a window parked under the camera rather
    /// than as part of it.
    var strip: CGFloat { inset + 1 }

    static func current() -> TopGeometry {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else {
            return TopGeometry(frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                               inset: NSStatusBar.system.thickness, notchWidth: 0)
        }
        var notch: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = max(0, screen.frame.width - left.width - right.width)
        }
        return TopGeometry(frame: screen.frame,
                           inset: max(screen.safeAreaInsets.top, NSStatusBar.system.thickness),
                           notchWidth: notch)
    }
}

/// A panel that takes keyboard focus without bringing its application forward.
///
/// A borderless `NSPanel` refuses to become key, and SwiftUI's controls inside one
/// are unreliable as a result — a click lands on a window that cannot accept it,
/// and nothing happens. `.nonactivatingPanel` is what makes accepting it safe:
/// the panel becomes key, the app behind stays exactly where it was, and the row
/// that was pressed is the thing that decides what comes forward.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - The hosting view

/// Reports the pointer entering and leaving.
///
/// SwiftUI's `onHover` is not enough here: the panel never becomes key, and the
/// tracking area has to be `.activeAlways` for the hover to register while
/// another application is in front — which is the only time this window matters.
private final class IslandHost: NSHostingView<IslandView> {
    var onEnter: (() -> Void)?
    private var installed = false

    /// Installed ONCE. `.inVisibleRect` keeps the area in step with the bounds by
    /// itself, and tearing it down and rebuilding it on every layout pass — which
    /// is every frame of the open animation — is what made AppKit emit an exit and
    /// an enter per frame, and the island blink itself to pieces.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard !installed else { return }
        installed = true
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways,
                                                 .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    /// Deliberately empty: leaving is decided by where the pointer actually is,
    /// not by an event the window's own animation produces. See `Island`.
    override func mouseExited(with event: NSEvent) {}

    /// The panel is never key, so without this the first click on a row would be
    /// spent activating a window that cannot be activated.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: IslandView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - The view

private struct IslandView: View {
    @ObservedObject var island: Island
    @ObservedObject private var states = SessionStates.shared
    @ObservedObject private var bridge = PhoneBridge.shared
    @State private var alertHovering = false
    @State private var settingsHovering = false
    @State private var markHovering = false

    var body: some View {
        Group {
            if island.expanded { expanded } else { collapsed }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // Square at the top, rounded at the bottom. The top edge is the edge of
            // the SCREEN — rounding it would round nothing.
            //
            // No border, and pure black rather than a near-black: an outline is
            // what turns the strip back into a window sitting under the camera,
            // and next to a physical cut-out there is nothing for an edge to
            // separate it from.
            shape.fill(Color.black)
        }
        .animation(.easeOut(duration: 0.18), value: island.expanded)
    }

    private var shape: UnevenRoundedRectangle {
        let radius: CGFloat = island.expanded ? 16 : 11
        return UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 0, bottomLeading: radius,
                               bottomTrailing: radius, topTrailing: 0),
            style: .continuous)
    }

    // MARK: Collapsed

    /// A badge on either side of the camera. Nothing is drawn behind it — whatever
    /// went there would be invisible, and the gap is what makes the two badges read
    /// as belonging to the notch instead of floating beside it.
    private var collapsed: some View {
        notchStrip(leading: waitingBadge, trailing: workingBadge)
    }

    private func notchStrip<L: View, T: View>(leading: L, trailing: T) -> some View {
        HStack(spacing: 0) {
            leading
                .frame(width: lobeWidth, alignment: .leading)
                .padding(.leading, 12)
            Color.clear.frame(width: island.top.notchWidth)
            trailing
                .frame(width: lobeWidth, alignment: .trailing)
                .padding(.trailing, 12)
        }
        .frame(height: island.top.strip)
    }

    /// Each lobe carries 12 points of outer padding, so the two lobes plus the gap
    /// have to come to exactly the window's width — otherwise the gap stops being
    /// centred and the notch eats a badge.
    private var lobeWidth: CGFloat {
        island.expanded
            ? max(60, (Island.expandedWidth - island.top.notchWidth - 24) / 2)
            : Island.lobeWidth - 12
    }

    /// Left: what is on you. Right: what is still running.
    private var waitingBadge: some View {
        HStack(spacing: 5) {
            StatusDot(color: states.actionableCount > 0
                      ? Theme.waiting : Color.white.opacity(0.22), size: 6)
            Text("\(states.actionableCount)")
                .font(Theme.ui(11, .medium))
                .foregroundStyle(Color.white.opacity(states.actionableCount > 0 ? 0.9 : 0.35))
        }
    }

    /// Narrow the list to one colour, from the place you are already looking.
    ///
    /// It sits where the settings button used to, because this is what you reach
    /// for while reading the list and settings is not — those moved to the row at
    /// the bottom, which is still the only way to reach them with no project open.
    private var filterChips: some View {
        HStack(spacing: 4) {
            chip("all", isOn: island.filter == "all") { island.filter = "all" }
            chip(dot: Theme.waiting, isOn: island.filter == "attention") {
                island.filter = island.filter == "attention" ? "all" : "attention"
            }
            chip(dot: Theme.running, isOn: island.filter == "working") {
                island.filter = island.filter == "working" ? "all" : "working"
            }
        }
    }

    private func chip(_ title: String? = nil, dot: Color? = nil, isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let dot { StatusDot(color: dot, size: 6) }
                else if let title {
                    Text(title)
                        .font(Theme.ui(9.5, .medium))
                        .foregroundStyle(Color.white.opacity(isOn ? 0.85 : 0.4))
                }
            }
            .frame(width: 22, height: 18)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(isOn ? 0.14 : 0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title.map { "Show \($0)" }
              ?? (dot == Theme.waiting ? "Only what is on you" : "Only what is running"))
    }

    private var workingBadge: some View {
        HStack(spacing: 5) {
            if island.meshIsBroken {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.warning)
            }
            Text("\(states.workingCount)")
                .font(Theme.ui(11, .medium))
                .foregroundStyle(Color.white.opacity(states.workingCount > 0 ? 0.9 : 0.35))
            StatusDot(color: states.workingCount > 0
                      ? Theme.running : Color.white.opacity(0.22), size: 6)
        }
    }

    // MARK: Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            // The camera still sits in the top-center of the open panel, so the
            // header goes around it exactly as the collapsed strip does.
            notchStrip(
                leading: HStack(spacing: 6) {
                    StatusDot(color: island.summaryColor, size: 6)
                    Text(island.summary)
                        .font(Theme.ui(11, .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                },
                trailing: filterChips)

            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

            if island.meshIsBroken { meshAlert }

            if island.rows.isEmpty {
                Text(emptyText)
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(island.rows) { row in
                            IslandRow(live: row,
                                      open: { island.open(row) },
                                      answer: { island.answer(row, option: $0) })
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            settingsRow
        }
    }

    private var emptyText: String {
        switch island.filter {
        case "attention": return "Nothing is waiting on you."
        case "working":   return "Nothing is running."
        default:          return "Nothing is running."
        }
    }

    /// Settings belong to the application, not to a project — but the gear lived
    /// in a project window's top bar, so reaching a global preference meant first
    /// choosing a project it has nothing to do with. The island belongs to no
    /// window either, and it is the only surface that is there when every window
    /// is showing something else.
    private var settingsRow: some View {
        HStack(spacing: 0) {
            footerButton(icon: "gearshape", title: "settings",
                         hovering: settingsHovering) { island.openSettings() }
                .onHover { settingsHovering = $0 }

            Spacer(minLength: 8)

            // Only when there is something to clear, and it clears only the
            // finished turns — a question is answered or it is not.
            if states.unreadCount > 0 {
                footerButton(icon: "checkmark", title: "mark \(states.unreadCount) read",
                             hovering: markHovering) { states.markAllSeen() }
                    .onHover { markHovering = $0 }
            }
        }
        .frame(height: Island.footerHeight)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
        }
    }

    private func footerButton(icon: String, title: String, hovering: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9.5))
                Text(title).font(Theme.ui(10))
            }
            .foregroundStyle(Color.white.opacity(hovering ? 0.75 : 0.32))
            .padding(.horizontal, 14)
            .frame(height: Island.footerHeight)
            .background(Color.white.opacity(hovering ? 0.06 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One click, in the one place that is on screen while another app is in front.
    ///
    /// `osascript display notification` carries no action — a banner can say the
    /// tunnel is down and nothing more — so the fix needs a surface, and this is the
    /// only one the app has that belongs to no window. Signing in opens the tool's
    /// page in a browser; `PhoneBridge` polls for a while afterwards, and the row
    /// takes itself away once the mesh answers.
    private var meshAlert: some View {
        Button { bridge.connectMesh() } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Phone access is down")
                        .font(Theme.ui(11.5, .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                    Text(bridge.mesh.needsLogin
                         ? "\(bridge.mesh.tool?.name ?? "The private network") needs you to sign in again."
                         : "\(bridge.mesh.tool?.name ?? "The private network") is not connected.")
                        .font(Theme.ui(10))
                        .foregroundStyle(Color.white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("Sign in")
                    .font(Theme.ui(10, .medium))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.warning.opacity(0.16)))
            }
            .padding(.horizontal, 14)
            .frame(height: Island.alertHeight)
            .background(Color.white.opacity(alertHovering ? 0.07 : 0.03))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { alertHovering = $0 }
    }
}

private struct IslandRow: View {
    let live: SessionStates.Live
    let open: () -> Void
    let answer: (Int) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            summary
            if !live.options.isEmpty { options }
        }
        // A question is the only row you can act on without going anywhere, so it
        // is the only one that is lit.
        .background(live.attention.isQuestion ? Theme.waiting.opacity(0.07) : .clear)
    }

    private var summary: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                StatusDot(color: live.attention.color, size: 6)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(live.project)
                            .font(Theme.ui(11))
                            .foregroundStyle(Color.white.opacity(0.45))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.25))
                        Text(live.name)
                            .font(Theme.ui(12, .medium))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineLimit(1)
                        // A question does not go away by being looked at, so it is
                        // worth saying which of the two orange rows this is.
                        if live.attention.isQuestion {
                            Text("asking")
                                .font(Theme.ui(9))
                                .foregroundStyle(Theme.waiting)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Theme.waiting.opacity(0.16)))
                        }
                    }
                    // Two lines: what the session is saying is the reason the row
                    // exists, and one truncated line was a hint rather than a
                    // message. While it is working this is Claude's own status
                    // line, which moves every second.
                    Text(live.headline ?? live.attention.label)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Color.white.opacity(live.attention == .working ? 0.55 : 0.42))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .frame(height: Island.rowHeight, alignment: .center)
            .background(hovering ? Color.white.opacity(0.07) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// The prompt, answerable where it is.
    ///
    /// The alternative is what this replaces: notice the dot, find the window,
    /// find the tab, read a wall of TUI, press a digit. The keystroke goes
    /// through tmux, so the project does not even have to be open.
    private var options: some View {
        VStack(spacing: 2) {
            ForEach(Array(live.options.prefix(Island.maxOptions).enumerated()), id: \.offset) {
                index, label in
                IslandOption(number: index + 1, label: label) { answer(index) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

private struct IslandOption: View {
    let number: Int
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.waiting)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Theme.waiting.opacity(0.18)))
                Text(label)
                    .font(Theme.ui(11))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: Island.optionHeight - 2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.12 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
