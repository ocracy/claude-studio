import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenuBuilder.install()
        HeaderDoubleClick.install()
        // One consumer for the whole app: windows would race over the same spool.
        UsageMonitor.shared.start()

        // Heavy setup happens in the background: hook bridge, tmux config, PATH
        // snapshot. The window never waits for them.
        Task.detached(priority: .utility) {
            HookBridge.installIfNeeded()
            Tmux.ensureConfig()
            _ = Shell.userPath
            await MainActor.run { ProjectBridge.install() }
        }

        // Is a new version out? Checked silently; a badge appears in the top bar.
        Updater.shared.check(silent: true)

        // If launched with a folder, `openFiles` already opened the window.
        if WindowManager.shared.isEmpty {
            WindowManager.shared.openWelcome()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Folders dropped from Finder or passed via `open -a "Claude Studio" <dir>`.
    /// Only directories are accepted.
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

    /// Clicking the Dock icon with no open window brings back the welcome screen.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.openWelcome() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

// MARK: - Command channel

/// Commands routed from the menu to the key window; applied by `WindowManager.perform`.
enum StudioCommand {
    case openFolder, newSession, newTerminal, newTab, closeTab, nextTab, previousTab, palette
    case selectTab(Int)
}

// MARK: - Menu

/// Main menu, built by hand in AppKit. The Edit menu is required for copy and
/// paste shortcuts to work inside the terminal.
@MainActor
enum MainMenuBuilder {

    static func install() {
        let main = NSMenu()

        // Application
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Claude Studio",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(action(title: "Check for Updates…", key: "", modifiers: []) {
            Updater.shared.check()
            SettingsWindow.show()
        })
        appMenu.addItem(.separator())
        appMenu.addItem(action(title: "Settings…", key: ",", modifiers: .command) {
            SettingsWindow.show()
        })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // File
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(action(title: "New Window", key: "n", modifiers: [.command, .shift]) {
            WindowManager.shared.openWelcome()
        })
        fileMenu.addItem(action(title: "Open Folder…", key: "o", modifiers: .command) {
            WindowManager.shared.perform(.openFolder)
        })
        fileMenu.addItem(.separator())
        fileMenu.addItem(action(title: "New Claude Session", key: "n", modifiers: .command) {
            WindowManager.shared.perform(.newSession)
        })
        fileMenu.addItem(action(title: "New Tab", key: "t", modifiers: .command) {
            WindowManager.shared.perform(.newTab)
        })
        fileMenu.addItem(action(title: "New Terminal", key: "t", modifiers: [.command, .shift]) {
            WindowManager.shared.perform(.newTerminal)
        })
        fileMenu.addItem(.separator())
        fileMenu.addItem(action(title: "Close Tab", key: "w", modifiers: .command) {
            WindowManager.shared.perform(.closeTab)
        })
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // Edit — ⌘C / ⌘V in the terminal come from this menu.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // View
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(action(title: "Command Palette…", key: "p", modifiers: .command) {
            WindowManager.shared.perform(.palette)
        })
        viewMenu.addItem(.separator())
        viewMenu.addItem(action(title: "Next Tab", key: "]", modifiers: [.command, .shift]) {
            WindowManager.shared.perform(.nextTab)
        })
        viewMenu.addItem(action(title: "Previous Tab", key: "[", modifiers: [.command, .shift]) {
            WindowManager.shared.perform(.previousTab)
        })
        viewMenu.addItem(.separator())
        // ⌘1…⌘9 jump straight to a tab, like a browser.
        for index in 1...9 {
            viewMenu.addItem(action(title: "Tab \(index)", key: "\(index)", modifiers: .command) {
                WindowManager.shared.perform(.selectTab(index - 1))
            })
        }
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Window
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// A menu item that runs a closure — no target/action plumbing required.
    private static func action(title: String, key: String, modifiers: NSEvent.ModifierFlags,
                               handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(BlockTarget.fire), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        let target = BlockTarget(handler)
        item.target = target
        item.representedObject = target   // strong reference: the target lives with the menu
        return item
    }
}

/// Target of a menu item; keeps the closure alive.
final class BlockTarget: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
