import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The private network the phone and this Mac share.
///
/// The bridge binds to this address and to nothing else routable — that is the
/// whole security model, so "is the mesh up" is a first-class piece of status
/// rather than a detail of the bridge. Netbird and Tailscale are interchangeable
/// here: both hand this Mac a stable private address and both put the phone on
/// the same network. Netbird is preferred only because it is checked first.
struct MeshStatus: Equatable, Sendable {
    enum Tool: String, Sendable {
        case netbird, tailscale
        var name: String { self == .netbird ? "Netbird" : "Tailscale" }
        var site: String {
            self == .netbird ? "https://netbird.io" : "https://tailscale.com"
        }
    }

    /// The tool found on this Mac, if any.
    var tool: Tool?
    /// It is installed but nobody is signed in.
    var needsLogin = false
    /// The private address it handed this Mac.
    var address: String?
    /// The private NAME it handed this Mac — `mac.netbird.cloud`, `mac.tail1234.ts.net`.
    ///
    /// This is what the phone is pointed at. An installed web app is bound to its
    /// origin, and a mesh address can change: when it does, the app on the Home
    /// Screen stops working and there is no address bar to correct it from. The
    /// name survives that, and it is also what makes two Macs two distinct apps
    /// rather than two icons that fight over the same origin.
    var fqdn: String?
    /// Whatever the tool said when it was asked — quoted back when something is
    /// wrong, because "check" that reports nothing is indistinguishable from a
    /// button that does nothing.
    var detail: String?

    var isConnected: Bool { address != nil }
    var isInstalled: Bool { tool != nil }

    /// What the phone should open: the name when there is one, the address otherwise.
    var host: String? { fqdn?.nilIfEmpty ?? address }

    static let absent = MeshStatus()

    /// The command that brings it up. Both open a browser to sign in.
    var connectCommand: String? {
        guard let tool, let binary = MeshStatus.binary(for: tool) else { return nil }
        return "\(Shell.quoted(binary)) up"
    }

    private static func binary(for tool: Tool) -> String? {
        switch tool {
        case .netbird:
            return Shell.findExecutable(["/usr/local/bin/netbird", "/opt/homebrew/bin/netbird"])
                ?? Shell.which("netbird")
        case .tailscale:
            // The Mac App Store build ships its CLI inside the bundle and puts
            // nothing on PATH, which is why the app path is checked at all.
            return Shell.findExecutable([
                "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            ]) ?? Shell.which("tailscale")
        }
    }

    /// Four decimal octets and nothing else. The bridge binds to whatever comes back
    /// from here and a certificate is issued for it, so "non-empty" is not a test —
    /// it is what let the string "N" through, and a leaf that cannot be issued for
    /// it takes the whole service down. See `make-cert.sh`, which checks again.
    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && (UInt8(part) != nil)
        }
    }

    static func detect() -> MeshStatus {
        if let netbird = binary(for: .netbird) {
            let result = Shell.run(netbird, ["status"])
            var status = MeshStatus(tool: .netbird)
            status.needsLogin = result.output.contains("NeedsLogin")
                || result.output.contains("Disconnected")
            for line in result.output.split(separator: "\n") {
                if line.contains("NetBird IP:") {
                    let value = line.split(separator: ":").last?
                        .trimmingCharacters(in: .whitespaces)
                        .split(separator: "/").first
                    // Validated, not merely non-empty. Signed out, Netbird prints
                    // "NetBird IP: N/A", and cutting at the slash leaves "N" — which
                    // read as an address here and reported a dead mesh as connected.
                    if let value, MeshStatus.isIPv4(String(value)) {
                        status.address = String(value)
                    }
                } else if line.hasPrefix("FQDN:") {
                    let value = line.dropFirst("FQDN:".count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty, value != "N/A" { status.fqdn = value }
                }
            }
            status.detail = summary(of: result.output)
            // A Netbird that is installed but signed out should not hide a
            // Tailscale that is up; only claim the slot if it has something.
            if status.isConnected || binary(for: .tailscale) == nil { return status }
        }

        if let tailscale = binary(for: .tailscale) {
            var status = MeshStatus(tool: .tailscale)
            let result = Shell.run(tailscale, ["ip", "-4"])
            let ip = result.output.split(separator: "\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let ip, MeshStatus.isIPv4(ip) {
                status.address = ip
                // MagicDNS name, with the trailing dot the JSON carries.
                let json = Shell.run(tailscale, ["status", "--json"]).output
                if let range = json.range(of: "\"DNSName\"") {
                    let tail = json[range.upperBound...]
                    let parts = tail.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count > 1 {
                        let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                        if !name.isEmpty { status.fqdn = name }
                    }
                }
            } else {
                status.needsLogin = true
                status.detail = summary(of: result.output)
            }
            return status
        }

        return .absent
    }

    /// The first line worth quoting back to someone staring at a card that has not
    /// changed. Trimmed hard: this goes in a note, not a console.
    private static func summary(of output: String) -> String? {
        output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("OS:") && !$0.hasPrefix("Daemon") }
            .map { String($0.prefix(120)) }
    }
}

