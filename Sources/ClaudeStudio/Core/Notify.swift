import Foundation
import AppKit

/// Notifications and sound. Deliberately restrained: one soft tone and a
/// single-line banner when work finishes — noticeable, not annoying.
///
/// `UNUserNotificationCenter` is unreliable in an ad-hoc signed app (it wants a
/// provisioned bundle and permission); `osascript display notification` needs no
/// entitlement at all.
enum Notify {

    /// The sound to play. If missing, NSSound fails silently.
    static let doneSound = "Glass"
    static let alertSound = "Basso"

    static func post(title: String, subtitle: String = "", body: String, sound: String? = doneSound) {
        var script = "display notification \(quote(body)) with title \(quote(title))"
        if !subtitle.isEmpty { script += " subtitle \(quote(subtitle))" }
        if let sound { script += " sound name \(quote(sound))" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        // Fire-and-forget: osascript outlives this Process object.
        try? p.run()
    }

    /// A temporary NSSound is deallocated before it finishes playing and never
    /// makes a sound — keep a strong reference.
    private static var activeSound: NSSound?

    static func play(_ name: String = doneSound) {
        let sound = NSSound(named: NSSound.Name(name)) ?? NSSound(named: NSSound.Name("Glass"))
        activeSound = sound
        sound?.stop()
        sound?.play()
    }

    @MainActor
    static func badge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    private static func quote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
