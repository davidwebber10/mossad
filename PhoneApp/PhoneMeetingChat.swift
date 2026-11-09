import MossadCore
import SwiftUI

/// The Chat tab of one meeting on the phone: the latest chat about it, saved with the other chats.
struct PhoneMeetingChat: View {
    @Environment(PhoneStore.self) private var store
    let record: CallRecord
    @State private var chatID: UUID?
    @State private var fresh = false
    @State private var question = ""
    @FocusState private var focused: Bool

    /// The question that runs and its error live in the store, so they outlive this section of the meeting.
    private var run: ChatRun { store.chatRun(record.id) }
    private var running: Bool { run.running }

    private var chat: Chat? {
        if let chatID { return store.chats.first { $0.id == chatID } }
        return fresh ? nil : store.chats.first { $0.callID == record.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let chat {
                ForEach(chat.messages) { MessageBubble(message: $0) }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    PhoneLabel("Ask about this meeting")
                    ExampleQuestions(questions: examples) { question = $0; send() }
                }
            }
            if running {
                HStack(spacing: 10) {
                    PhoneProcessingMark()
                    Text(run.steps.last ?? "Thinking…").textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(1)
                }
            }
            if let error = run.error { ErrorCard(error: error, retry: error.canRetry ? { retry() } : nil) }
            HStack(alignment: .bottom, spacing: Space.s) {
                if chat != nil {
                    Button { chatID = nil; fresh = true } label: {
                        Image(systemName: "square.and.pencil").foregroundStyle(Palette.ink).frame(width: 44, height: 44)
                    }
                    .mossadGlass(in: Circle(), interactive: true)
                    .accessibilityLabel("New chat")
                }
                ChatComposer(text: $question, prompt: chat == nil ? "Ask about this meeting" : "Ask a follow-up",
                             focused: $focused, disabled: running) { send() }
            }
        }
        .dismissesKeyboard($focused)
    }

    private let examples = [
        "What did I agree to, and by when?",
        "What did the others push back on?",
        "Write a short follow-up email from me.",
    ]

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        var current = chat ?? {
            var c = Chat(title: Chat.title(from: q))
            c.callID = record.id
            return c
        }()
        let history = current.messages
        current.messages.append(ChatMessage(role: .user, text: q))
        current.updated = Date()
        store.save(current)
        chatID = current.id
        fresh = false
        question = ""
        let run = run, store = store, callID = record.id
        run.error = nil
        run.steps = []
        run.running = true
        let sink = StepSink { step in Task { @MainActor in run.steps.append(step) } }
        Task {
            do {
                let answer = try await store.answer(q, history: history, about: callID, onStep: { sink.add($0) })
                var latest = store.chats.first { $0.id == current.id } ?? current
                latest.messages.append(ChatMessage(role: .assistant, text: answer, steps: sink.all))
                latest.updated = Date()
                store.save(latest)
                store.finish(latest.id)
            } catch {
                Log.error("Chat failed: \(error)")
                let friendly = FriendlyError(error, context: .chatting)
                if friendly.shouldShow(failures: 1) { run.error = friendly }
            }
            run.running = false
        }
    }

    /// Asks the last question again: it leaves the chat and goes back through send.
    private func retry() {
        guard var c = chat, let last = c.messages.last, last.role == .user else { return }
        c.messages.removeLast()
        store.save(c)
        question = last.text
        send()
    }
}
