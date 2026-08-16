import SwiftUI
import AppKit
import SwiftTerm

/// Motorun sahip olduğu kalıcı terminal görünümünü SwiftUI içinde barındırır.
///
/// Konteyner BİR KEZ kurulur; sekme değişince içindeki terminal takas edilir.
/// Representable'ı yeniden yaratmak kaydırma konumunu ve tamponu sıfırlardı —
/// sekme geçişinin bedelsiz olmasının sebebi bu takas modelidir.
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

/// Aynı anda tek terminal barındırır. `attach` idempotenttir — SwiftUI'nin sık
/// güncelleme çağrıları görünüm ağacını hırpalamaz.
final class TerminalContainer: NSView {
    private weak var current: LocalProcessTerminalView?
    /// Pencere sürüklenirken SwiftTerm'in ağır yeniden boyutlama hattını her
    /// fare hareketinde koşturmamak için sönümleme.
    private var resizeDebounce: DispatchWorkItem?

    func attach(_ terminal: LocalProcessTerminalView) {
        if current === terminal { return }
        // Aynı NSView iki hiyerarşide olamaz — ikisini de sök.
        current?.removeFromSuperview()
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        current = terminal

        // Çift tazeleme: t=0 boyut + odak + ilk çizim, t=350 ms Cocoa yerleşim
        // turu bittikten sonra ikinci çizim. Takas sonrası bayat tuvali
        // belirlenimci biçimde toparlar.
        DispatchQueue.main.async { [weak terminal, weak self] in
            guard let view = terminal, let self, let window = view.window else { return }
            if bounds.width > 0 && bounds.height > 0 { view.setFrameSize(self.bounds.size) }
            window.makeFirstResponder(view)
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak terminal] in
            guard let view = terminal, view.window != nil else { return }
            let term = view.getTerminal()
            term.refresh(startRow: 0, endRow: term.rows)
            view.needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let terminal = current, newSize.width > 0, newSize.height > 0 else { return }
        terminal.setFrameSize(newSize)

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
