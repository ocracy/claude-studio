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

    var isConnected: Bool { address != nil }
    var isInstalled: Bool { tool != nil }

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
            for line in result.output.split(separator: "\n") where line.contains("NetBird IP:") {
                let value = line.split(separator: ":").last?
                    .trimmingCharacters(in: .whitespaces)
                    .split(separator: "/").first
                if let value, !value.isEmpty { status.address = String(value) }
            }
            // A Netbird that is installed but signed out should not hide a
            // Tailscale that is up; only claim the slot if it has something.
            if status.isConnected || binary(for: .tailscale) == nil { return status }
        }

        if let tailscale = binary(for: .tailscale) {
            var status = MeshStatus(tool: .tailscale)
            let ip = Shell.run(tailscale, ["ip", "-4"]).output
                .split(separator: "\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let ip, !ip.isEmpty, ip.first?.isNumber == true {
                status.address = ip
            } else {
                status.needsLogin = true
            }
            return status
        }

        return .absent
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

    static let port = 7788
    private static let label = "com.claudestudio.bridge"

    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false
    @Published private(set) var address: String?
    @Published private(set) var token: String?
    /// The private network the bridge binds to, and whether it is up.
    @Published private(set) var mesh = MeshStatus.absent

    private var plist: URL { Paths.launchAgentsDir.appendingPathComponent("\(Self.label).plist") }

    private init() { refresh() }

    // MARK: - Status

    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: plist.path)
        isEnabled = isInstalled && jobIsLoaded
        isRunning = Shell.portIsListening(Self.port)
        mesh = MeshStatus.detect()
        address = mesh.address
        token = try? String(contentsOf: Paths.bridgeToken, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    var connectURL: String? {
        guard let address, let token, !token.isEmpty else { return nil }
        return "http://\(address):\(Self.port)/setup?k=\(token)"
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

    /// Replace the token and restart the service — how you cut off a lost phone.
    func rotateToken() {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let value = bytes.map { String(format: "%02x", $0) }.joined()

        Paths.writeAtomically(Data(value.utf8), to: Paths.bridgeToken)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.bridgeToken.path)

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
