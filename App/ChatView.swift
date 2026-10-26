import MossadCore
import SwiftUI

/// Starts a new chat from the Meetings pane. ⌘K.
struct AskButton: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Button { controller.startChat() } label: { Label("Ask", systemImage: "sparkles") }
        .keyboardShortcut("k", modifiers: .command)
        .help("Ask your meetings (⌘K)")
        .accessibilityLabel("Ask your meetings")
    }
}

/// Chats with Claude over every meeting: the saved chats on the left, the open chat on the right. Links in the
/// answers open the meeting at that moment.
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

    var body: some View {
        HStack(spacing: 0) {
            chatList.frame(width: 260)
            Divider()
            conversation.frame(maxWidth: .infinity)
        }
        .background(Theme.background)
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
    }

    // MARK: List

    private var chatList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(chats) { chat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title).lineLimit(1)
                        Text(shortTime(chat.updated)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(chat.id)
                    .contextMenu {
                        Button("Delete chat", role: .destructive) { delete(chat) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if chats.isEmpty {
                    Text("Your chats show here.").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if current.messages.isEmpty && running == nil { welcome }
                        ForEach(current.messages) { message in
                            MessageView(message: message).id(message.id)
                        }
                        if running == current.id {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                                    Label(s, systemImage: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(steps.isEmpty ? "Thinking" : "Reading").font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            }
                            .id("running")
                        }
                        if let error {
                            Text(error).font(.system(size: 13)).foregroundStyle(Theme.recording)
                        }
                    }
                    .padding(.horizontal, 32).padding(.vertical, 24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: current.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(current.messages.last?.id, anchor: .top) }
                }
                .onChange(of: steps.count) { _, _ in withAnimation { proxy.scrollTo("running", anchor: .bottom) } }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom) {
            composer
                .padding(.horizontal, 32).padding(.bottom, 18).padding(.top, 8)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
        }
        .environment(\.openURL, OpenURLAction { url in controller.openLink(url) ? .handled : .systemAction })
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(Color.accentColor)
            Text("Ask about your meetings").font(.system(size: 22, weight: .bold)).kerning(-0.3)
            Text("Claude searches every call: who said what, what people agreed to and by when, what was decided, and which meetings covered a topic. Answers link to the meetings and the moments.")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.self) { e in
                    Button { question = e; send() } label: {
                        Text(e).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
        }
        .padding(.top, 40)
    }

    private var examples: [String] {
        let person = controller.meetings.lazy.compactMap { r in
            r.speakerNames.values.first { $0 != controller.ownerName && !$0.hasPrefix("Speaker ") }
        }.first.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? "the team"
        return [
            "What did \(person) and I agree to last call, and was there a deadline?",
            "Which meetings this month were about the budget?",
            "What do I owe people from this week's meetings?",
            "Summarize everything decided about Databricks.",
        ]
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(current.messages.isEmpty ? "Ask about your meetings" : "Ask a follow-up", text: $question, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send")
        }
        .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 3)
        .onAppear { focused = true }
    }

    private var canSend: Bool { !question.trimmingCharacters(in: .whitespaces).isEmpty && running == nil }

    // MARK: Actions

    private func reload() {
        chats = controller.chats.all()
        // Development hook: `--open-latest-chat`.
        if selection == nil, CommandLine.arguments.contains("--open-latest-chat") { selection = chats.first?.id }
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
                let answer = try await controller.chatAnswer(q, history: history, onStep: collector.add)
                chat.messages.append(ChatMessage(role: .assistant, text: answer, steps: steps))
                chat.updated = Date()
                store(chat)
                controller.summarizeChat(chat.id)
                controller.syncToICloud()
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

private final class StepSink: Sendable {
    let add: @Sendable (String) -> Void
    init(_ add: @escaping @Sendable (String) -> Void) { self.add = add }
}

private struct MessageView: View {
    let message: ChatMessage
    @State private var showSteps = false

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 80)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.steps.isEmpty {
                    Button { showSteps.toggle() } label: {
                        Label("\(message.steps.count) \(message.steps.count == 1 ? "lookup" : "lookups")",
                              systemImage: showSteps ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    if showSteps {
                        ForEach(Array(message.steps.enumerated()), id: \.offset) { _, s in
                            Text(s).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 16)
                        }
                    }
                }
                ChatMarkdown(text: message.text, bodyFont: .system(size: 14))
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}
