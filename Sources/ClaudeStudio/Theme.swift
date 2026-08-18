import SwiftUI
import AppKit

/// The single source of design truth.
///
/// Restrained and native. Colors are macOS semantic colors, so light and dark
/// appearance are handled for free; only the accent and status colors are fixed.
/// No decoration: system font for the UI, SF Mono in the terminal.
enum Theme {

    // MARK: - Surfaces

    /// Main content background (the editor area).
    static let bg          = Color(nsColor: .textBackgroundColor)
    /// Sidebar, top bar and status bar.
    static let chrome      = Color(nsColor: .windowBackgroundColor)
    /// Selected row / active tab fill.
    static let selection   = Color(nsColor: .selectedContentBackgroundColor).opacity(0.16)
    static let hover       = Color(nsColor: .labelColor).opacity(0.06)
    static let separator   = Color(nsColor: .separatorColor)
    /// Card and input field background.
    static let field       = Color(nsColor: .controlBackgroundColor)

    // MARK: - Text

    static let text        = Color(nsColor: .labelColor)
    static let text2       = Color(nsColor: .secondaryLabelColor)
    static let text3       = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Accent and status

    /// Claude's orange — the only accent color.
    static let accent      = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let running     = Color(red: 0.290, green: 0.686, blue: 0.353)
    static let waiting     = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let warning     = Color(red: 0.847, green: 0.635, blue: 0.176)
    static let danger      = Color(red: 0.898, green: 0.353, blue: 0.310)
    static let idle        = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Terminal

    static let nsTermBG: NSColor = .textBackgroundColor
    static let nsTermFG: NSColor = .labelColor

    // MARK: - Typography

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Section heading: small, letterspaced.
    static func sectionLabel() -> Font { .system(size: 10.5, weight: .semibold) }
}

// MARK: - Project palettes

