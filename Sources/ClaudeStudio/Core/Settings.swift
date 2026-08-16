import Foundation
import SwiftUI
import AppKit

/// Uygulama tercihleri (makine geneli, `UserDefaults`).
///
/// Proje ayarları `.cs/config.json`'da durur; burası yalnız kullanıcının kendi
/// tercihleridir: ses, bildirim, terminal yazı tipi.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Claude işini bitirip sırayı sana verince ses çal.
    @AppStorage("sound.enabled")       var soundEnabled = true
    /// Çalınacak sistem sesi.
    @AppStorage("sound.name")          var soundName = "Glass"
    /// Zamanlanmış/arka plan çalışması bitince ses çal.
    @AppStorage("sound.onRunFinish")   var soundOnRunFinish = true
    /// Bildirim balonu göster.
    @AppStorage("notify.enabled")      var notifyEnabled = true
    /// Dock simgesinde bekleyen oturum sayısı.
    @AppStorage("notify.badge")        var badgeEnabled = true
    /// Terminal yazı tipi boyutu.
    @AppStorage("terminal.fontSize")   var terminalFontSize = 12.5
    /// Proje açılınca en son oturuma kendiliğinden bağlan.
    @AppStorage("session.autoAttach")  var autoAttachLastSession = true

    /// Seçilebilir sistem sesleri — hepsi macOS ile birlikte gelir.
    static let sounds = ["Glass", "Ping", "Pop", "Submarine", "Blow", "Bottle",
                         "Frog", "Funk", "Hero", "Morse", "Purr", "Sosumi", "Tink"]

    private init() {}

    /// Bekleyen oturum bildirimi — tek yumuşak ton, isteğe bağlı balon.
    func announceWaiting(session: String, project: String) {
        if soundEnabled { Notify.play(soundName) }
        if notifyEnabled {
            Notify.post(title: project, subtitle: session,
                        body: "Claude seni bekliyor.", sound: nil)
        }
    }

    /// Çalışma (skill / arka plan komutu) bitti.
    func announceFinished(title: String, detail: String, ok: Bool) {
        if soundOnRunFinish { Notify.play(ok ? soundName : "Basso") }
        if notifyEnabled {
            Notify.post(title: title, body: detail, sound: nil)
        }
    }
}
