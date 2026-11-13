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
    @AppStorage("notify.finishedAfterMinutes") var notifyFinishedAfterMinutes = -1
    /// Show the number of waiting sessions on the Dock icon.
    @AppStorage("notify.badge")        var badgeEnabled = true
    /// Terminal font size.
    @AppStorage("terminal.fontSize")   var terminalFontSize = 12.5
    @AppStorage("terminal.fontFamily") var terminalFontFamily = ""
    @AppStorage("terminal.lineSpacing") var terminalLineSpacing = 1.0
    @AppStorage("terminal.cursor")     var terminalCursor = TerminalCursor.block.rawValue
    @AppStorage("terminal.cursorBlink") var terminalCursorBlink = true
    @AppStorage("terminal.boldBright") var terminalBoldBright = true
    @AppStorage("terminal.gpu")        var terminalGPU = false

    enum TerminalCursor: String, CaseIterable, Identifiable {
        case block, bar, underline
        var id: String { rawValue }
        var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }

    static let terminalAppearanceChanged = Notification.Name("terminalAppearanceChanged")

    static let monospacedFamilies: [String] = NSFontManager.shared.availableFontFamilies.filter { family in
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
        return font.isFixedPitch
            || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
    }.sorted()

    var terminalFont: NSFont {
        let size = CGFloat(terminalFontSize)
        if !terminalFontFamily.isEmpty,
           let font = NSFontManager.shared.font(withFamily: terminalFontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func terminalAppearanceDidChange() {
        NotificationCenter.default.post(name: Self.terminalAppearanceChanged, object: nil)
    }
    /// Reattach to the most recent session when a project opens.
    @AppStorage("session.autoAttach")  var autoAttachLastSession = true
    /// The island at the top of the screen: every project's sessions in one place,
    /// above whatever you are working in.
    @AppStorage("island.enabled")      var islandEnabled = true
    /// Which rows the island lists: `all`, `attention` (orange) or `working`
    /// (green). Remembered, because it is a way of working rather than a glance.
    @AppStorage("island.filter")       var islandFilter = "all"
    /// Rename a session nobody named after Claude's own title for the conversation.
    @AppStorage("session.autoTitle")   var autoTitleSessions = true
    /// Order of the activity rail, as comma-separated pane names. Empty means the
    /// built-in order; unknown or missing names are ignored, so the list survives
    /// a release that adds or removes a section.
    @AppStorage("rail.order")          var railOrder = ""

    /// Selectable system sounds — all ship with macOS.
    static let finishedAfterChoices = [-1, 0, 2, 5, 10, 15]

    static let sounds = ["Glass", "Ping", "Pop", "Submarine", "Blow", "Bottle",
                         "Frog", "Funk", "Hero", "Morse", "Purr", "Sosumi", "Tink"]

    private init() {}

    /// Waiting-session announcement — one soft tone, optional banner.
    ///
    /// The body says WHICH of the two it is. "Claude is waiting for you" was said
    /// for a finished report and for a permission prompt alike, which is the same
    /// flattening the orange dot used to do: the banner that actually needs you
    /// read exactly like the twelve that did not.
    func announceWaiting(session: String, project: String,
                         question: String? = nil, summary: String? = nil) {
        if soundEnabled { Notify.play(soundName) }
        if notifyEnabled {
            Notify.post(title: project, subtitle: session,
                        body: question?.nilIfEmpty ?? summary?.nilIfEmpty
                            ?? "Finished — nothing to answer.",
                        sound: nil)
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
