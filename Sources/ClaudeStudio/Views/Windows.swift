import SwiftUI
import AppKit

/// The app's windows. Each is either the welcome screen or the studio for one
/// project. A project never opens twice — the existing window comes forward.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var controllers: [StudioWindow] = []

    var isEmpty: Bool { controllers.isEmpty }

    @discardableResult
    func openWelcome() -> StudioWindow {
        // Reuse an idle window if there is one — do not pile up empty windows.
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
        // If a window is idle, open the project there (Visual Studio behaviour).
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

    /// Applies a menu command to the key window's model.
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
        case .closeTab:
            // No tabs left to close → close the window, as any editor would.
            if let id = model.activeTabID { model.closeTab(id: id) }
            else { controllers.first(where: \.isKey)?.window.performClose(nil) }
        case let .selectTab(index): model.selectTab(index)
        case .palette:      model.paletteOpen.toggle()
        case .nextTab:      model.selectNextTab(1)
        case .previousTab:  model.selectNextTab(-1)
        case .openFolder:   break
        }
    }

    private var keyModel: StudioModel? {
        controllers.first(where: \.isKey)?.activeModel ?? controllers.first?.activeModel
    }
}

/// One window and the SwiftUI tree inside it.
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

    /// Opens the project in this window (or returns to the welcome screen).
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

    /// Menu commands apply to the key window only.
    var isKey: Bool { window.isKeyWindow }
    var activeModel: StudioModel? { model }
}

/// Whether the pointer is over an interactive control in the header.
///
/// SwiftUI knows this exactly; AppKit hit-testing does not, because everything in a
/// SwiftUI hierarchy answers as the same hosting view. The header's controls report
/// their hover state here, and `HeaderDoubleClick` uses it to leave their clicks
/// alone.
@MainActor
final class HeaderHover: ObservableObject {
    static let shared = HeaderHover()
    private(set) var overControl = false

    func set(_ inside: Bool) { overControl = inside }
}

extension View {
    /// Marks a header control, so a double-click on it is not taken as "zoom".
    func headerControl() -> some View {
        onHover { HeaderHover.shared.set($0) }
    }
}

/// Restores the native "double-click the title bar to zoom" behaviour.
///
/// The window uses `fullSizeContentView` with a transparent title bar, so the top
/// ~28 px belong to AppKit's title bar and never reach our SwiftUI header — which
/// is why a double-click up there did nothing. The event is intercepted before the
/// window sees it, and consumed, so the system setting for title-bar double-clicks
/// cannot double-toggle the zoom either.
@MainActor
enum HeaderDoubleClick {
    /// Height of the header strip, and the traffic-light zone to leave alone.
    private static let headerHeight: CGFloat = 42
    private static let trafficLightWidth: CGFloat = 92

    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                guard event.clickCount == 2,
                      let window = event.window,
                      window.delegate is StudioWindow,
                      window.isZoomable
                else { return event }

                let point = event.locationInWindow
                guard point.y > window.frame.height - headerHeight,
                      point.x > trafficLightWidth,
                      !HeaderHover.shared.overControl   // a control keeps its own click
                else { return event }

                window.zoom(nil)
                return nil
            }
        }
    }
}
