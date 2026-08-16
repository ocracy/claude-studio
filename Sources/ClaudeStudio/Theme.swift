import SwiftUI
import AppKit

/// Tek tasarım kaynağı.
///
/// Ölçü: sade ve yerel. Renkler macOS'un anlamsal renkleridir — açık/koyu
/// görünüme kendiliğinden uyar; yalnız vurgu ve durum renkleri sabittir.
/// Süsleme yok: yazı tipi sistem yazı tipi, terminal SF Mono.
enum Theme {

    // MARK: - Yüzeyler

    /// Ana içerik zemini (editör alanı).
    static let bg          = Color(nsColor: .textBackgroundColor)
    /// Kenar çubuğu, üst ve alt barlar.
    static let chrome      = Color(nsColor: .windowBackgroundColor)
    /// Seçili satır / etkin sekme dolgusu.
    static let selection   = Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
    static let hover       = Color(nsColor: .labelColor).opacity(0.06)
    static let separator   = Color(nsColor: .separatorColor)
    /// Kart ve giriş alanı zemini.
    static let field       = Color(nsColor: .controlBackgroundColor)

    // MARK: - Metin

    static let text        = Color(nsColor: .labelColor)
    static let text2       = Color(nsColor: .secondaryLabelColor)
    static let text3       = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Vurgu ve durum

    /// Claude'un turuncusu — tek vurgu rengi.
    static let accent      = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let running     = Color(red: 0.290, green: 0.686, blue: 0.353)
    static let waiting     = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let warning     = Color(red: 0.847, green: 0.635, blue: 0.176)
    static let danger      = Color(red: 0.898, green: 0.353, blue: 0.310)
    static let idle        = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Terminal

    static let nsTermBG: NSColor = .textBackgroundColor
    static let nsTermFG: NSColor = .labelColor

    // MARK: - Tipografi

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Bölüm başlığı: küçük, harf aralıklı.
    static func sectionLabel() -> Font { .system(size: 10.5, weight: .semibold) }
}

/// Kenar çubuğu bölüm başlığı.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.sectionLabel())
            .tracking(0.6)
            .foregroundStyle(Theme.text3)
    }
}

/// Durum noktası — çalışıyor / bekliyor / durdu.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// Fare üstüne gelince zemini değişen satır.
struct HoverRow<Content: View>: View {
    var selected: Bool = false
    var padding: EdgeInsets = EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
    var radius: CGFloat = 5
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Theme.selection : (hovering ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Küçük, sade düğme. `prominent` yalnız birincil eylemde kullanılır.
struct SmallButton: View {
    let title: String
    var icon: String? = nil
    var prominent: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)) }
                Text(title).font(Theme.ui(11.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(prominent ? Theme.accent : (hovering ? Theme.hover : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(prominent ? .clear : Theme.separator)
                    )
            )
            .foregroundStyle(prominent ? Color.white : Theme.text)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Yalnız ikonlu araç düğmesi.
struct IconButton: View {
    let icon: String
    var help: String = ""
    var tint: Color = Theme.text2
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}
