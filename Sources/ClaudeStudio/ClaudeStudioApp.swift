import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenuBuilder.install()

        // Ağır kurulumlar arka planda: hook köprüsü, tmux config, PATH anlık
        // görüntüsü. Pencere bunları beklemez.
        Task.detached(priority: .utility) {
            HookBridge.installIfNeeded()
            Tmux.ensureConfig()
            _ = Shell.userPath
        }

        // Yeni sürüm var mı? Sessizce bakılır; varsa üst barda rozet çıkar.
        Updater.shared.check(silent: true)

        // Klasörle açıldıysa `openFiles` zaten pencereyi açtı.
        if WindowManager.shared.isEmpty {
            WindowManager.shared.openWelcome()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Finder'dan sürüklenen ya da `open -a "Claude Studio" <klasör>` ile gelen
    /// klasörler. Yalnız klasörler kabul edilir.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var opened = false
        for path in filenames {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            WindowManager.shared.open(project: Project(path: path))
            opened = true
        }
        sender.reply(toOpenOrPrint: opened ? .success : .failure)
    }

    /// Dock'tan tıklandığında açık pencere yoksa karşılama ekranını getir.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.openWelcome() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

// MARK: - Komut kanalı

/// Menüden etkin pencereye giden komutlar; `WindowManager.perform` uygular.
enum StudioCommand {
    case openFolder, newSession, newTerminal, newTab, closeTab, nextTab, previousTab
}

// MARK: - Menü

/// Ana menü. AppKit tarafında elle kurulur; Edit menüsü terminaldeki kopyala /
/// yapıştır kısayollarının çalışması için şart.
@MainActor
enum MainMenuBuilder {

    static func install() {
        let main = NSMenu()

        // Uygulama
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Claude Studio Hakkında",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(action(title: "Güncellemeleri Denetle…", key: "", modifiers: []) {
            Updater.shared.check()
            SettingsWindow.show()
        })
        appMenu.addItem(.separator())
        appMenu.addItem(action(title: "Ayarlar…", key: ",", modifiers: .command) {
            SettingsWindow.show()
        })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Gizle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Dosya
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Dosya")
        fileMenu.addItem(action(title: "Yeni Pencere", key: "n", modifiers: [.command, .shift]) {
            WindowManager.shared.openWelcome()
        })
        fileMenu.addItem(action(title: "Klasör Aç…", key: "o", modifiers: .command) {
            WindowManager.shared.perform(.openFolder)
        })
        fileMenu.addItem(.separator())
        fileMenu.addItem(action(title: "Yeni Claude Oturumu", key: "n", modifiers: .command) {
            WindowManager.shared.perform(.newSession)
        })
        fileMenu.addItem(action(title: "Yeni Sekme", key: "t", modifiers: .command) {
            WindowManager.shared.perform(.newTab)
        })
        fileMenu.addItem(action(title: "Yeni Terminal", key: "t", modifiers: [.command, .shift]) {
            WindowManager.shared.perform(.newTerminal)
        })
        fileMenu.addItem(.separator())
        fileMenu.addItem(action(title: "Sekmeyi Kapat", key: "w", modifiers: .command) {
            WindowManager.shared.perform(.closeTab)
        })
        fileMenu.addItem(withTitle: "Pencereyi Kapat",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Düzen — terminalde ⌘C / ⌘V bu menüden gelir.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Düzen")
        editMenu.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // Görünüm
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Görünüm")
        viewMenu.addItem(action(title: "Sonraki Sekme", key: "]", modifiers: [.command, .shift]) {
            WindowManager.shared.perform(.nextTab)
        })
        viewMenu.addItem(action(title: "Önceki Sekme", key: "[", modifiers: [.command, .shift]) {
            WindowManager.shared.perform(.previousTab)
        })
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Pencere
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Pencere")
        windowMenu.addItem(withTitle: "Simge Durumuna Küçült",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Tümünü Öne Getir",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Blok çalıştıran menü öğesi — hedef/aksiyon zincirine ihtiyaç duymaz.
    private static func action(title: String, key: String, modifiers: NSEvent.ModifierFlags,
                               handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(BlockTarget.fire), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        let target = BlockTarget(handler)
        item.target = target
        item.representedObject = target   // güçlü referans: hedef menüyle yaşar
        return item
    }
}

/// Menü öğesinin hedefi; bloğu canlı tutar.
final class BlockTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
