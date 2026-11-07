import MossadCore
import SwiftUI

/// Chats with Claude over every meeting: the saved chats on the left, the open chat on the right. Times in the
/// answers are chips that open the meeting at that moment. The composer is the page's only glass.
struct ChatView: View {
    @EnvironmentObject var controller: AppController
    @State private var chats: [Chat] = []
    @State private var selection: UUID?
    @State private var draft = Chat(title: "New chat")
    @State private var question = ""
    @State private var running: UUID?
    @State private var steps: [String] = []
    @State private var error: String?
    @FocusState private var focused: Bool

    private var current: Chat {
        chats.first { $0.id == selection } ?? draft
    }

    private var isEmpty: Bool { current.messages.isEmpty && running != current.id }

    var body: some View {
        HStack(spacing: 0) {
            ChatList(chats: chats, selection: $selection, delete: delete)
                .frame(width: 300)
            Hairline(axis: .vertical)
            conversation.frame(maxWidth: .infinity)
        }
        .background(Palette.window)
        .navigationTitle("Chat")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: newChat) { Label("New chat", systemImage: "square.and.pencil") }
                    .help("New chat (⌘N)")
            }
        }
        .onAppear(perform: reload)
        .onChange(of: controller.newChatRequest) { _, _ in newChat() }
        .onChange(of: controller.chatsVersion) { _, _ in reload() }
        .onChange(of: selection) { _, _ in error = nil }
    }

    // MARK: Conversation

    private var conversation: some View {
        Group {
            if isEmpty {
                ScrollView {
                    welcome
                        .padding(.horizontal, 36)
                        .padding(.bottom, 80)
                        // Full width, so the scroll view (and its edge under the toolbar) spans the pane.
                        .frame(maxWidth: .infinity)
                        .containerRelativeFrame(.vertical)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                exchange
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom) {
            composer
                .frame(maxWidth: isEmpty ? 720 : Self.column - LabelColumn<EmptyView>.labelWidth - Space.m)
                .padding(.leading, isEmpty ? 0 : LabelColumn<EmptyView>.labelWidth + Space.m)
                .frame(maxWidth: isEmpty ? 720 : Self.column, alignment: .leading)
                .padding(.horizontal, 36).padding(.bottom, Space.l).padding(.top, 6)
                .frame(maxWidth: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in controller.openLink(url) ? .handled : .systemAction })
    }

    /// The reading column of a chat: the label column and an answer at a comfortable measure.
    private static let column: CGFloat = 880

    private var exchange: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LabelColumnStack(spacing: Space.m) {
                    if let id = current.callID, let r = controller.meetings.first(where: { $0.id == id }) {
                        LabelColumn(label: "About", labelTopPadding: 6) { MeetingPill(record: r) }
                    }
                    ForEach(current.messages) { m in
                        ChatExchangeRow(message: m).id(m.id)
                    }
                    if running == current.id {
                        LabelColumn(label: "Answer") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                                    Label(s, systemImage: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                }
                                Text(steps.isEmpty ? "Thinking…" : "Reading…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                    .phaseAnimator([0.45, 1]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.8) }
                            }
                        }
                        .id("running")
                    }
                    if let error {
                        LabelColumn(label: "") { Text(error).font(.system(size: 13)).foregroundStyle(Palette.recording) }
                    }
                }
                .frame(maxWidth: Self.column, alignment: .leading)
                .padding(.horizontal, 36).padding(.top, 28).padding(.bottom, Space.xl)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: current.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(current.messages.last?.id, anchor: .top) }
            }
            .onChange(of: steps.count) { _, _ in withAnimation { proxy.scrollTo("running", anchor: .bottom) } }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "sparkle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text("Ask about your meetings")
                .font(.system(size: 26, weight: .semibold)).tracking(-0.52)
                .foregroundStyle(Palette.ink)
                .padding(.top, Space.l)
                .accessibilityAddTraits(.isHeader)
            Text("Every call is searchable: who said what, what people agreed to and by when, what was decided, which meetings covered a topic. Answers link to the meeting and the moment.")
                .font(.system(size: 14)).lineSpacing(4)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(examples.enumerated()), id: \.offset) { i, e in
                    ExampleQuestion(text: e, last: i == examples.count - 1) { question = e; send() }
                }
            }
            .padding(.top, 22)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var examples: [String] {
        let person = controller.meetings.lazy.compactMap { r in
            r.speakerNames.values.first { $0 != controller.ownerName && !$0.hasPrefix("Speaker ") }
        }.first.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "the team"
        return [
            "What did \(person) and I agree to last call, and was there a deadline?",
            "Which meetings this month were about the budget?",
            "What do I owe people from this week’s meetings?",
            "Summarize everything decided about Databricks.",
        ]
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(current.messages.isEmpty ? "Ask about your meetings" : "Ask a follow-up", text: $question, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...6)
                .padding(.vertical, 4)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 26, height: 26)
                    .background(Palette.accentFill, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.5)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 7)
        .mossadGlass(cornerRadius: 20, interactive: true)
        .onAppear { focused = true }
    }

    private var canSend: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty && running == nil }

    // MARK: Actions

    private func reload() {
        chats = controller.chats.all()
        // Development hook: `--open-latest-chat`.
        if selection == nil, CommandLine.arguments.contains("--open-latest-chat") { selection = chats.first?.id }
        // Development hook for screenshots: MOSSAD_CHAT=<the start of a chat id> opens that chat.
        if selection == nil, CommandLine.arguments.contains("--ui-preview"),
           let prefix = ProcessInfo.processInfo.environment["MOSSAD_CHAT"]?.uppercased() {
            selection = chats.first { $0.id.uuidString.hasPrefix(prefix) }?.id
        }
    }

    private func newChat() {
        draft = Chat(title: "New chat")
        selection = nil
        error = nil
        question = ""
        focused = true
    }

    private func delete(_ chat: Chat) {
        controller.chats.delete(chat.id)
        if selection == chat.id { newChat() }
        reload()
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, running == nil else { return }
        var chat = current
        let history = chat.messages
        if chat.messages.isEmpty { chat.title = Chat.title(from: q) }
        chat.messages.append(ChatMessage(role: .user, text: q))
        chat.updated = Date()
        store(chat)
        question = ""
        error = nil
        steps = []
        running = chat.id
        let collector = StepSink { step in Task { @MainActor in steps.append(step) } }
        Task {
            do {
                let answer = try await controller.chatAnswer(q, history: history, about: chat.callID, onStep: collector.add)
                chat.messages.append(ChatMessage(role: .assistant, text: answer, steps: steps))
                chat.updated = Date()
                store(chat)
                controller.summarizeChat(chat.id)
                controller.syncNow()
            } catch {
                self.error = "\(error)"
            }
            running = nil
            focused = true
        }
    }

    /// Saves the chat and keeps it selected; a new chat becomes a saved one with its first question.
    private func store(_ chat: Chat) {
        do { try controller.chats.save(chat) } catch { Log.error("Saving the chat failed: \(error)") }
        reload()
        selection = chat.id
    }
}

