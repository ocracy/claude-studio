import SwiftUI

/// Pencere içeriği: proje yoksa karşılama ekranı, varsa stüdyo.
struct RootView: View {
    let model: StudioModel?
    let onOpen: (Project) -> Void
    let onClose: () -> Void

    var body: some View {
        Group {
            if let model {
                StudioView(model: model, onClose: onClose)
                    .id(model.project.path)
            } else {
                WelcomeView(onOpen: onOpen)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(Theme.bg)
    }
}
