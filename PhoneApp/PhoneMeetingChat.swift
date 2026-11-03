import MossadCore
import SwiftUI

/// The Chat tab of one meeting on the phone: the latest chat about it, saved with the other chats.
struct PhoneMeetingChat: View {
    @EnvironmentObject var store: PhoneStore
    let record: CallRecord
    @State private var chatID: UUID?
    @State private var fresh = false
    @State private var question = ""
    @State private var running = false
    @State private var steps: [String] = []
    @State private var error: String?

    private var chat: Chat? {
        if let chatID { return store.chats.first { $0.id == chatID } }
        return fresh ? nil : store.chats.first { $0.callID == record.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let chat {
                ForEach(chat.messages) { MessageBubble(message: $0) }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ask about this meeting").font(.headline)
                    ForEach(examples, id: \.self) { e in
                        Button { question = e; send() } label: {
                            Text(e).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if running {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(steps.last ?? "Thinking…").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let error { Label(error, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.red) }
            HStack(alignment: .bottom, spacing: 8) {
                if chat != nil {
                    Button { chatID = nil; fresh = true } label: { Image(systemName: "square.and.pencil").frame(width: 30, height: 30) }
                        .accessibilityLabel("New chat")
                }
                TextField(chat == nil ? "Ask about this meeting" : "Ask a follow-up", text: $question, axis: .vertical)
                    .lineLimit(1...6)
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
        error = nil
        steps = []
        running = true
        let sink = StepSink { step in Task { @MainActor in steps.append(step) } }
        Task {
            do {
                let answer = try await store.answer(q, history: history, about: record.id, onStep: sink.add)
                var latest = store.chats.first { $0.id == current.id } ?? current
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
