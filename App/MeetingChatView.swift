import MossadCore
import SwiftUI

/// The Chat tab of one meeting, in the label column: what you asked, then the answer, whose times are chips that
/// move the playhead. The chat is saved with the other chats, so the Chat section shows it too.
struct MeetingChatView: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    /// Room above the first question for the tabs on the band's edge.
    var top: CGFloat = 14
    /// Plays this meeting from a time in an answer.
    let seek: (TimeInterval) -> Void
    @State private var chat: Chat?
    @State private var question = ""
    @State private var running = false
    @State private var steps: [String] = []
    @State private var error: FriendlyError? = AppController.errorPreview("meetingChat")
    @FocusState private var focused: Bool

    private var messages: [ChatMessage] { chat?.messages ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if messages.isEmpty && !running { welcome }
                    ForEach(messages) { m in
                        ChatExchangeRow(message: m, callID: record.id, chatID: chat?.id).id(m.id)
                    }
                    if running { ChatAnswering(steps: steps, callID: record.id).id("running") }
                    if let error { ErrorCard(error: error, retry: error.canRetry ? { retry() } : nil) }
                    // Questions not asked yet, under the last answer.
                    if !messages.isEmpty, !running, !followUps.isEmpty { chips(followUps) }
                }
                // Room for the floating composer, as the canvas leaves 80 pt under the last answer.
                .detailColumn(top: top, bottom: 80)
            }
            .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo(messages.last?.id, anchor: .top) } }
            .onChange(of: steps.count) { _, _ in withAnimation { proxy.scrollTo("running", anchor: .bottom) } }
        }
        .floatingComposer(composer)
        .environment(\.openURL, OpenURLAction { url in
            if let link = ChatLink.parse(url), link.callID == record.id, let at = link.at {
                seek(at)
                return .handled
            }
            if controller.openLink(url) { return .handled }
            return ChatThread.opens(url) ? .systemAction : .discarded
        })
        .onAppear(perform: load)
        .onChange(of: record.id) { _, _ in load() }
        .onChange(of: controller.chatsVersion) { _, _ in if !running { load() } }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            Text("Ask about this meeting").font(.system(size: Rhythm.leadSize, weight: .medium))
            Text("Claude reads this meeting's summary and transcript, and can look at your other meetings when that helps. Times in the answer play the moment.")
                .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            chips(examples).padding(.top, 4)
        }
        .frame(maxWidth: ChatThread.answerMax, alignment: .leading)
    }

    /// Wraps instead of cutting the questions short in a narrow detail pane.
    private func chips(_ questions: [String]) -> some View {
        FlowLayout(spacing: Space.s) {
            ForEach(questions, id: \.self) { e in
                Button { question = e; send() } label: {
                    Text(e).font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Palette.fill, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var followUps: [String] {
        let asked = Set(messages.filter { $0.role == .user }.map(\.text))
        return examples.filter { !asked.contains($0) }
    }

    private let examples = [
        "What did I agree to, and by when?",
        "What did the others push back on?",
        "Write a short follow-up email from me.",
    ]

    private var composer: some View {
        FloatingComposer(prompt: messages.isEmpty ? "Ask about this meeting" : "Ask a follow-up", text: $question,
                         focused: $focused, hasLeading: chat != nil, send: send) {
            if chat != nil {
                Button(action: newChat) {
                    IconImage(.compose, size: 15).foregroundStyle(Palette.secondary)
                        .frame(width: 22, height: Detail.composerSend).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New chat about this meeting")
                .accessibilityLabel("New chat")
            }
        }
    }

    /// The newest chat about this meeting, if there is one.
    private func load() {
        chat = controller.chats.all().first { $0.callID == record.id }
    }

    private func newChat() {
        chat = nil
        error = nil
        focused = true
    }

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
        save(current)
        question = ""
        error = nil
        steps = []
        running = true
        let sink = StepSink { step in Task { @MainActor in steps.append(step) } }
        // Each receipt goes into the chat the moment its action is done; the answer joins the file's copy.
        let answerID = UUID(), asked = current, questionID = current.messages.last!.id
        let actionSink = ActionSink { r in Task { @MainActor in chat = controller.saveChatAction(r, chat: asked, answer: answerID) } }
        let earlier = controller.chatActions(current)
        Task {
            do {
                let answer = try await controller.chatAnswer(q, history: history, about: record.id, earlier: earlier, onAction: actionSink.add, onStep: sink.add)
                var message = answer.message(steps: steps)
                message.id = answerID
                save(controller.finishChatAnswer(message, chat: asked))
                controller.summarizeChat(current.id)
                if !controller.isRecording { controller.syncNow() }
            } catch {
                // What was done stays with its question.
                let stop = controller.stopChatAnswer(chat: asked, answer: answerID, question: questionID)
                if stop.kept { chat = stop.chat }
                Log.error("Chat failed: \(error)")
                let friendly = FriendlyError(error, context: .chatting)
                if friendly.shouldShow(failures: 1) { self.error = friendly }
            }
            running = false
            focused = true
        }
    }

    /// Asks the last question again: it leaves the chat and goes back through send.
    private func retry() {
        guard var c = chat, let last = c.messages.last, last.role == .user else { return }
        c.messages.removeLast()
        chat = c
        question = last.text
        send()
    }

    private func save(_ c: Chat) {
        do { try controller.chats.save(c) } catch { Log.error("Saving the chat failed: \(error)") }
        chat = c
    }
}
