import Foundation
import SwiftUI

/// A link from this project to another local Claude project.
///
/// The link is what lets one project's session see another: its capabilities, its
/// running services and terminals, and — when `allowEdits` is on — its files through
/// Claude's own tools. Stored in `.cs/links.json`, so it travels with the project.
struct ProjectLink: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var name: String
    var path: String
    /// Off by default: a link starts read-only, and granting write access is a
    /// deliberate act. See `LinkAccess`, which turns this into
    /// `permissions.additionalDirectories` — files only, never the other project's
    /// skills.
    var allowEdits: Bool = false

    var url: URL { URL(fileURLWithPath: path) }

    var displayPath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var exists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    init(project: Project, allowEdits: Bool = false) {
        self.name = project.name
        self.path = project.path
        self.allowEdits = allowEdits
    }
}

/// Puts the bridge binary somewhere stable and registers it with Claude.
///
/// The helper ships inside the app bundle, but the bundle is deleted and rewritten on
/// every update and can be moved by the user — and an MCP config entry records an
/// absolute path. So the binary is copied into Application Support and *that* copy is
/// what Claude launches, exactly as the hook script and the launchd runners already do.
@MainActor
enum ProjectBridge {
    static let serverName = "claude-studio"
    private static let binaryName = "claude-studio-bridge"

    static var installedURL: URL {
        Paths.binDir.appendingPathComponent(binaryName)
    }

    /// Copies the helper out of the bundle when it is missing or stale.
    @discardableResult
    static func install() -> URL? {
        guard let source = bundledURL else { return nil }
        let destination = installedURL
        let stamp = Paths.binDir.appendingPathComponent("\(binaryName).version")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

        let installed = (try? String(contentsOf: stamp, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let exists = FileManager.default.isExecutableFile(atPath: destination.path)
        if exists, installed == version { return destination }

        Paths.ensure(Paths.binDir)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: destination.path)
            try version.write(to: stamp, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[ProjectBridge] could not install the helper: %@", "\(error)")
            return exists ? destination : nil
        }
        return destination
    }

    /// The helper inside the bundle, or — when running from a build directory during
    /// development — next to the executable.
    private static var bundledURL: URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(binaryName)"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(binaryName)"),
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("StudioBridge"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Registers the bridge for this project if it is not registered yet. One server
    /// per project serves every link, so linking again needs no new registration.
    static func register(project: Project, mcp: MCPStore, completion: ((Bool, String) -> Void)? = nil) {
        guard let binary = install() else {
            completion?(false, "The bridge helper is missing from the app bundle.")
            return
        }
        // Read the config rather than the store: a scan may not have finished yet,
        // and registering twice makes the CLI complain.
        let alreadyRegistered = MCPStore.read(project: project)
            .contains { $0.name == serverName }
        if alreadyRegistered {
            completion?(true, "")
            return
        }
        var server = MCPServer(name: serverName, scope: .local, transport: .stdio)
        server.command = binary.path
        server.args = ["--project", project.path]
        mcp.add(server) { ok, output in completion?(ok, output) }
    }
}
