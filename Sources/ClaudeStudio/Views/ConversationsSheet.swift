import SwiftUI

struct ConversationsSheet: View {
    @Environment(\.studioTheme) private var theme
    @ObservedObject var model: StudioModel
    let onDismiss: () -> Void

    @State private var transcripts: [ClaudeTranscripts.Transcript] = []
    @State private var loading = true
    @State private var query = ""
    @State private var contentMatches: Set<String>?
    @State private var searching = false
    @State private var selected: String?
    @State private var messages: [ClaudeTranscripts.Message] = []
    @State private var loadingMessages = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var visible: [ClaudeTranscripts.Transcript] {
        guard !trimmedQuery.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.title.localizedCaseInsensitiveContains(trimmedQuery)
                || contentMatches?.contains($0.id) == true
        }
    }

    private var selectedTranscript: ClaudeTranscripts.Transcript? {
        transcripts.first { $0.id == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.separator).frame(height: 1)
            if loading {
                placeholder("Reading transcripts…")
            } else if transcripts.isEmpty {
                placeholder("Claude has not recorded a conversation in this project yet.")
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 320)
                    Rectangle().fill(theme.separator).frame(width: 1)
                    preview
                }
            }
        }
        .frame(width: 960, height: 640)
        .background(theme.surface)
        .onAppear(perform: load)
        .onChange(of: query) { scheduleSearch() }
        .onChange(of: selected) { loadMessages() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Conversations")
                .font(Theme.ui(15, .semibold))
                .foregroundStyle(theme.text)
            if !loading {
                Text(trimmedQuery.isEmpty ? "\(transcripts.count)" : "\(visible.count) of \(transcripts.count)")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(theme.text3)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.text3)
                TextField("Search titles and messages", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .focused($searchFocused)
                if searching {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: 300)
            .background(RoundedRectangle(cornerRadius: 6).fill(theme.field))
            SmallButton(title: "Done", action: onDismiss)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if visible.isEmpty {
                    Text(searching ? "Searching…" : "Nothing matches.")
                        .font(Theme.ui(11.5))
                        .foregroundStyle(theme.text3)
                        .padding(10)
                }
                ForEach(visible) { transcript in
                    HoverRow(selected: selected == transcript.id,
                             padding: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)) {
                        row(transcript)
                    }
                    .onTapGesture { selected = transcript.id }
                    .onTapGesture(count: 2) { resume(transcript) }
                }
            }
            .padding(8)
        }
    }

    private func row(_ transcript: ClaudeTranscripts.Transcript) -> some View {
        let open = isOpen(transcript)
        return HStack(spacing: 8) {
            Image(systemName: open ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 10))
                .foregroundStyle(open ? Theme.running : theme.text3)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Text("\(open ? "open · " : "")\(transcript.modified.relative) · \(transcript.id.prefix(8))")
                    .font(Theme.mono(10))
                    .foregroundStyle(theme.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
    }

    @ViewBuilder private var preview: some View {
        if let transcript = selectedTranscript {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transcript.title)
                            .font(Theme.ui(13, .medium))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        Text("\(transcript.modified.shortStamp) · \(transcript.id)")
                            .font(Theme.mono(10))
                            .foregroundStyle(theme.text3)
                            .lineLimit(1)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    SmallButton(title: isOpen(transcript) ? "Show" : "Resume",
                                icon: "arrow.uturn.backward", prominent: true) {
                        resume(transcript)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Rectangle().fill(theme.separator).frame(height: 1)

                if loadingMessages {
                    placeholder("Reading conversation…")
                } else if messages.isEmpty {
                    placeholder("No readable messages.")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(messages) { message in
                                    bubble(message).id(message.id)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onAppear { scrollToTarget(proxy) }
                        .onChange(of: messages) { scrollToTarget(proxy) }
                    }
                }
            }
        } else {
            placeholder("Pick a conversation to read it.")
        }
    }

    @ViewBuilder private func bubble(_ message: ClaudeTranscripts.Message) -> some View {
        switch message.role {
        case .tools:
            Text(message.text)
                .font(Theme.mono(10.5))
                .foregroundStyle(theme.text3)
                .lineLimit(2)
        case .user, .claude:
            let user = message.role == .user
            VStack(alignment: .leading, spacing: 4) {
                Text(user ? "YOU" : "CLAUDE")
                    .font(Theme.sectionLabel())
                    .tracking(0.6)
                    .foregroundStyle(user ? theme.accent : theme.text3)
                Text(message.text)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(user ? theme.field : .clear))
        }
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let last = messages.last else { return }
        let target = trimmedQuery.isEmpty ? nil
            : messages.first { $0.text.localizedCaseInsensitiveContains(trimmedQuery) }
        DispatchQueue.main.async {
            proxy.scrollTo((target ?? last).id, anchor: target == nil ? .bottom : .top)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(12.5))
            .foregroundStyle(theme.text3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func isOpen(_ transcript: ClaudeTranscripts.Transcript) -> Bool {
        model.sessions.first { $0.claudeSID == transcript.id }.map { model.isOpen($0) } ?? false
    }

    private func resume(_ transcript: ClaudeTranscripts.Transcript) {
        model.resumeTranscript(transcript)
        onDismiss()
    }

    private func load() {
        searchFocused = true
        let path = model.project.path
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ClaudeTranscripts.list(projectPath: path, limit: 1000)
            }.value
            transcripts = found
            selected = found.first?.id
            loading = false
        }
    }

    private func loadMessages() {
        guard let url = selectedTranscript?.url else {
            messages = []
            return
        }
        loadingMessages = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                ClaudeTranscripts.messages(of: url)
            }.value
            guard selectedTranscript?.url == url else { return }
            messages = found
            loadingMessages = false
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let needle = trimmedQuery
        guard needle.count >= 2 else {
            contentMatches = nil
            searching = false
            return
        }
        let path = model.project.path
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                ClaudeTranscripts.search(projectPath: path, query: needle)
            }.value
            guard !Task.isCancelled else { return }
            contentMatches = found
            searching = false
            if let selected, !visible.contains(where: { $0.id == selected }) {
                self.selected = visible.first?.id
            } else if selected != nil {
                loadMessages()
            }
        }
    }
}
