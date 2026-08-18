import SwiftUI
import AppKit

/// A small markdown renderer.
///
/// No dependencies: headings, bullets, numbered lists, code blocks, quotes, rules
/// and inline formatting (bold, italic, `code`, links) — everything a SKILL.md
/// file actually uses.
struct MarkdownView: View {
    @Environment(\.studioTheme) private var theme
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownParser.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(Theme.ui(level == 1 ? 19 : level == 2 ? 16 : 14, .semibold))
                .foregroundStyle(theme.text)
                .padding(.top, level == 1 ? 4 : 16)
                .padding(.bottom, 6)

        case let .paragraph(text):
            Text(inline(text))
                .font(Theme.ui(13))
                .foregroundStyle(theme.text)
                .lineSpacing(4)
                .padding(.bottom, 10)

        case let .bullet(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(theme.text3)
                        Text(inline(item))
                            .font(Theme.ui(13))
                            .foregroundStyle(theme.text)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(.bottom, 12)

        case let .numbered(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(Theme.mono(12))
                            .foregroundStyle(theme.text3)
                        Text(inline(item))
                            .font(Theme.ui(13))
                            .foregroundStyle(theme.text)
                            .lineSpacing(3)
                    }
                }
            }
            .padding(.bottom, 12)

        case let .code(language, body):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(Theme.mono(10))
                        .foregroundStyle(theme.text3)
                        .padding(.bottom, 5)
                }
                Text(body)
                    .font(Theme.mono(12))
                    .foregroundStyle(theme.text)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.separator))
            )
            .padding(.bottom, 12)

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(theme.separator).frame(width: 2)
                Text(inline(text))
                    .font(Theme.ui(13))
                    .foregroundStyle(theme.text2)
                    .lineSpacing(4)
            }
            .padding(.bottom, 12)

        case let .table(header, rows):
            table(header: header, rows: rows)

        case .rule:
            Rectangle().fill(theme.separator).frame(height: 1).padding(.vertical, 10)
        }
    }

    /// A pipe table.
    ///
    /// `Grid` rather than a stack of `HStack`s: columns have to agree on their width
    /// across every row, and that is the one thing a stack cannot do. It scrolls
    /// horizontally because a report's table is often wider than the pane — the
    /// alternative is columns squeezed until the numbers wrap.
    private func table(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(inline(cell))
                            .font(Theme.ui(11.5, .semibold))
                            .foregroundStyle(theme.text2)
                    }
                }
                .padding(.vertical, 7)

                Divider().overlay(theme.separator).gridCellUnsizedAxes(.horizontal)

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell))
                                .font(Theme.ui(12))
                                .foregroundStyle(theme.text)
                        }
                    }
                    .padding(.vertical, 6)
                    if index < rows.count - 1 {
                        Divider().overlay(theme.separator.opacity(0.5))
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.field.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.separator))
            )
        }
        .padding(.bottom, 12)
    }

    /// Inline formatting — `AttributedString`'s markdown parser already handles
    /// bold, italic, code and links.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Line-based markdown parser.
enum MarkdownParser {

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet([String])
        case numbered([String])
        case code(String?, String)
        case quote(String)
        case table(header: [String], rows: [[String]])
        case rule
    }

    /// A pipe table's separator row: `|---|:--:|---:|`. It is what distinguishes a
    /// table from an ordinary line that happens to contain pipes, so it is matched
    /// strictly rather than by counting bars.
    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        let cells = splitRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let body = cell.trimmingCharacters(in: .whitespaces)
            return !body.isEmpty && body.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Splits `| a | b |` into its cells. Leading and trailing bars are optional,
    /// which is how most tables in the wild are written.
    static func splitRow(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        // `\|` is an escaped pipe inside a cell, not a column boundary.
        return body
            .replacingOccurrences(of: "\\|", with: "\u{0}")
            .components(separatedBy: "|")
            .map { $0.replacingOccurrences(of: "\u{0}", with: "|")
                     .trimmingCharacters(in: .whitespaces) }
    }

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
        }
        func flushAll() { flushParagraph(); flushLists() }

        var lines = text.components(separatedBy: .newlines)[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Code block: collect raw lines until the closing fence (or the end).
            if line.hasPrefix("```") {
                flushAll()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first,
                      !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                if !lines.isEmpty { lines = lines.dropFirst() }   // closing fence
                blocks.append(.code(language.isEmpty ? nil : language,
                                    body.joined(separator: "\n")))
                continue
            }

            if line.isEmpty { flushAll(); continue }

            if line.hasPrefix("#") {
                flushAll()
                let level = line.prefix(while: { $0 == "#" }).count
                let title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(min(level, 3), title))
                continue
            }

            if line == "---" || line == "***" || line == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if line.hasPrefix("> ") {
                flushAll()
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }

            // A pipe table: this line is the header, the next is the separator.
            // Without looking ahead, a header row is indistinguishable from a
            // paragraph — which is exactly how tables used to come out.
            if line.contains("|"),
               let next = lines.first, isTableSeparator(next) {
                flushAll()
                let header = splitRow(line)
                lines = lines.dropFirst()
                var rows: [[String]] = []
                while let candidate = lines.first {
                    let row = candidate.trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    lines = lines.dropFirst()
                    var cells = splitRow(row)
                    // Ragged rows are common; pad or trim to the header's width so
                    // the grid stays a grid.
                    while cells.count < header.count { cells.append("") }
                    if cells.count > header.count { cells = Array(cells.prefix(header.count)) }
                    rows.append(cells)
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("· ") {
                flushParagraph()
                if !numbers.isEmpty { blocks.append(.numbered(numbers)); numbers = [] }
                bullets.append(String(line.dropFirst(2)))
                continue
            }

            if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
                numbers.append(String(line[match.upperBound...]))
                continue
            }

            flushLists()
            paragraph.append(line)
        }
        flushAll()
        return blocks
    }
}
