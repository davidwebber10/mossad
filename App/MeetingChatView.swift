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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var messages: [ChatMessage] { chat?.messages ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LabelColumnStack(spacing: Space.m) {
                    if messages.isEmpty && !running { welcome }
                    ForEach(messages) { m in
                        ChatExchangeRow(message: m).id(m.id)
                    }
                    if running {
                        LabelColumn(label: "Answer") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                                    Label(s, systemImage: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                }
                                Text("Thinking…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                                    .phaseAnimator(reduceMotion ? [1] : [0.45, 1]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.8) }
                            }
                        }
                        .id("running")
                    }
                    if let error {
                        LabelColumn(label: "") { ErrorCard(error: error, retry: error.canRetry ? { retry() } : nil) }
                    }
                    // Questions not asked yet, under the last answer, as the canvas shows them.
                    if !messages.isEmpty, !running, !followUps.isEmpty {
                        LabelColumn(label: "") { chips(followUps) }
                    }
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
            return controller.openLink(url) ? .handled : .systemAction
        })
        .onAppear(perform: load)
        .onChange(of: record.id) { _, _ in load() }
        .onChange(of: controller.chatsVersion) { _, _ in if !running { load() } }
    }

    private var welcome: some View {
        LabelColumn(label: "Ask") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ask about this meeting").font(.system(size: 16, weight: .medium))
                Text("Claude reads this meeting's summary and transcript, and can look at your other meetings when that helps. Times in the answer play the moment.")
                    .font(.system(size: 13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                chips(examples).padding(.top, 4)
            }
        }
    }

    /// Wraps instead of cutting the questions short in a narrow detail pane.
    private func chips(_ questions: [String]) -> some View {
        FlowLayout(spacing: Space.s) {
            ForEach(questions, id: \.self) { e in
                Button { question = e; send() } label: {
                    Text(e).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
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
        Task {
            do {
                let answer = try await controller.chatAnswer(q, history: history, about: record.id, onStep: sink.add)
                current.messages.append(ChatMessage(role: .assistant, text: answer, steps: steps))
                current.updated = Date()
                save(current)
                controller.summarizeChat(current.id)
                controller.syncNow()
            } catch {
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

/// "You asked" with the question as a lede, or "Answer" with the reply and its lookups.
struct ChatExchangeRow: View {
    let message: ChatMessage
    @State private var showSteps = false

    var body: some View {
        switch message.role {
        case .user:
            LabelColumn(label: "You asked") {
                Text(message.text).font(.system(size: 16, weight: .medium)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.top, Space.s)
        case .assistant:
            LabelColumn(label: "Answer") {
                VStack(alignment: .leading, spacing: 8) {
                    ChatMarkdown(text: message.text, bodyFont: .system(size: 13), timeChips: true)
                        .lineSpacing(2)
                        .foregroundStyle(Palette.ink)
                        .frame(maxWidth: 680, alignment: .leading)
                    if !message.steps.isEmpty {
                        Button { showSteps.toggle() } label: {
                            Label("\(message.steps.count) \(message.steps.count == 1 ? "lookup" : "lookups")",
                                  systemImage: showSteps ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                        }
                        .buttonStyle(.plain)
                        if showSteps {
                            ForEach(Array(message.steps.enumerated()), id: \.offset) { _, s in
                                Text(s).font(.system(size: 11)).foregroundStyle(Palette.tertiary).padding(.leading, 16)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
            }
        }
    }
}