/// Status of `cs-bridge`, the companion service that lets a phone reach these
/// sessions.
///
/// The bridge is a separate launchd agent, not part of this process: sessions
/// stay reachable from the phone while the app is closed, and a bug in it
/// cannot take the app down. So everything here observes rather than hosts —
/// the port is probed, the address is read from Netbird, the job is started and
/// stopped through launchctl.
///
/// The phone never runs a model. It types into the `claude` processes already
/// running on this Mac, under this Mac's subscription.
@MainActor
final class PhoneBridge: ObservableObject {
    static let shared = PhoneBridge()

    nonisolated static let port = 7788
    private static let label = "com.claudestudio.bridge"

    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false
    @Published private(set) var address: String?
    @Published private(set) var token: String?
    /// The private network the bridge binds to, and whether it is up.
    @Published private(set) var mesh = MeshStatus.absent

    /// What the last "Check" found. A button that recomputes state silently is a
    /// button that looks broken exactly when nothing works — which is the only
    /// time anybody presses it.
    enum CheckState: Equatable {
        case idle
        case checking
        case done(String)
    }
    @Published private(set) var checkState = CheckState.idle

    /// What launchd is being asked to do right now, if anything — "Restarting…".
    ///
    /// These calls can take the better part of a minute (see `control`), so they
    /// need to say so. A button that has already been pressed and looks untouched is
    /// pressed again, and the second press queues another minute behind the first.
    @Published private(set) var busy: String?

    /// Live output of an install in progress, and whether one is running.
    @Published private(set) var installing = false
    @Published private(set) var installLog = ""

    /// node / ttyd / tmux. Cached rather than asked for on demand: each answer is a
    /// process spawn, and a view that reads this redraws far more often than the
    /// machine grows a new binary.
    @Published private(set) var requirements: [PhoneInstaller.Requirement] = []
    var missingRequirements: [PhoneInstaller.Requirement] { requirements.filter { !$0.isPresent } }

    private var plist: URL { Paths.launchAgentsDir.appendingPathComponent("\(Self.label).plist") }

    /// Deliberately empty. This used to `refresh()`, which was affordable while the
    /// first touch of `shared` was someone opening Settings; the watchdog moved that
    /// touch to app launch, and `refresh()` is three process spawns on the calling
    /// thread. The watchdog's first tick fills everything in off the main thread a
    /// moment later, and Settings refreshes on appear regardless.
    private init() {}

    // MARK: - Status

    /// Every assignment here is compared first.
    ///
    /// This used to write all five unconditionally, which was harmless while it only
    /// ran when someone opened Settings. The watchdog calls it once a minute forever,
    /// and an `@Published` write invalidates every view that reads it whether or not
    /// the value moved — the same bug `attention` and `serviceStatus` had.
    func refresh() {
        let installed = PhoneInstaller.isInstalled
        let loaded = jobIsLoaded
        Task.detached(priority: .userInitiated) {
            let reading = Self.measure(installed: installed, jobIsLoaded: loaded)
            await MainActor.run { self.apply(reading) }
        }
    }

