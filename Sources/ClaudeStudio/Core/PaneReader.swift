import Foundation

/// What a session is waiting for, read off its screen.
///
/// A hook can say that Claude handed the turn back. It cannot say WHY, and the
/// difference is the whole point: a turn that ended needs nothing, a turn that
/// ended on "1. Yes  2. No" needs an answer. Claude Code draws that prompt into
/// the TUI and blocks on a keypress — there is no hook payload for it, no file,
/// no API. The screen is the only place it exists.
///
/// So this is a heuristic over someone else's interface, and it is deliberately
/// conservative: when the shape is not unmistakable it reports nothing and the
/// session is treated as simply finished. The Swift twin of
/// `Bridge/lib/choices.mjs`, which does the same job for the phone — the two must
/// stay in step, since a notification and a status dot disagreeing about whether
/// a session is asking something is worse than either being wrong alone.
enum PaneReader {

    struct Screen: Equatable {
        /// The prompt above a selected numbered list, when there is one.
        var question: String?
        /// Its options, in order.
        var options: [String] = []
        /// The last thing the session actually said — the island's second line.
        var lastLine: String?
        /// What it is doing THIS second, while it is doing it: Claude's own status
        /// line, "Ebbing… (51s · ↓ 1.4k tokens)". For a working session this is the
        /// interesting line and the last thing it said is stale by definition.
        var activity: String?
        /// Is a turn actually in flight?
        ///
        /// Claude draws "esc to interrupt" in its footer for exactly as long as
        /// there is something to interrupt, which makes it the one honest witness
        /// to green. A hook cannot be: `Stop` never fires for a session that was
        /// killed mid-turn, or whose client went away, so its file says `working`
        /// forever and the dot stays green over a conversation that ended hours
        /// ago.
        var isWorking = false

        /// Is a numbered prompt on screen, waiting to be answered?
        var isAsking: Bool { !options.isEmpty }

        /// One line for a list row: the question if it is asking, what it is doing
        /// if it is doing something, and otherwise the last thing it said.
        var headline: String? {
            question?.nilIfEmpty
                ?? (isWorking ? activity?.nilIfEmpty : nil)
                ?? lastLine?.nilIfEmpty
        }
    }

    /// Reads every named session's screen in one tmux call.
    static func readAll(sessions: [String]) -> [String: Screen] {
        Tmux.capturePanes(sessions).mapValues { read($0) }
    }

    static func read(_ rawLines: [String]) -> Screen {
        let lines = rawLines.map(stripFrame)
        var screen = Screen()
        if let choices = readChoices(lines) {
            screen.question = choices.question
            screen.options = choices.options
        }
        screen.lastLine = lastSpokenLine(raw: rawLines, stripped: lines)
        screen.isWorking = lines.contains { $0.lowercased().contains("esc to interrupt") }
        screen.activity = statusLine(lines)
        return screen
    }

    /// Claude's own status line, without the spinner glyph in front of it.
    ///
    /// It is the one line that changes every second while a turn runs, and it
    /// carries the elapsed time and the token count — which together answer "is
    /// this moving, and how long has it been" without opening anything. The
    /// footer's mode hints start with the same family of glyphs, so a bracket is
    /// required: the status line always carries `(…)`.
    private static func statusLine(_ lines: [String]) -> String? {
        for line in lines.reversed() {
            guard let first = line.unicodeScalars.first,
                  "✻✳✶✽✢·*⠂⠄⠈⠐⠠⡀⢀⠁⠉⠙⠹⠸⠼⠴⠦⠧⠇⠏".unicodeScalars.contains(first),
                  line.contains("("), line.contains(")")
            else { continue }
            let text = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            let lower = text.lowercased()
            // The mode footer looks similar and is not an activity.
            if lower.contains("auto mode") || lower.contains("shift+tab") { continue }
            guard !text.isEmpty else { continue }
            return text.count > 120 ? String(text.prefix(120)) + "…" : text
        }
        return nil
    }

    // MARK: - Frame

