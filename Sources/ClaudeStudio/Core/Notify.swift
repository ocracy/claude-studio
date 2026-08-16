import Foundation
import AppKit

/// Bildirim + ses. Sade tutuldu: iş bitince tek bir yumuşak ton ve tek satırlık
/// banner — dikkat çeker, rahatsız etmez.
///
/// `UNUserNotificationCenter` ad-hoc imzalı bir uygulamada güvenilir değildir
/// (provizyonlu bundle ve izin ister); `osascript display notification` hiçbir
/// entitlement gerektirmez.
enum Notify {

    /// Kullanılan tek ses. Sistemde yoksa NSSound sessizce yutar.
    static let doneSound = "Glass"
    static let alertSound = "Basso"

    static func post(title: String, subtitle: String = "", body: String, sound: String? = doneSound) {
        var script = "display notification \(quote(body)) with title \(quote(title))"
        if !subtitle.isEmpty { script += " subtitle \(quote(subtitle))" }
        if let sound { script += " sound name \(quote(sound))" }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        // Fire-and-forget: osascript bu nesneden uzun yaşar.
        try? p.run()
    }

    /// Geçici NSSound çalmadan serbest bırakılırsa ses hiç çıkmaz — referansı tut.
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