final class StepSink: Sendable {
    let add: @Sendable (String) -> Void
    init(_ add: @escaping @Sendable (String) -> Void) { self.add = add }
}

/// The saved chats, newest first: the title on one line and the day under it. The arrow keys move the selection.
private struct ChatList: View {
    let chats: [Chat]
    @Binding var selection: UUID?
    let delete: (Chat) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(chats) { chat in
                        ChatListRow(chat: chat, selected: selection == chat.id) { selection = chat.id }
                            .id(chat.id)
                            .contextMenu {
                                Button("Delete chat", role: .destructive) { delete(chat) }
                            }
                            .accessibilityAction(named: "Delete chat") { delete(chat) }
                    }
                    if chats.isEmpty {
                        Text("Your chats show here.")
                            .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                            .padding(.horizontal, 10).padding(.top, Space.s)
                    }
                }
                .padding(.leading, 4).padding(.trailing, Space.s).padding(.vertical, Space.s)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1, proxy) }
            .onKeyPress(.upArrow) { move(-1, proxy) }
        }
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !chats.isEmpty else { return .ignored }
        let index = selection.flatMap { id in chats.firstIndex { $0.id == id } }.map { min(max($0 + by, 0), chats.count - 1) } ?? 0
        selection = chats[index].id
        proxy.scrollTo(chats[index].id)
        return .handled
    }
}

private struct ChatListRow: View {
    let chat: Chat
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 5) {
                    if chat.callID != nil {
                        Image(systemName: "waveform").font(.system(size: 9, weight: .medium)).foregroundStyle(Palette.tertiaryMark)
                            .accessibilityLabel("About one meeting")
                    }
                    Text(shortTime(chat.updated))
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One example on the empty chat: a plain line with a hairline under it, that asks it.
private struct ExampleQuestion: View {
    let text: String
    let last: Bool
    let ask: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: ask) {
            HStack(spacing: Space.s) {
                Text(text).font(.system(size: 13)).foregroundStyle(Palette.ink)
                Spacer(minLength: Space.s)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.tertiaryMark)
                    .opacity(hovering ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { if !last { Hairline() } }
        .accessibilityHint("Asks this question")
    }
}

/// The meeting a chat is about: its platform dot, title, and day on the fill. Opens it.
struct MeetingPill: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord

    var body: some View {
        Button { controller.openMeeting(record.id) } label: {
            HStack(spacing: 6) {
                PlatformDot(platform: record.platform, size: 7)
                Text(record.title).foregroundStyle(Palette.ink).lineLimit(1)
                Text(record.start.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(Palette.secondary)
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 10).frame(height: 26)
            .background(Palette.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open this meeting")
    }
}
