import SwiftUI
import AppKit
import SwiftTerm

/// Hosts the engine-owned persistent terminal view inside SwiftUI.
///
/// The container is created ONCE; switching tabs swaps the terminal inside it.
/// Recreating the representable would reset the scroll position and the buffer —
/// this swap model is why switching tabs costs nothing.
struct TerminalHost: NSViewRepresentable {
    let key: String
    let engine: TerminalEngine

    func makeNSView(context: Context) -> TerminalContainer {
        let container = TerminalContainer()
        container.autoresizingMask = [.width, .height]
        container.attach(engine.view(for: key))
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        container.attach(engine.view(for: key))
    }
}

/// Hosts exactly one terminal at a time. `attach` is idempotent, so SwiftUI's
/// frequent update calls never churn the view tree.
final class TerminalContainer: NSView {
    private weak var current: LocalProcessTerminalView?
    /// Debounce so SwiftTerm's expensive resize path does not run on every mouse
    /// move while the window is dragged.
    private var resizeDebounce: DispatchWorkItem?
    /// A deferred spawn waits for the geometry to STOP changing, not merely to be
    /// non-zero: the container is briefly full-window wide before the sidebar is
    /// laid out, and a terminal started at that width draws at the wrong column
    /// count until something resizes it.
    private var startDebounce: DispatchWorkItem?

    func attach(_ terminal: LocalProcessTerminalView) {
        if current === terminal { return }
        // The same NSView cannot live in two hierarchies — detach both.
        current?.removeFromSuperview()
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        current = terminal

        // Double refresh: at t=0 size, focus and first draw; at t=350 ms a second
        // draw once Cocoa's layout pass has settled. This deterministically fixes a
        // stale canvas after the swap.
        DispatchQueue.main.async { [weak terminal, weak self] in
            guard let view = terminal, let self, let window = view.window else { return }
            if bounds.width > 0 && bounds.height > 0 { view.setFrameSize(self.bounds.size) }
            window.makeFirstResponder(view)
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
            self.armPendingStart()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak terminal] in
            guard let view = terminal, view.window != nil else { return }
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
        }
    }

    /// Re-arms the deferred spawn; every size change pushes it further out, so it
    /// fires once the layout has been quiet for a moment.
    private func armPendingStart() {
        guard (current as? StudioTerminalView)?.hasPendingStart == true else { return }
        startDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            (self?.current as? StudioTerminalView)?.runPendingStart()
        }
        startDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let terminal = current, newSize.width > 0, newSize.height > 0 else { return }
        terminal.setFrameSize(newSize)
        armPendingStart()

        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak terminal] in
            guard let view = terminal, view.window != nil else { return }
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
        }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
