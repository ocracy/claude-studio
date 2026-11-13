import SwiftUI

struct ChangesSheet: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let path: String
    let onDismiss: () -> Void

    @State private var files: [GitChanges.FileChange] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var commentLine: Int?
    @State private var draft = ""
    @State private var comments: [Comment] = []
    @FocusState private var draftFocused: Bool

    struct Comment: Identifiable, Equatable {
        let id = UUID()
        var file: String
        var line: String
        var code: String
        var text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.separator.opacity(0.5)).frame(height: 1)
            if loading {
                placeholder("Reading changes…")
            } else if files.isEmpty {
                placeholder("No uncommitted changes")
            } else {
                HStack(spacing: 0) {
                    fileList.frame(width: 270)
                    Rectangle().fill(theme.separator.opacity(0.5)).frame(width: 1)
                    patch
                }
            }
            if !comments.isEmpty {
                Rectangle().fill(theme.separator.opacity(0.5)).frame(height: 1)
                commentTray
            }
        }
        .frame(width: 980, height: 660)
        .background(theme.surface)
        .onAppear(perform: load)
        .onChange(of: selected) {
            commentLine = nil
            draft = ""
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Changes")
                .font(Theme.ui(15, .semibold))
                .foregroundStyle(theme.text)
            if !files.isEmpty {
                Text("\(files.count) \(files.count == 1 ? "file" : "files")")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(theme.text3)
                counts(added: files.reduce(0) { $0 + $1.added },
                       removed: files.reduce(0) { $0 + $1.removed })
            }
            Spacer()
            Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(Theme.ui(11))
                .foregroundStyle(theme.text3)
                .lineLimit(1)
                .truncationMode(.head)
            IconButton(icon: "arrow.clockwise", help: "Refresh", action: load)
            SmallButton(title: "Done", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(files) { file in
                    HoverRow(selected: selected == file.path, radius: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text((file.path as NSString).lastPathComponent)
                                    .font(Theme.ui(12))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(1)
                                let count = comments.filter { $0.file == file.path }.count
                                if count > 0 {
                                    Image(systemName: "text.bubble")
                                        .font(.system(size: 9.5, weight: .light))
                                        .foregroundStyle(theme.accent)
                                    Text("\(count)").font(Theme.ui(10)).foregroundStyle(theme.accent)
                                }
                            }
                            HStack(spacing: 6) {
                                if file.untracked {
                                    Text("new").font(Theme.ui(10.5)).foregroundStyle(theme.accent)
                                }
                                counts(added: file.added, removed: file.removed)
                                Text((file.path as NSString).deletingLastPathComponent)
                                    .font(Theme.ui(10))
                                    .foregroundStyle(theme.text3)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                    }
                    .onTapGesture { selected = file.path }
                }
            }
            .padding(8)
        }
    }

    private var patch: some View {
        let file = files.first { $0.path == selected }
        let lines = GitChanges.numbered(file?.patch ?? [], untracked: file?.untracked ?? false)
        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    patchLine(line, index: index, file: file?.path ?? "")
                    if commentLine == index, let file {
                        commentEditor(line, file: file.path)
                    }
                    ForEach(comments.filter { $0.file == file?.path && $0.line == label(line) }) { comment in
                        commentBubble(comment)
                    }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(selected)
    }

    private func patchLine(_ line: GitChanges.Line, index: Int, file: String) -> some View {
        HStack(spacing: 0) {
            Text(line.old.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
            Text(line.new.map(String.init) ?? "")
                .frame(width: 38, alignment: .trailing)
            Image(systemName: "plus.bubble")
                .font(.system(size: 9.5, weight: .light))
                .foregroundStyle(theme.accent)
                .frame(width: 22)
                .opacity(commentLine == index ? 1 : 0)
            Text(line.text.isEmpty ? " " : line.text)
                .font(Theme.mono(11.5))
                .foregroundStyle(color(of: line.text))
                .fixedSize(horizontal: true, vertical: false)
                .padding(.trailing, 16)
        }
        .font(Theme.mono(10))
        .foregroundStyle(theme.text3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background(of: line.text, active: commentLine == index))
        .contentShape(Rectangle())
        .onTapGesture {
            guard line.commentable else { return }
            commentLine = commentLine == index ? nil : index
            draft = ""
            if commentLine != nil { DispatchQueue.main.async { draftFocused = true } }
        }
        .help(line.commentable ? "Click to comment on this line" : "")
    }

    private func commentEditor(_ line: GitChanges.Line, file: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("Comment for Claude on \((file as NSString).lastPathComponent):\(label(line))…",
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .lineLimit(1...5)
                .focused($draftFocused)
                .onSubmit { addComment(line, file: file) }
            SmallButton(title: "Add", prominent: true) { addComment(line, file: file) }
                .disabled(draft.nilIfEmpty == nil)
            IconButton(icon: "xmark", help: "Cancel") { commentLine = nil }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.field))
        .padding(.leading, 98)
        .padding(.trailing, 16)
        .padding(.vertical, 6)
    }

    private func commentBubble(_ comment: Comment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 11, weight: .light))
                .foregroundStyle(theme.accent)
            Text(comment.text)
                .font(Theme.ui(12))
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            IconButton(icon: "trash", help: "Remove comment") {
                comments.removeAll { $0.id == comment.id }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.accent.opacity(0.08)))
        .padding(.leading, 98)
        .padding(.vertical, 4)
    }

    private var commentTray: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(theme.accent)
            Text("\(comments.count) \(comments.count == 1 ? "comment" : "comments")")
                .font(Theme.ui(12.5, .medium))
                .foregroundStyle(theme.text)
            if let target = targetSession {
                Text("to \(target.title)")
                    .font(Theme.ui(12))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
            } else {
                Text("Open a Claude session to send them.")
                    .font(Theme.ui(12))
                    .foregroundStyle(theme.text3)
            }
            Spacer()
            SmallButton(title: "Clear") { comments.removeAll() }
            SmallButton(title: "Send to Claude", icon: "paperplane", prominent: true, action: send)
                .disabled(targetSession == nil)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var targetSession: StudioTab? {
        if let active = model.activeTab, active.kind == .session { return active }
        return model.tabs.first { $0.kind == .session }
    }

    private func addComment(_ line: GitChanges.Line, file: String) {
        guard let text = draft.nilIfEmpty else { return }
        comments.append(Comment(file: file, line: label(line),
                                code: String(line.text.dropFirst()).trimmingCharacters(in: .whitespaces),
                                text: text))
        draft = ""
        commentLine = nil
    }

    private func send() {
        guard let target = targetSession else { return }
        let grouped = Dictionary(grouping: comments, by: \.file)
        var message = "Review comments on the uncommitted changes:"
        for file in grouped.keys.sorted() {
            for comment in grouped[file] ?? [] {
                let code = comment.code.count > 80 ? String(comment.code.prefix(80)) + "…" : comment.code
                message += " \(file):\(comment.line) (`\(code)`): \(comment.text.replacingOccurrences(of: "\n", with: " "))."
            }
        }
        model.activeTabID = target.id
        model.engine.send(key: target.terminalKey, text: message)
        comments.removeAll()
        onDismiss()
    }

    private func label(_ line: GitChanges.Line) -> String {
        if let new = line.new { return "\(new)" }
        if let old = line.old { return "\(old) (removed)" }
        return ""
    }

    private func counts(added: Int, removed: Int) -> some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(Theme.running)
            Text("−\(removed)").foregroundStyle(Theme.danger)
        }
        .font(Theme.mono(10.5))
    }

    private func color(of line: String) -> Color {
        if line.hasPrefix("@@") { return theme.accent }
        if line.hasPrefix("+") { return Theme.running }
        if line.hasPrefix("-") { return Theme.danger }
        return theme.text2
    }

    private func background(of line: String, active: Bool) -> Color {
        if active { return theme.accent.opacity(0.14) }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Theme.running.opacity(0.07) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Theme.danger.opacity(0.07) }
        return .clear
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(12.5))
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() {
        let path = path
        Task {
            let found = await Task.detached(priority: .userInitiated) { GitChanges.files(at: path) }.value
            files = found
            if selected == nil || !found.contains(where: { $0.path == selected }) {
                selected = found.first?.path
            }
            loading = false
        }
    }
}
