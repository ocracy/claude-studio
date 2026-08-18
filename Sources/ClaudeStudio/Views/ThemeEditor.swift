import SwiftUI
import AppKit

/// Picks the project's palette.
///
/// Every change is applied and saved as it is made — there is no "apply" step and no
/// cancel, because the whole point is to see the window and its terminals in the new
/// colors while choosing. The palettes are the well-known editor themes; the accent
/// can be replaced by any color, which is what makes twenty projects tellable apart
/// when sixteen presets are not enough.
struct ThemeEditor: View {
    @ObservedObject var model: StudioModel
    let onDismiss: () -> Void

    private var theme: StudioTheme { model.theme }

    private let columns = [GridItem(.adaptive(minimum: 148), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ThemePreset.all) { preset in
                        card(preset)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }
            .frame(height: 340)

            Divider()

            accentRow
            Divider()
            footer
        }
        .frame(width: 520)
        .background(Theme.bg)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Appearance")
                .font(Theme.ui(15, .semibold))
                .foregroundStyle(Theme.text)
            Text(model.project.name)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.text3)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // MARK: - Palette card

    private func card(_ preset: ThemePreset) -> some View {
        let selected = preset.id == theme.preset.id
        return Button {
            // Picking a palette drops a custom accent: the point of choosing
            // "Dracula" is to get Dracula, not to keep the last color over it.
            model.setTheme(presetID: preset.id, accentHex: "", tintChrome: theme.tintChrome)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                preview(preset)
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(nsColor: NSColor(hex: preset.accentHex) ?? .controlAccentColor))
                        .frame(width: 7, height: 7)
                    Text(preset.name)
                        .font(Theme.ui(11.5, selected ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? theme.accent : Theme.separator,
                                  lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A miniature terminal: the palette's own background, a line of its foreground
    /// and the eight colors you actually see in a shell prompt.
    private func preview(_ preset: ThemePreset) -> some View {
        let bg = NSColor(hex: preset.bgHex).map { Color(nsColor: $0) } ?? Color(nsColor: .textBackgroundColor)
        let fg = NSColor(hex: preset.fgHex).map { Color(nsColor: $0) } ?? Color(nsColor: .labelColor)
        let swatches = preset.ansi.isEmpty
            ? [Theme.danger, Theme.running, Theme.warning, Theme.accent,
               Theme.waiting, Theme.idle, Theme.text2, Theme.text3]
            : (1...8).map { Color(nsColor: NSColor(hex: preset.ansi[$0]) ?? .gray) }

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 1.5).fill(color).frame(height: 7)
                }
            }
            RoundedRectangle(cornerRadius: 1.5).fill(fg.opacity(0.75)).frame(height: 4)
            RoundedRectangle(cornerRadius: 1.5).fill(fg.opacity(0.45))
                .frame(width: 78, height: 4)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6,
                                          style: .continuous))
    }

    // MARK: - Accent and tint

    private var accentRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Accent")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.text)
                    .frame(width: 96, alignment: .leading)

                ColorPicker("", selection: accentBinding, supportsOpacity: false)
                    .labelsHidden()

                Text(theme.customAccentHex.isEmpty
                     ? "from \(theme.preset.name)"
                     : theme.customAccentHex)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.text3)

                Spacer()

                if !theme.customAccentHex.isEmpty {
                    SmallButton(title: "Reset") {
                        model.setTheme(presetID: theme.preset.id, accentHex: "",
                                       tintChrome: theme.tintChrome)
                    }
                }
            }

            HStack(spacing: 10) {
                Text("Window tint")
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.text)
                    .frame(width: 96, alignment: .leading)
                Toggle("Wash the sidebar and bars with the accent", isOn: tintBinding)
                    .toggleStyle(.switch)
                    .tint(theme.accent)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.text2)
                Spacer()
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    /// Reading falls back to the preset's accent, so the well always shows the color
    /// currently in use rather than an empty override.
    private var accentBinding: Binding<Color> {
        Binding(
            get: { theme.accent },
            set: { model.setTheme(presetID: theme.preset.id,
                                  accentHex: NSColor($0).hexString,
                                  tintChrome: theme.tintChrome) }
        )
    }

    private var tintBinding: Binding<Bool> {
        Binding(
            get: { theme.tintChrome },
            set: { model.setTheme(presetID: theme.preset.id,
                                  accentHex: theme.customAccentHex,
                                  tintChrome: $0) }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Saved in .cs/settings.json")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.text3)
            Spacer()
            SmallButton(title: "Done", prominent: true, action: onDismiss)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}
