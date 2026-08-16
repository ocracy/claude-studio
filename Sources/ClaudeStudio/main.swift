import AppKit

// Giriş noktası. Pencereler SwiftUI'nin `WindowGroup`'una değil, `WindowManager`a
// aittir: bir editörde pencere sayısı ve kimliği kesin olmalıdır — klasörle
// açma, yeni pencere ve karşılama ekranı hep aynı deterministik yoldan geçer.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
