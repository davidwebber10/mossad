import MossadCore
import SwiftUI

/// Chat over every meeting, the coach's reviews, and its memory of you. It is the coach on the phone too.
struct ChatScreen: View {
    @EnvironmentObject var store: PhoneStore
    @State private var chatID: UUID?
    @State private var draft = Chat(title: "New chat")
    @State private var question = ""
    @State private var running = false
    @State private var steps: [String] = []
    @State private var error: String?
    @State private var showChats = false
    @State private var showMemory = false
    @FocusState private var focused: Bool

    private var chat: Chat { chatID.flatMap { id in store.chats.first { $0.id == id } } ?? draft }

    var body: some View {
        NavigationStack {
            Group {
                if chat.messages.isEmpty { ChatWelcome { question = $0; send() } } else { conversation }
            }
            .dismissesKeyboard($focused)
            .safeAreaBar(edge: .bottom) { composer }
            .phonePage()
            .toolbar { toolbar }
            .navigationTitle(chat.messages.isEmpty ? "Chat" : chat.title)
            .navigationBarTitleDisplayMode(chat.messages.isEmpty ? .large : .inline)
            .sheet(isPresented: $showChats) { ChatList(selected: $chatID, onPick: { showChats = false }) }
            .sheet(isPresented: $showMemory) { CoachMemoryView() }
            // Development hook for screenshots: `MOSSAD_CHAT=1` opens the newest chat.
            .onAppear { if PhoneStore.hook("MOSSAD_CHAT") != nil, chatID == nil { chatID = store.chats.first?.id } }
            // Search opened a chat.
            .onChange(of: store.openChat, initial: true) { _, id in
                guard let id else { return }
                store.openChat = nil
                if store.chats.contains(where: { $0.id == id }) { chatID = id }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let link = ChatLink.parse(url) else { return .systemAction }
            store.open(link)
            return .handled
        })
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Chats", systemImage: "clock.arrow.circlepath") { showChats = true }.tint(Palette.ink)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("The coach's memory", systemImage: "brain") { showMemory = true }.tint(Palette.ink)
            Button("New chat", systemImage: "square.and.pencil") { newChat() }.disabled(running).tint(Palette.ink)
        }
    }

    private var conversation: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.messages) { MessageBubble(message: $0).id($0.id) }
                    if running { thinking.id("thinking") }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").textRole(.secondary).foregroundStyle(Palette.recording)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.count) { scroll(scroller) }
            .onChange(of: running) { scroll(scroller) }
        }
    }

    private var thinking: some View {
        HStack(spacing: 10) {
            PhoneProcessingMark()
            Text(steps.last ?? "Thinking…").textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(1)
                .contentTransition(.opacity)
        }
        .animation(.default, value: steps.count)
    }

    private var composer: some View {
        ChatComposer(text: $question, prompt: "Ask about your meetings", focused: $focused, disabled: running) { send() }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.s)
    }

    private func scroll(_ scroller: ScrollViewProxy) {
        withAnimation {
            if running { scroller.scrollTo("thinking", anchor: .bottom) } else if let last = chat.messages.last { scroller.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private func newChat() {
        draft = Chat(title: "New chat")
        chatID = nil
        error = nil
        question = ""
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        var chat = chat
        let history = chat.messages
        if chat.messages.isEmpty { chat.title = Chat.title(from: q) }
        chat.messages.append(ChatMessage(role: .user, text: q))
        chat.updated = Date()
        store.save(chat)
        chatID = chat.id
        question = ""
        error = nil
        steps = []
        running = true
        let sink = StepSink { step in Task { @MainActor in steps.append(step) } }
        Task {
            do {
                let answer = try await store.answer(q, history: history, about: chat.callID, onStep: sink.add)
                var latest = store.chats.first { $0.id == chat.id } ?? chat
                latest.messages.append(ChatMessage(role: .assistant, text: answer, steps: steps))
                latest.updated = Date()
                store.save(latest)
                store.finish(latest.id)
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}

final class StepSink: Sendable {
    let add: @Sendable (String) -> Void
    init(_ add: @escaping @Sendable (String) -> Void) { self.add = add }
}

/// Earlier chats from both devices, newest first.
private struct ChatList: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selected: UUID?
    let onPick: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.chats) { chat in
                    Button {
                        selected = chat.id
                        onPick()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chat.title).font(.body).foregroundStyle(.primary).lineLimit(1)
                            if let summary = chat.summary {
                                Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(chat.updated.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { offsets in
                    for i in offsets {
                        if selected == store.chats[i].id { selected = nil }
                        store.delete(store.chats[i])
                    }
                }
            }
            .overlay {
                if store.chats.isEmpty { ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right") }
            }
            .phonePage()
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The composer, the only glass on the page: the field and the accent send button in one capsule.
struct ChatComposer: View {
    @Binding var text: String
    let prompt: String
    var focused: FocusState<Bool>.Binding
    var disabled = false
    let send: () -> Void

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: Space.s) {
            // Return adds a line in this field, so the keyboard needs its own way out.
            if focused.wrappedValue {
                Button { focused.wrappedValue = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down").font(.body)
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .padding([.leading, .vertical], 6)
                .padding(.trailing, -10)
                .accessibilityLabel("Hide keyboard")
                .transition(.opacity)
            }
            TextField(prompt, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .textRole(.body)
                .focused(focused)
                .padding(.leading, 18).padding(.vertical, 12)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.body.weight(.semibold))
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 36, height: 36)
                    .background(Palette.accentFill.opacity(empty || disabled ? 0.45 : 1), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(empty || disabled)
            .padding(6)
            .accessibilityLabel("Send")
        }
        .mossadGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
        .animation(.snappy, value: focused.wrappedValue)
    }
}

extension View {
    /// A tap on the page, outside the composer, puts the keyboard away. Buttons and links in the page still win.
    func dismissesKeyboard(_ focused: FocusState<Bool>.Binding) -> some View {
        contentShape(Rectangle()).onTapGesture { focused.wrappedValue = false }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showSteps = false

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .textRole(.body)
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.accentFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 44)
                .textSelection(.enabled)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !message.steps.isEmpty {
                    Button { withAnimation { showSteps.toggle() } } label: {
                        Label("\(message.steps.count) \(message.steps.count == 1 ? "lookup" : "lookups")",
                              systemImage: showSteps ? "chevron.down" : "chevron.right")
                            .textRole(.secondary).foregroundStyle(Palette.tertiary)
                    }
                    .buttonStyle(.plain)
                    if showSteps {
                        ForEach(Array(message.steps.enumerated()), id: \.offset) { _, s in
                            Text(s).textRole(.secondary).foregroundStyle(Palette.tertiary).padding(.leading, 18)
                        }
                    }
                }
                ChatMarkdown(text: message.text, timeChips: true)
                    .foregroundStyle(Palette.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}
