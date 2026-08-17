import Foundation
import SwiftUI
import AppKit

/// Application preferences (machine-wide, `UserDefaults`).
///
/// Project settings live in `.cs/`; this is only the user's own preferences:
/// sound, notifications, terminal font.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Play a sound when Claude finishes and hands the turn back.
    @AppStorage("sound.enabled")       var soundEnabled = true
    /// Which system sound to play.
    @AppStorage("sound.name")          var soundName = "Glass"
    /// Play a sound when a scheduled or background run finishes.
    @AppStorage("sound.onRunFinish")   var soundOnRunFinish = true
    /// Show a notification banner.
    @AppStorage("notify.enabled")      var notifyEnabled = true
    /// Show the number of waiting sessions on the Dock icon.
    @AppStorage("notify.badge")        var badgeEnabled = true
    /// Terminal font size.
    @AppStorage("terminal.fontSize")   var terminalFontSize = 12.5
    /// Reattach to the most recent session when a project opens.
    @AppStorage("session.autoAttach")  var autoAttachLastSession = true
    /// Order of the activity rail, as comma-separated pane names. Empty means the
    /// built-in order; unknown or missing names are ignored, so the list survives
    /// a release that adds or removes a section.
    @AppStorage("rail.order")          var railOrder = ""

    /// Selectable system sounds — all ship with macOS.
    static let sounds = ["Glass", "Ping", "Pop", "Submarine", "Blow", "Bottle",
                         "Frog", "Funk", "Hero", "Morse", "Purr", "Sosumi", "Tink"]

    private init() {}

    /// Waiting-session announcement — one soft tone, optional banner.
    func announceWaiting(session: String, project: String) {
        if soundEnabled { Notify.play(soundName) }
        if notifyEnabled {
            Notify.post(title: project, subtitle: session,
                        body: "Claude is waiting for you.", sound: nil)
        }
    }

    /// A run (skill or background command) finished.
    func announceFinished(title: String, detail: String, ok: Bool) {
        if soundOnRunFinish { Notify.play(ok ? soundName : "Basso") }
        if notifyEnabled {
            Notify.post(title: title, body: detail, sound: nil)
        }
    }
}
