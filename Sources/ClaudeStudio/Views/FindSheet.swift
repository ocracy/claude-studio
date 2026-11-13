import SwiftUI
import AppKit

struct FindSheet: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let tab: StudioTab
    let onDismiss: () -> Void

    @State private var lines: [String] = []
    @State private var loading = true
    @State private var query = ""
    @State private var needle = ""
    @State private var debounce: Task<Void, Never>?
    @State private var caseSensitive = false
    @State private var selected: Int?
    @FocusState private var focused: Bool

    private struct Match: Identifiable {
        var id: Int { line }
        var line: Int
    }

    private var matches: [Match] {
        guard needle.count >= 2 else { return [] }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        return lines.indices.reversed()
            .filter { lines[$0].range(of: needle, options: options) != nil }
            .prefix(500)
            .map { Match(line: $0) }
    }

    var body: some View {
        let found = matches
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(theme.text3)
                TextField("Find in \(tab.title)", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(14))
                    .focused($focused)
                    .onSubmit { selected = found.first?.line }
                Toggle("Aa", isOn: $caseSensitive)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Match case")
                Text(loading ? "Reading…" : needle.count < 2 ? "\(lines.count) lines"
                     : "\(found.count)\(found.count == 500 ? "+" : "") matches")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(theme.text3)
                    .fixedSize()
                SmallButton(title: "Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(theme.separator.opacity(0.5)).frame(height: 1)

            if loading {
                placeholder("Reading the scrollback…")
            } else if lines.isEmpty {
                placeholder(Tmux.isAvailable ? "Nothing in the scrollback yet." : "Searching needs tmux.")
            } else if needle.count < 2 {
                placeholder("Type at least two characters. The last 10,000 lines are searched, newest first.")
            } else if found.isEmpty {
                placeholder("No matches.")
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(found) { match in
                                HoverRow(selected: selected == match.line,
                                         padding: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8), radius: 6) {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text("\(match.line + 1)")
                                            .font(Theme.mono(10))
                                            .foregroundStyle(theme.text3)
                                            .frame(width: 44, alignment: .trailing)
                                        highlighted(lines[match.line])
                                            .font(Theme.mono(11.5))
                                            .lineLimit(1)
                                    }
                                }
                                .onTapGesture { selected = match.line }
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 420)
                    Rectangle().fill(theme.separator.opacity(0.5)).frame(width: 1)
                    context
                }
            }
        }
        .frame(width: 980, height: 620)
        .background(theme.surface)
        .onAppear(perform: load)
        .onChange(of: query) {
            debounce?.cancel()
            let next = query.trimmingCharacters(in: .whitespaces)
            debounce = Task {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                needle = next
            }
        }
    }

    @ViewBuilder private var context: some View {
        if let selected {
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(max(0, selected - 40)..<min(lines.count, selected + 41), id: \.self) { index in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(theme.text3)
                                    .frame(width: 44, alignment: .trailing)
                                highlighted(lines[index].isEmpty ? " " : lines[index])
                                    .font(Theme.mono(11.5))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.vertical, 1)
                            .background(index == selected ? theme.accent.opacity(0.14) : Color.clear)
                            .id(index)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(selected, anchor: .center) }
                .onChange(of: selected) { proxy.scrollTo(selected, anchor: .center) }
            }
        } else {
            placeholder("Pick a match to see it in context.")
        }
    }

    private func highlighted(_ line: String) -> Text {
        var attributed = AttributedString(line)
        attributed.foregroundColor = theme.text2
        guard needle.count >= 2 else { return Text(attributed) }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive, .diacriticInsensitive]
        var searchRange = line.startIndex..<line.endIndex
        while let range = line.range(of: needle, options: options, range: searchRange) {
            if let lower = AttributedString.Index(range.lowerBound, within: attributed),
               let upper = AttributedString.Index(range.upperBound, within: attributed) {
                attributed[lower..<upper].foregroundColor = theme.text
                attributed[lower..<upper].backgroundColor = theme.accent.opacity(0.35)
            }
            searchRange = range.upperBound..<line.endIndex
        }
        return Text(attributed)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(12.5))
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        focused = true
        guard Tmux.isAvailable,
              let session = model.engine.tmuxSession(key: tab.terminalKey) ?? (tab.kind == .session ? tab.ref : nil)
        else {
            loading = false
            return
        }
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                Tmux.capture(session, lines: 10_000)
            }.value
            var found = text.components(separatedBy: "\n")
            while found.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { found.removeLast() }
            lines = found
            loading = false
        }
    }
}
