import SwiftUI
import AppKit

/// Uygulamanın pencereleri. Her pencere ya karşılama ekranıdır ya da tek bir
/// projenin stüdyosu. Aynı proje ikinci kez açılmaz — var olan pencere öne gelir.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var controllers: [StudioWindow] = []

    var isEmpty: Bool { controllers.isEmpty }

    @discardableResult
    func openWelcome() -> StudioWindow {
        // Zaten boş bir pencere varsa onu kullan — boş pencere yığmayalım.
        if let idle = controllers.first(where: { $0.project == nil }) {
            idle.window.makeKeyAndOrderFront(nil)
            return idle
        }
        let window = StudioWindow(project: nil)
        controllers.append(window)
        window.window.makeKeyAndOrderFront(nil)
        return window
    }

    func open(project: Project) {
        if let existing = controllers.first(where: { $0.project?.path == project.path }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        // Boş bir pencere varsa projeyi orada aç (Visual Studio davranışı).
        if let idle = controllers.first(where: { $0.project == nil }) {
            idle.load(project: project)
            idle.window.makeKeyAndOrderFront(nil)
            return
        }
        let window = StudioWindow(project: project)
        controllers.append(window)
        window.window.makeKeyAndOrderFront(nil)
    }

    func forget(_ controller: StudioWindow) {
        controllers.removeAll { $0 === controller }
    }

    /// Menü komutunu etkin pencerenin modeline uygular.
    func perform(_ command: StudioCommand) {
        switch command {
        case .openFolder:
            if let project = Recents.chooseFolder() { open(project: project) }
            return
        default:
            break
        }
        guard let model = keyModel else { return }
        switch command {
        case .newSession:   model.newSession()
        case .newTab:       model.newTabForContext()
        case .newTerminal:  model.newTerminal()
        case .closeTab:     if let id = model.activeTabID { model.closeTab(id: id) }
        case .nextTab:      model.selectNextTab(1)
        case .previousTab:  model.selectNextTab(-1)
        case .openFolder:   break
        }
    }

    private var keyModel: StudioModel? {
        controllers.first(where: \.isKey)?.activeModel ?? controllers.first?.activeModel
    }
}

/// Tek bir pencere ve içindeki SwiftUI ağacı.
@MainActor
final class StudioWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private(set) var project: Project?
    private var model: StudioModel?

    init(project: Project?) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 620)
        window.backgroundColor = .windowBackgroundColor
        super.init()
        window.delegate = self
        window.center()
        render()
        if let project { load(project: project) }
    }

    /// Projeyi bu pencerede açar (ya da karşılama ekranına döner).
    func load(project: Project?) {
        model?.stop()
        self.project = project
        if let project {
            let fresh = StudioModel(project: project)
            fresh.start()
            model = fresh
            Recents.shared.remember(project)
            window.title = "\(project.name) — Claude Studio"
        } else {
            model = nil
            window.title = "Claude Studio"
        }
        render()
    }

    private func render() {
        let root = RootView(model: model,
                            onOpen: { [weak self] project in self?.load(project: project) },
                            onClose: { [weak self] in self?.load(project: nil) })
        window.contentView = NSHostingView(rootView: root)
    }

    func windowWillClose(_ notification: Notification) {
        model?.stop()
        model = nil
        WindowManager.shared.forget(self)
    }

    /// Menü komutları yalnız anahtar pencereye uygulanır.
    var isKey: Bool { window.isKeyWindow }
    var activeModel: StudioModel? { model }
}
