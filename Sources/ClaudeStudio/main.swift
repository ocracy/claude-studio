import AppKit

// Entry point. Windows belong to `WindowManager`, not to SwiftUI's `WindowGroup`:
// in an editor the number and identity of windows must be exact, so opening a
// folder, opening a new window and showing the welcome screen all go through the
// same deterministic path.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
