import MossadCore
import SwiftUI

/// One call's live chat while the app runs: the chat, and the answer on its way with its lookups and the text so far.
/// It lives on the controller, so a change of tab during an answer neither hides it nor lets a second question run
/// beside it.
@MainActor
final class LiveChatSession: ObservableObject {
    let callID: String
    @Published private(set) var chat: Chat?
    @Published private(set) var running = false
    @Published private(set) var steps: [String] = []
    @Published private(set) var partial = ""
    @Published var error: FriendlyError?
    private var loaded = false
    private var pendingText: String?
    private var textScheduled = false

    init(callID: String) {
        self.callID = callID
    }

    /// The newest chat about this call, read off the main thread once.
    func load(_ store: ChatStore) {
        guard !loaded else { return }
        loaded = true
        let id = callID
        Task {
            let found = await Task.detached(priority: .utility) { store.all().first { $0.callID == id } }.value
            if chat == nil { chat = found }
        }
    }

    func newChat() {
        guard !running else { return }
        chat = nil
        error = nil
    }

    func send(_ question: String, record: CallRecord, controller: AppController) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !running else { return }
        var current = chat ?? {
            var c = Chat(title: Chat.title(from: q))
            c.callID = callID
            return c
        }()
        let history = current.messages
        current.messages.append(ChatMessage(role: .user, text: q))
        current.updated = Date()
        save(current, controller)
        error = nil
        steps = []
        partial = ""
        running = true
        let stepSink = StepSink { [weak self] step in Task { @MainActor in self?.steps.append(step) } }
        let textSink = StepSink { [weak self] text in Task { @MainActor in self?.setPartial(text) } }
        Task {
            do {
                let answer = try await controller.liveChatAnswer(q, history: history, record: record, onStep: stepSink.add, onText: textSink.add)
                current.messages.append(ChatMessage(role: .assistant, text: answer, steps: steps))
                current.updated = Date()
                save(current, controller)
                controller.liveChatsToSummarize.insert(current.id)
                AccessibilityNotification.Announcement("Answer ready").post()
            } catch {
                Log.error("Live chat failed: \(error)")
                let friendly = FriendlyError(error, context: .chatting)
                if friendly.shouldShow(failures: 1) { self.error = friendly }
            }
            running = false
            partial = ""
            pendingText = nil
        }
    }

    /// Asks the last question again: it leaves the chat and goes back through send.
    func retry(record: CallRecord, controller: AppController) {
        guard !running, var c = chat, let last = c.messages.last, last.role == .user else { return }
        c.messages.removeLast()
        chat = c
        send(last.text, record: record, controller: controller)
    }

    /// The streamed text at most ten times a second: each change draws the whole answer again.
    private func setPartial(_ text: String) {
        guard running else { return }
        pendingText = text
        guard !textScheduled else { return }
        textScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            textScheduled = false
            if running, let pendingText { partial = pendingText }
        }
    }

    private func save(_ c: Chat, _ controller: AppController) {
        do { try controller.chats.save(c) } catch { Log.error("Saving the chat failed: \(error)") }
        chat = c
        controller.chatsVersion += 1
    }
}
