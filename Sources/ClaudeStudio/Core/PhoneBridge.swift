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
                    if let value, !value.isEmpty { status.address = String(value) }
                } else if line.hasPrefix("FQDN:") {
                    let value = line.dropFirst("FQDN:".count).trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { status.fqdn = value }
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
            if let ip, !ip.isEmpty, ip.first?.isNumber == true {
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

    /// Live output of an install in progress, and whether one is running.
    @Published private(set) var installing = false
    @Published private(set) var installLog = ""

    /// node / ttyd / tmux. Cached rather than asked for on demand: each answer is a
    /// process spawn, and a view that reads this redraws far more often than the
    /// machine grows a new binary.
    @Published private(set) var requirements: [PhoneInstaller.Requirement] = []
    var missingRequirements: [PhoneInstaller.Requirement] { requirements.filter { !$0.isPresent } }

    private var plist: URL { Paths.launchAgentsDir.appendingPathComponent("\(Self.label).plist") }

    private init() { refresh() }

    // MARK: - Status

    func refresh() {
        isInstalled = PhoneInstaller.isInstalled
        isEnabled = isInstalled && jobIsLoaded
        isRunning = Shell.portIsListening(Self.port)
        mesh = MeshStatus.detect()
        address = mesh.address
        token = try? String(contentsOf: Paths.bridgeToken, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        Task.detached(priority: .userInitiated) {
            let mesh = MeshStatus.detect()
            let listening = Shell.portIsListening(Self.port)
            let message = Self.describe(mesh: mesh, listening: listening)
            let found = await MainActor.run { PhoneInstaller.requirements() }
            await MainActor.run {
                self.refresh()
                self.requirements = found
                self.checkState = .done(message)
            }
        }
    }

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
    func restart() {
        guard isInstalled else { return }
        Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Self.label)"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
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
        guard isInstalled else { return }
        let uid = getuid()
        if enabled {
            Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist.path])
        } else {
            Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(Self.label)"])
        }
        // launchd takes a moment to bring the listener up or tear it down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
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

        // The running service read the old token at startup, so it has to be
        // restarted before the new QR code means anything.
        Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(Self.label)"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.refresh() }
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
