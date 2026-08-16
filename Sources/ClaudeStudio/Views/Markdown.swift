import SwiftUI
import AppKit

/// Sade markdown görüntüleyici.
///
/// Dış bağımlılık yok: başlık, madde, numaralı liste, kod bloğu, alıntı, çizgi
/// ve satır içi biçimlendirme (kalın, italik, `kod`, bağlantı) — bir SKILL.md
/// dosyasının gerçekte kullandığı her şey.
struct MarkdownView: View {
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
                .foregroundStyle(Theme.text)
                .padding(.top, level == 1 ? 4 : 16)
                .padding(.bottom, 6)

        case let .paragraph(text):
            Text(inline(text))
                .font(Theme.ui(13))
                .foregroundStyle(Theme.text)
                .lineSpacing(4)
                .padding(.bottom, 10)

        case let .bullet(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.text3)
                        Text(inline(item))
                            .font(Theme.ui(13))
                            .foregroundStyle(Theme.text)
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
                            .foregroundStyle(Theme.text3)
                        Text(inline(item))
                            .font(Theme.ui(13))
                            .foregroundStyle(Theme.text)
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
                        .foregroundStyle(Theme.text3)
                        .padding(.bottom, 5)
                }
                Text(body)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.separator))
            )
            .padding(.bottom, 12)

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(Theme.separator).frame(width: 2)
                Text(inline(text))
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.text2)
                    .lineSpacing(4)
            }
            .padding(.bottom, 12)

        case .rule:
            Rectangle().fill(Theme.separator).frame(height: 1).padding(.vertical, 10)
        }
    }

    /// Satır içi biçimlendirme — `AttributedString`'in markdown çözümleyicisi
    /// kalın/italik/kod/bağlantıyı zaten anlıyor.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Satır tabanlı markdown çözümleyici.
enum MarkdownParser {

    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet([String])
        case numbered([String])
        case code(String?, String)
        case quote(String)
        case rule
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

            // Kod bloğu: kapanış görülene (ya da metin bitene) kadar ham topla.
            if line.hasPrefix("```") {
                flushAll()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                while let next = lines.first,
                      !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(next)
                    lines = lines.dropFirst()
                }
                if !lines.isEmpty { lines = lines.dropFirst() }   // kapanış çiti
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