    /// Box drawing and the padding tmux returns — but NOT the selection caret,
    /// which is the one mark that tells a prompt apart from prose.
    private static func stripFrame(_ line: String) -> String {
        var text = line
        for character in ["│", "┃", "|"] {
            text = text.replacingOccurrences(of: character, with: " ")
        }
        let leading = CharacterSet(charactersIn: " \t╭╰─━═┌└")
        let trailing = CharacterSet(charactersIn: " \t╮╯─━═┐┘")
        while let first = text.unicodeScalars.first, leading.contains(first) {
            text.removeFirst()
        }
        while let last = text.unicodeScalars.last, trailing.contains(last) {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The numbered prompt

    private struct Option {
        var number: Int
        var label: String
        var at: Int
        var selected: Bool
    }

    /// `1. Yes` / `❯ 2) No` — with the caret optional, because only ONE of the
    /// options carries it.
    private static func option(in line: String) -> (number: Int, label: String, selected: Bool)? {
        var rest = Substring(line)
        var selected = false
        if let first = rest.first, "❯›‣>".contains(first) {
            selected = true
            rest = rest.dropFirst()
            while let first = rest.first, first == " " { rest = rest.dropFirst() }
        }
        var digits = ""
        while let first = rest.first, first.isNumber, digits.count < 2 {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        guard let punctuation = rest.first, punctuation == "." || punctuation == ")" else { return nil }
        rest = rest.dropFirst()
        guard let space = rest.first, space == " " || space == "\t" else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (number, label, selected)
    }

    /// The numbered options at the bottom of the screen, if that is what this is.
    ///
    /// Requirements, all of them deliberate:
    ///   • at least two options, numbered from 1 and consecutive;
    ///   • one of them SELECTED — the caret the TUI draws on the current choice.
    ///     This is the discriminator the whole reader rests on. Claude writes
    ///     numbered lists in its ANSWERS all the time, and one of those sitting
    ///     above the input box is shape-identical to a prompt. Only a prompt has
    ///     something selected;
    ///   • they sit in the last screenful, adjacent to each other.
    private static func readChoices(_ lines: [String]) -> (question: String, options: [String])? {
        var end = -1
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            if option(in: lines[index]) != nil { end = index; break }
            // A few lines of footer ("esc to interrupt") may follow the box.
            if lines.count - index > 8 { return nil }
        }
        guard end >= 0 else { return nil }

        var collected: [Option] = []
        var anySelected = false
        for index in stride(from: end, through: 0, by: -1) {
            if let found = option(in: lines[index]) {
                if found.selected { anySelected = true }
                collected.insert(Option(number: found.number, label: found.label,
                                        at: index, selected: found.selected), at: 0)
                continue
            }
            // Blank lines inside the box are fine; anything else ends the block.
            if lines[index].isEmpty { continue }
            break
        }

        guard collected.count >= 2, anySelected else { return nil }
        guard collected.enumerated().allSatisfy({ $1.number == $0 + 1 }) else { return nil }

        // The question is the last thing said above the list. Claude's prompts put
        // a title there ("Bash command", "Edit file"), so a couple of lines are
        // joined rather than only the nearest one.
        var question: [String] = []
        var index = collected[0].at - 1
        while index >= 0 && question.count < 2 {
            let line = lines[index]
            index -= 1
            if line.isEmpty {
                if question.isEmpty { continue } else { break }
            }
            if option(in: line) != nil { break }
            question.insert(line, at: 0)
        }

        return (String(question.joined(separator: " — ").prefix(160)),
                collected.map { String($0.label.prefix(60)) })
    }

    // MARK: - The last thing said

    /// The last line of Claude's own output, skipping everything the TUI draws
    /// around it.
    ///
    /// What gets skipped is the whole reason this is not just "the last non-empty
    /// line": below Claude's answer sit the input box, the spinner's epitaph
    /// ("✻ Cogitated for 4m 20s"), the mode footer and the token hint — four
    /// lines of furniture, none of which is what the session said.
    private static func lastSpokenLine(raw: [String], stripped: [String]) -> String? {
        for index in stride(from: stripped.count - 1, through: 0, by: -1) {
            let text = stripped[index]
            guard !text.isEmpty, !isFurniture(raw: raw[index], stripped: text) else { continue }
            return text.count > 120 ? String(text.prefix(120)) + "…" : text
        }
        return nil
    }

    /// The raw line matters as well as the stripped one: the rule that carries the
    /// conversation's title (`──────── fix-openai-batch ──`) is nothing but frame,
    /// and stripping the frame off it leaves a perfectly ordinary-looking sentence
    /// that was never said.
    private static func isFurniture(raw: String, stripped: String) -> Bool {
        guard let first = stripped.unicodeScalars.first else { return true }
        // A rule, whatever is written into it.
        if let rawFirst = raw.trimmingCharacters(in: .whitespaces).unicodeScalars.first,
           "─━═╭╮╰╯┌┐└┘├┤".unicodeScalars.contains(rawFirst) { return true }
        // The input box's own caret, and whatever is typed into it but not sent.
        if "❯›‣>".unicodeScalars.contains(first) { return true }
        // The spinner and its epitaph, and the tool-output gutter.
        if "✻✳✶✽✢·*⏵⏸⎿⠂⠄⠈⠐⠠⡀⢀⠁⠉⠙⠹⠸⠼⠴⠦⠧⠇⠏".unicodeScalars.contains(first) { return true }
        // The mode footer and the token hint.
        if stripped.hasPrefix("/") && stripped.count <= 30 { return true }
        if stripped.allSatisfy({ "─━═-· ".contains($0) }) { return true }
        let lower = stripped.lowercased()
        for hint in ["esc to interrupt", "shift+tab to cycle", "? for shortcuts",
                     "new task?", "auto mode on", "bypass permissions",
                     "ctrl+c to exit", "to save ", "for agents"] where lower.contains(hint) {
            return true
        }
        return false
    }
}
