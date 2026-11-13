import MossadCore
import SwiftUI

/// One chat while the app runs: the chat, and the answer on its way with its lookups and the text so far. The
/// chat of a call that records (`callID`) is answered from the live transcript; the quick panel's chat with no call
/// (`callID` nil) is a normal chat about all meetings. It lives on the controller, so a change of tab, or the quick
/// panel and the window showing the same chat, neither hides an answer nor lets a second question run beside it.
@MainActor
final class ChatSession: ObservableObject {
    let callID: String?
    @Published private(set) var chat: Chat?
    @Published private(set) var running = false
    @Published private(set) var steps: [String] = []
    @Published private(set) var partial = ""
    @Published var error: FriendlyError?
    /// A question typed while an answer comes: it is asked when that answer is in.
    @Published private(set) var queued: String?
    private var loaded = false
    private var pendingText: String?
    private var textScheduled = false
    private var task: Task<Void, Never>?
    private var stopped = false

    init(callID: String?) {
        self.callID = callID
    }

    var isQuick: Bool { callID == nil }

    /// The newest chat about this call, read off the main thread once.
    func load(_ store: ChatStore) {
        guard !loaded, let id = callID else { return }
        loaded = true
        Task {
            let found = await Task.detached(priority: .utility) { store.all().first { $0.callID == id } }.value
            if chat == nil { chat = found }
        }
    }

    /// The quick chat to continue, or none for a new one. Not while an answer comes: it saves its own copy.
    func adopt(_ found: Chat?) {
        guard !running else { return }
        chat = found
    }

    func newChat() {
        guard !running else { return }
        chat = nil
        error = nil
        queued = nil
    }

    /// Asks a question. While an answer comes, the question waits for it (only the newest one waits).
    func send(_ question: String, record: CallRecord?, controller: AppController) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard !running else { queued = q; return }
        guard isQuick || record != nil else { return }
        var current = chat ?? {
            var c = Chat(title: Chat.title(from: q))
            c.callID = callID
            return c
        }()
        let history = current.messages
        var asked = ChatMessage(role: .user, text: q)
        asked.asked = Date()
        current.messages.append(asked)
        current.updated = Date()
        save(current, controller)
        error = nil
        steps = []
        partial = ""
        running = true
        stopped = false
        let stepSink = StepSink { [weak self] step in Task { @MainActor in self?.steps.append(step) } }
        let textSink = StepSink { [weak self] text in Task { @MainActor in self?.setPartial(text) } }
        task = Task {
            do {
                let answer: String
                if let record {
                    answer = try await controller.liveChatAnswer(q, history: history, record: record, onStep: stepSink.add, onText: textSink.add)
                } else {
                    answer = try await controller.chatAnswer(q, history: history, onStep: stepSink.add)
                }
                guard !stopped else { throw CancellationError() }
                var message = ChatMessage(role: .assistant, text: answer, steps: steps)
                if record != nil { message.live = true }
                current.messages.append(message)
                current.updated = Date()
                save(current, controller)
                if record != nil {
                    controller.liveChatsToSummarize.insert(current.id)
                } else {
                    controller.summarizeChat(current.id)
                    controller.syncNow()
                }
                AccessibilityNotification.Announcement("Answer ready").post()
            } catch {
                if stopped {
                    // A stopped answer leaves no question without its answer.
                    if current.messages.last?.id == asked.id { current.messages.removeLast() }
                    save(current, controller)
                } else {
                    Log.error("\(record == nil ? "Quick chat" : "Live chat") failed: \(error)")
                    let friendly = FriendlyError(error, context: .chatting)
                    if friendly.shouldShow(failures: 1) { self.error = friendly }
                }
            }
            running = false
            partial = ""
            pendingText = nil
            task = nil
            if let next = queued {
                queued = nil
                send(next, record: record, controller: controller)
            }
        }
    }

    /// A preview's answer on its way, with nothing sent or saved.
    func showAnswering(_ question: String) {
        var c = chat ?? Chat(title: Chat.title(from: question))
        c.messages.append(ChatMessage(role: .user, text: question))
        chat = c
        running = true
    }

    /// Stops the answer on its way. The question goes with it; one that waits is asked next.
    func stop() {
        guard running else { return }
        stopped = true
        task?.cancel()
    }

    /// Asks the last question again: it leaves the chat and goes back through send.
    func retry(record: CallRecord?, controller: AppController) {
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
        if isQuick { controller.rememberQuickChat(c.id) }
        controller.chatsVersion += 1
    }
}