/// A named palette, in the shape the popular editor themes define one: a terminal
/// background and foreground, the 16 ANSI colors, and a single accent the interface
/// marks the project with.
///
/// An empty `ansi` means "leave the terminal alone" — that palette follows the system
/// appearance, exactly like `Theme`'s semantic colors do everywhere else. Only the
/// accent is honoured then, which is what keeps the default looking native in both
/// light and dark.
struct ThemePreset: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let accentHex: String
    let bgHex: String
    let fgHex: String
    /// 16 hex colors: 8 normal, then 8 bright. Empty = the terminal keeps its own.
    let ansi: [String]

    var followsSystem: Bool { ansi.isEmpty }

    static let claude = ThemePreset(
        id: "claude", name: "Claude", accentHex: "#D97757",
        bgHex: "", fgHex: "", ansi: [])

    /// The palettes offered in the picker, default first.
    static let all: [ThemePreset] = [
        claude,
        ThemePreset(id: "tokyo-night", name: "Tokyo Night", accentHex: "#7AA2F7",
                    bgHex: "#1A1B26", fgHex: "#C0CAF5", ansi: [
                        "#15161E", "#F7768E", "#9ECE6A", "#E0AF68",
                        "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                        "#414868", "#FF7A93", "#B9F27C", "#FF9E64",
                        "#7DA6FF", "#BB9AF7", "#0DB9D7", "#C0CAF5"]),
        ThemePreset(id: "dracula", name: "Dracula", accentHex: "#BD93F9",
                    bgHex: "#282A36", fgHex: "#F8F8F2", ansi: [
                        "#21222C", "#FF5555", "#50FA7B", "#F1FA8C",
                        "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                        "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
                        "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]),
        ThemePreset(id: "nord", name: "Nord", accentHex: "#88C0D0",
                    bgHex: "#2E3440", fgHex: "#D8DEE9", ansi: [
                        "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
                        "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                        "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
                        "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]),
        ThemePreset(id: "catppuccin-mocha", name: "Catppuccin Mocha", accentHex: "#CBA6F7",
                    bgHex: "#1E1E2E", fgHex: "#CDD6F4", ansi: [
                        "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
                        "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                        "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF",
                        "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]),
        ThemePreset(id: "one-dark", name: "One Dark", accentHex: "#61AFEF",
                    bgHex: "#282C34", fgHex: "#ABB2BF", ansi: [
                        "#282C34", "#E06C75", "#98C379", "#E5C07B",
                        "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
                        "#5C6370", "#E06C75", "#98C379", "#E5C07B",
                        "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF"]),
        ThemePreset(id: "gruvbox-dark", name: "Gruvbox Dark", accentHex: "#FABD2F",
                    bgHex: "#282828", fgHex: "#EBDBB2", ansi: [
                        "#282828", "#CC241D", "#98971A", "#D79921",
                        "#458588", "#B16286", "#689D6A", "#A89984",
                        "#928374", "#FB4934", "#B8BB26", "#FABD2F",
                        "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]),
        ThemePreset(id: "solarized-dark", name: "Solarized Dark", accentHex: "#268BD2",
                    bgHex: "#002B36", fgHex: "#93A1A1", ansi: [
                        "#073642", "#DC322F", "#859900", "#B58900",
                        "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                        "#002B36", "#CB4B16", "#586E75", "#657B83",
                        "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]),
        ThemePreset(id: "solarized-light", name: "Solarized Light", accentHex: "#268BD2",
                    bgHex: "#FDF6E3", fgHex: "#657B83", ansi: [
                        "#073642", "#DC322F", "#859900", "#B58900",
                        "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                        "#002B36", "#CB4B16", "#586E75", "#657B83",
                        "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]),
        ThemePreset(id: "monokai", name: "Monokai", accentHex: "#A6E22E",
                    bgHex: "#272822", fgHex: "#F8F8F2", ansi: [
                        "#272822", "#F92672", "#A6E22E", "#F4BF75",
                        "#66D9EF", "#AE81FF", "#A1EFE4", "#F8F8F2",
                        "#75715E", "#F92672", "#A6E22E", "#F4BF75",
                        "#66D9EF", "#AE81FF", "#A1EFE4", "#F9F8F5"]),
        ThemePreset(id: "github-dark", name: "GitHub Dark", accentHex: "#58A6FF",
                    bgHex: "#0D1117", fgHex: "#C9D1D9", ansi: [
                        "#484F58", "#FF7B72", "#3FB950", "#D29922",
                        "#58A6FF", "#BC8CFF", "#39C5CF", "#B1BAC4",
                        "#6E7681", "#FFA198", "#56D364", "#E3B341",
                        "#79C0FF", "#D2A8FF", "#56D4DD", "#F0F6FC"]),
        ThemePreset(id: "github-light", name: "GitHub Light", accentHex: "#0969DA",
                    bgHex: "#FFFFFF", fgHex: "#24292F", ansi: [
                        "#24292F", "#CF222E", "#116329", "#4D2D00",
                        "#0969DA", "#8250DF", "#1B7C83", "#6E7781",
                        "#57606A", "#A40E26", "#1A7F37", "#633C01",
                        "#218BFF", "#A475F9", "#3192AA", "#8C959F"]),
        ThemePreset(id: "rose-pine", name: "Rosé Pine", accentHex: "#EBBCBA",
                    bgHex: "#191724", fgHex: "#E0DEF4", ansi: [
                        "#26233A", "#EB6F92", "#31748F", "#F6C177",
                        "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
                        "#6E6A86", "#EB6F92", "#31748F", "#F6C177",
                        "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4"]),
        ThemePreset(id: "everforest", name: "Everforest", accentHex: "#A7C080",
                    bgHex: "#2D353B", fgHex: "#D3C6AA", ansi: [
                        "#343F44", "#E67E80", "#A7C080", "#DBBC7F",
                        "#7FBBB3", "#D699B6", "#83C092", "#D3C6AA",
                        "#868D80", "#E67E80", "#A7C080", "#DBBC7F",
                        "#7FBBB3", "#D699B6", "#83C092", "#D3C6AA"]),
        ThemePreset(id: "ayu-mirage", name: "Ayu Mirage", accentHex: "#FFCC66",
                    bgHex: "#1F2430", fgHex: "#CBCCC6", ansi: [
                        "#191E2A", "#ED8274", "#A6CC70", "#FAD07B",
                        "#6DCBFA", "#CFBAFA", "#90E1C6", "#C7C7C7",
                        "#686868", "#F28779", "#BAE67E", "#FFD580",
                        "#73D0FF", "#D4BFFF", "#95E6CB", "#FFFFFF"]),
        ThemePreset(id: "night-owl", name: "Night Owl", accentHex: "#82AAFF",
                    bgHex: "#011627", fgHex: "#D6DEEB", ansi: [
                        "#011627", "#EF5350", "#22DA6E", "#C5E478",
                        "#82AAFF", "#C792EA", "#21C7A8", "#FFFFFF",
                        "#575656", "#EF5350", "#22DA6E", "#FFEB95",
                        "#82AAFF", "#C792EA", "#7FDBCA", "#FFFFFF"]),
    ]

    static func named(_ id: String) -> ThemePreset {
        all.first { $0.id == id } ?? claude
    }
}

/// One project's resolved appearance: a preset, optionally with the accent replaced
/// by a color the user picked, and whether the chrome carries a wash of it.
///
/// This is what the interface reads — through `\.studioTheme`, never a global. Two
/// windows show two projects in the same process, so a shared mutable `Theme.accent`
/// would paint both the same.
struct StudioTheme: Equatable {
    var preset: ThemePreset = .claude
    /// Replaces the preset's accent. Empty means "use the preset's own".
    var customAccentHex: String = ""
    /// Wash the sidebar, top bar and status bar with the accent, so two windows
    /// side by side are told apart without reading their titles.
    var tintChrome: Bool = true

    static let `default` = StudioTheme()

    // MARK: Interface

    var accentNS: NSColor {
        NSColor(hex: customAccentHex) ?? NSColor(hex: preset.accentHex) ?? NSColor(Theme.accent)
    }
    var accent: Color { Color(nsColor: accentNS) }

    /// Label color for text sitting on the accent. Some of these accents are pale
    /// yellows and pinks, where white would be unreadable.
    var onAccent: Color {
        guard let rgb = accentNS.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.2126 * rgb.redComponent
                      + 0.7152 * rgb.greenComponent
                      + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? Color.black.opacity(0.8) : .white
    }

    /// Chrome surfaces: the window background plus a faint wash of the accent.
    @ViewBuilder var chrome: some View {
        ZStack {
            Theme.chrome
            if tintChrome && !isDefault { accent.opacity(0.07) }
        }
    }

    /// True when nothing has been chosen — the app looks exactly as it always has.
    var isDefault: Bool { preset.id == ThemePreset.claude.id && customAccentHex.isEmpty }

    // MARK: Terminal

    var terminalBG: NSColor { NSColor(hex: preset.bgHex) ?? Theme.nsTermBG }
    var terminalFG: NSColor { NSColor(hex: preset.fgHex) ?? Theme.nsTermFG }
    /// 16 ANSI colors, or empty when the terminal keeps its own palette.
    var terminalANSI: [String] { preset.ansi }
}

private struct StudioThemeKey: EnvironmentKey {
    static let defaultValue = StudioTheme.default
}

extension EnvironmentValues {
    /// The appearance of the project this window is showing.
    var studioTheme: StudioTheme {
        get { self[StudioThemeKey.self] }
        set { self[StudioThemeKey.self] = newValue }
    }
}

// MARK: - Hex

extension NSColor {
    /// `#RRGGBB` (with or without the hash). Returns nil for an empty or malformed
    /// string, which is how "this palette has no color of its own" is expressed.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green:   CGFloat((value >> 8) & 0xFF) / 255,
                  blue:    CGFloat(value & 0xFF) / 255,
                  alpha:   1)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "" }
        return String(format: "#%02X%02X%02X",
                      Int(round(rgb.redComponent * 255)),
                      Int(round(rgb.greenComponent * 255)),
                      Int(round(rgb.blueComponent * 255)))
    }
}

/// Sidebar section heading.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.sectionLabel())
            .tracking(0.6)
            .foregroundStyle(Theme.text3)
    }
}

/// Status dot — running / waiting / stopped.
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 6
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

/// A row that highlights on hover.
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

/// Small, plain button. Use `prominent` only for the primary action.
struct SmallButton: View {
    let title: String
    var icon: String? = nil
    var prominent: Bool = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.studioTheme) private var theme

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
                    .fill(prominent ? theme.accent : (hovering ? Theme.hover : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(prominent ? .clear : Theme.separator)
                    )
            )
            .foregroundStyle(prominent ? theme.onAccent : Theme.text)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Icon-only tool button.
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
