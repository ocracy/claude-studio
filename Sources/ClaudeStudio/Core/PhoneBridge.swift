import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

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

    private var plist: URL { Paths.launchAgentsDir.appendingPathComponent("\(Self.label).plist") }

    private init() { refresh() }

    // MARK: - Status

    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: plist.path)
        isEnabled = isInstalled && jobIsLoaded
        isRunning = Shell.portIsListening(Self.port)
        address = netbirdAddress
        token = try? String(contentsOf: Paths.bridgeToken, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The link the phone opens: address, port and token in one QR code.
    var connectURL: String? {
        guard let address, let token, !token.isEmpty else { return nil }
        return "http://\(address):\(Self.port)/?k=\(token)"
    }

    /// Netbird assigns this Mac a stable private address; the bridge binds to it
    /// and to nothing else routable.
    private var netbirdAddress: String? {
        guard let binary = Shell.findExecutable(["/usr/local/bin/netbird",
                                                 "/opt/homebrew/bin/netbird"])
                ?? Shell.which("netbird") else { return nil }
        let result = Shell.run(binary, ["status"])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") where line.contains("NetBird IP:") {
            let value = line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
                .split(separator: "/").first
            if let value, !value.isEmpty { return String(value) }
        }
        return nil
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
