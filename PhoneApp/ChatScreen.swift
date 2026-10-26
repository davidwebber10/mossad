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
            .safeAreaBar(edge: .bottom) { composer }
            .toolbar { toolbar }
            .navigationTitle(chat.messages.isEmpty ? "" : chat.title)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showChats) { ChatList(selected: $chatID, onPick: { showChats = false }) }
            .sheet(isPresented: $showMemory) { CoachMemoryView() }
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
            Button("Chats", systemImage: "clock.arrow.circlepath") { showChats = true }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Memory", systemImage: "brain") { showMemory = true }
            Button("New chat", systemImage: "square.and.pencil") { newChat() }.disabled(running)
        }
    }

    private var conversation: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.messages) { MessageBubble(message: $0).id($0.id) }
                    if running { thinking.id("thinking") }
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red)
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
            ProgressView()
            Text(steps.last ?? "Thinking…").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                .contentTransition(.opacity)
        }
        .animation(.default, value: steps.count)
    }

    private var composer: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Mossad", text: $question, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                Button { send() } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || running)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
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
                let answer = try await store.answer(q, history: history, onStep: sink.add)
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

private final class StepSink: Sendable {
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
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showSteps = false

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.16), in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 48)
                .textSelection(.enabled)
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if !message.steps.isEmpty {
                    Button { withAnimation { showSteps.toggle() } } label: {
                        Label("\(message.steps.count) \(message.steps.count == 1 ? "lookup" : "lookups")",
                              systemImage: showSteps ? "chevron.down" : "chevron.right")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    if showSteps {
                        ForEach(Array(message.steps.enumerated()), id: \.offset) { _, s in
                            Text(s).font(.caption).foregroundStyle(.tertiary).padding(.leading, 18)
                        }
                    }
                }
                ChatMarkdown(text: message.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}