    /// One reading of everything that can change underneath us.
    ///
    /// Split out of `refresh()` so the watchdog can take it off the main thread:
    /// `MeshStatus.detect()` and `portIsListening` are both process spawns, and this
    /// now runs once a minute for the life of the app. The two main-actor answers
    /// (`isInstalled`, `jobIsLoaded`) are passed in rather than asked for here — they
    /// are cheap, and taking them as arguments is what keeps this side isolation-free.
    nonisolated private static func measure(installed: Bool, jobIsLoaded: Bool) -> Reading {
        Reading(
            installed: installed,
            enabled: installed && jobIsLoaded,
            running: Shell.portIsListening(port),
            mesh: MeshStatus.detect(),
            token: try? String(contentsOf: Paths.bridgeToken, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct Reading: Sendable {
        var installed: Bool
        var enabled: Bool
        var running: Bool
        var mesh: MeshStatus
        var token: String?
    }

    private func apply(_ reading: Reading) {
        if isInstalled != reading.installed { isInstalled = reading.installed }
        if isEnabled != reading.enabled { isEnabled = reading.enabled }
        if isRunning != reading.running { isRunning = reading.running }
        if mesh != reading.mesh { mesh = reading.mesh }
        if address != reading.mesh.address { address = reading.mesh.address }
        if token != reading.token { token = reading.token }

        announce(reading)
    }

    /// Looks again — and says what it found.
    ///
    /// `refresh()` recomputes everything silently, which is right for a poll and
    /// wrong for a button: with the mesh signed out the card looked identical
    /// before and after the click, so the one action available when nothing works
    /// appeared to do nothing. The tool's own words go in the answer, because
    /// "still signed out" and "the daemon is not running" need different fixes.
    func check() {
        guard checkState != .checking else { return }
        checkState = .checking
        let loaded = jobIsLoaded
        let installed = PhoneInstaller.isInstalled
        Task.detached(priority: .userInitiated) {
            let reading = Self.measure(installed: installed, jobIsLoaded: loaded)
            let message = Self.describe(mesh: reading.mesh, listening: reading.running)
            let found = await MainActor.run { PhoneInstaller.requirements() }
            await MainActor.run {
                self.apply(reading)
                self.requirements = found
                self.checkState = .done(message)
            }
        }
    }

    // MARK: - Watchdog

    /// A drop has been announced and not yet taken back. This is the whole memory the
    /// announcer needs: it makes a repeat reading silent and a recovery meaningful,
    /// and without it the "back" banner would fire on every launch that happens to
    /// find the mesh healthy.
    private var announcedDown = false
    private var watchdog: Task<Void, Never>?

    /// Watches the private network for the life of the app.
    ///
    /// The mesh is the one thing phone access cannot survive without, and until now
    /// nothing looked at it unless Settings → Phone was open. A Netbird peer login
    /// expires after about a day; the tunnel went down, the phone stopped working,
    /// and nothing on this Mac said so — the failure was only discoverable by
    /// reaching for the phone and finding it dead, often days later.
    ///
    /// App-wide and started once, like `SessionStates` and `Island`: the mesh is a
    /// property of the machine, not of a window.
    func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                // Once a minute. `MeshStatus.detect()` is a process spawn and the
                // mesh is not something that changes by the second — the 1.5 s
                // rhythm the session poll runs at would be pure waste here.
                let (installed, loaded) = await MainActor.run {
                    (PhoneInstaller.isInstalled, self?.jobIsLoaded ?? false)
                }
                let reading = await Task.detached(priority: .utility) {
                    PhoneBridge.measure(installed: installed, jobIsLoaded: loaded)
                }.value
                guard let self else { return }
                await MainActor.run { self.apply(reading) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Says something only when the answer CHANGED.
    ///
    /// Announcing on the state rather than the transition would put a banner on
    /// screen every minute for as long as the tunnel stayed down — the same trap the
    /// phone's push notifications avoid by firing on `working` → `waiting`.
    ///
    /// The first reading is the deliberate exception. A session poll seeds silently
    /// because a first sighting says nothing about what came before; here the
    /// opposite holds — if the mesh is already down when the app opens, that is
    /// precisely the fact nobody has been told, so it is announced once and then
    /// falls quiet.
    private func announce(_ reading: Reading) {
        let connected = reading.mesh.isConnected

        // Silent for anyone who does not use phone access: with the bridge missing
        // or switched off, a mesh that is down costs them nothing.
        guard reading.installed, reading.enabled, AppSettings.shared.notifyEnabled else {
            announcedDown = false
            return
        }

        if !connected {
            guard !announcedDown else { return }
            announcedDown = true
            Notify.post(title: "Phone access is down",
                        body: Self.describe(mesh: reading.mesh, listening: reading.running),
                        sound: Notify.alertSound)
        } else if announcedDown {
            announcedDown = false
            // Quiet on the way back up: the problem is gone, and a sound for that is
            // a sound for something nobody has to act on.
            Notify.post(title: "Phone access is back",
                        body: "\(reading.mesh.tool?.name ?? "The private network") is up at "
                            + "\(reading.mesh.host ?? "—").",
                        sound: nil)
        }
    }

    /// The mesh is down while phone access is supposed to be working — the one state
    /// worth interrupting for. Read by the island.
    var isBroken: Bool { isInstalled && isEnabled && !mesh.isConnected }

    nonisolated private static func describe(mesh: MeshStatus, listening: Bool) -> String {
        guard let tool = mesh.tool else {
            return "Neither Netbird nor Tailscale is installed on this Mac."
        }
        if let host = mesh.host {
            let where_ = mesh.fqdn == nil
                ? host
                : "\(host) (\(mesh.address ?? "—"))"
            return listening
                ? "\(tool.name) is up at \(where_), and the bridge is listening."
                : "\(tool.name) is up at \(where_), but nothing is listening on port \(port) yet."
        }
        var message = "\(tool.name) is installed but not connected"
        message += mesh.needsLogin ? " — it needs you to sign in again." : "."
        if let detail = mesh.detail { message += " It reports: “\(detail)”." }
        return message
    }

    /// Installs everything phone access needs. See `PhoneInstaller`.
    func install() {
        guard !installing else { return }
        installing = true
        installLog = ""
        PhoneInstaller.install(log: { line in
            Task { @MainActor in
                self.installLog += (self.installLog.isEmpty ? "" : "\n") + line
            }
        }, completion: { _ in
            Task { @MainActor in
                self.installing = false
                self.refresh()
                self.check()
            }
        })
    }

    /// Brings the private network up.
    ///
    /// Both tools sign in through a browser, so this cannot report success — it
    /// opens the flow and the next refresh tells the truth. Run detached for the
    /// same reason: `netbird up` does not return until the login completes.
    func connectMesh() {
        guard let command = mesh.connectCommand else { return }
        Shell.runDetached(command)
        // The sign-in happens in a browser; poll for a while rather than once.
        for delay in [4.0, 10.0, 20.0, 35.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    /// Restarts the bridge agent. After the network comes up the agent may still
    /// be inside its 30-second throttle, and nobody wants to watch a spinner for
    /// half a minute to find out it would have worked.
    func restart() { control("Restarting…", ["kickstart", "-k", "gui/\(getuid())/\(Self.label)"]) }

    /// Every launchctl verb this class uses, off the main thread and with something
    /// on screen while it runs.
    ///
    /// `kickstart` does not return when the job has been signalled — it returns when
    /// the job has actually STARTED, and `ThrottleInterval` is 30 seconds. With the
    /// mesh down the runner exits immediately (there is no address to bind to), so
    /// launchd throttles, and a measured `kickstart -k` took **54 seconds**. Run on
    /// the calling thread, as this was, that is the whole app frozen — which is
    /// exactly what pressing Restart with a signed-out tunnel did. `bootout` blocks
    /// on the process dying for the same kind of reason.
    private func control(_ label: String, _ arguments: [String]) {
        guard isInstalled, busy == nil else { return }
        busy = label
        Task.detached(priority: .userInitiated) {
            Shell.run("/bin/launchctl", arguments)
            // launchd needs a moment to bring the listener up or tear it down.
            try? await Task.sleep(for: .seconds(1.5))
            let reading = await MainActor.run {
                (installed: PhoneInstaller.isInstalled, loaded: self.jobIsLoaded)
            }
            let measured = Self.measure(installed: reading.installed, jobIsLoaded: reading.loaded)
            await MainActor.run {
                self.busy = nil
                self.apply(measured)
            }
        }
    }

    /// The link the phone opens: address, port and token in one QR code.
    ///
    /// It points at the setup page over plain HTTP on purpose. Notifications and
    /// installing the page as an app require a secure context, and the phone
    /// cannot reach the HTTPS side until it has fetched and trusted the root
    /// certificate — which it can only download over HTTP. The setup page walks
    /// through that once and then hands over to HTTPS; a phone that has already
    /// done it is sent straight on.
    /// The mesh NAME is preferred over the address: an installed web app is bound to
    /// its origin, and the address is the part that changes.
    var connectURL: String? {
        guard let host = mesh.host, let token, !token.isEmpty else { return nil }
        return "http://\(host):\(Self.port)/setup?k=\(token)"
    }

    private var jobIsLoaded: Bool {
        Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.label)"]).status == 0
    }

    // MARK: - Control

    func setEnabled(_ enabled: Bool) {
        let uid = getuid()
        control(enabled ? "Starting…" : "Stopping…",
                enabled ? ["bootstrap", "gui/\(uid)", plist.path]
                        : ["bootout", "gui/\(uid)/\(Self.label)"])
    }

    /// The access token, generated on first use.
    ///
    /// One writer only: the app builds the QR code from this file and the bridge
    /// reads it at startup, so a second generator would eventually hand out a code
    /// for a token the service is not using.
    @discardableResult
    static func ensureToken() -> String? {
        if let existing = try? String(contentsOf: Paths.bridgeToken, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        return newToken()
    }

    private static func newToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else { return nil }
        let value = bytes.map { String(format: "%02x", $0) }.joined()
        Paths.writeAtomically(Data(value.utf8), to: Paths.bridgeToken)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.bridgeToken.path)
        return value
    }

    /// Replace the token and restart the service — how you cut off a lost phone.
    func rotateToken() {
        guard Self.newToken() != nil else { return }
        token = try? String(contentsOf: Paths.bridgeToken, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The running service read the old token at startup, so it has to be
        // restarted before the new QR code means anything.
        control("Replacing the link…", ["kickstart", "-k", "gui/\(getuid())/\(Self.label)"])
    }

    // MARK: - QR

    /// The connect link as a QR code, so the phone is set up by pointing a
    /// camera at it rather than by typing an address and a 64-character token.
    func qrImage(side: CGFloat) -> NSImage? {
        guard let connectURL else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(connectURL.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }
}
