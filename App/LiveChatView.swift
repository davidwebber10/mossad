import MossadCore
import SwiftUI

/// The Chat tab of the call that records now: questions about what was said so far, answered from the live
/// transcript, the invite, and the owner's history. Quick questions sit over the field. The chat is saved with the
/// other chats under this meeting, so the meeting's Chat tab shows the same conversation after the call.
struct LiveChatView: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    var top: CGFloat = 14
    /// Set by "Ask about this call…": focus the field once.
    @Binding var focusRequest: Bool
    /// Shows a moment of an answer in the live transcript.
    let showMoment: (TimeInterval) -> Void
    @State private var chat: Chat?
    @State private var question = ""
    @State private var running = false
    @State private var steps: [String] = []
    @State private var partial = ""
    @State private var error: FriendlyError?
    @FocusState private var focused: Bool

    private var messages: [ChatMessage] { chat?.messages ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if messages.isEmpty && !running { welcome }
                    ForEach(messages) { m in
                        ChatExchangeRow(message: m, callID: record.id).id(m.id)
                    }
                    if running { ChatAnswering(steps: steps, partial: partial, callID: record.id, waiting: "Reading the call…").id("running") }
                    if let error { ErrorCard(error: error, retry: error.canRetry ? { retry() } : nil) }
                }
                // Room for the quick questions and the floating composer.
                .detailColumn(top: top, bottom: 128)
            }
            .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo(messages.last?.id, anchor: .top) } }
            .onChange(of: partial) { _, _ in proxy.scrollTo("running", anchor: .bottom) }
        }
        .floatingComposer(composerStack)
        .environment(\.openURL, OpenURLAction { url in
            if let link = ChatLink.parse(url), link.callID == record.id, let at = link.at {
                showMoment(at)
                return .handled
            }
            return controller.openLink(url) ? .handled : .systemAction
        })
        .onAppear {
            load()
            takeFocus()
        }
        .onChange(of: focusRequest) { _, _ in takeFocus() }
        .onChange(of: controller.chatsVersion) { _, _ in if !running { load() } }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this call").font(.system(size: 16, weight: .medium))
            Text("Answers come from what was said so far, the invite, and your earlier meetings. Times in an answer show the moment in the live transcript.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: ChatThread.answerMax, alignment: .leading)
    }

    private var composerStack: some View {
        VStack(spacing: 8) {
            if !running {
                LiveChipsRow(model: controller.live, owner: controller.ownerName, start: record.start) { q in
                    question = q
                    send()
                }
            }
            FloatingComposer(prompt: messages.isEmpty ? "Ask about this call" : "Ask a follow-up", text: $question,
                             focused: $focused, hasLeading: chat != nil, send: send) {
                if chat != nil {
                    Button(action: newChat) {
                        IconImage(.compose, size: 15).foregroundStyle(Palette.secondary)
                            .frame(width: 22, height: Detail.composerSend).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New chat about this call")
                    .accessibilityLabel("New chat")
                }
            }
        }
    }

    private func takeFocus() {
        guard focusRequest else { return }
        focusRequest = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
        }
    }

    /// The newest chat about this call, if there is one.
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
        partial = ""
        running = true
        let stepSink = StepSink { step in Task { @MainActor in steps.append(step) } }
        let textSink = StepSink { text in Task { @MainActor in if running { partial = text } } }
        Task {
            do {
                let answer = try await controller.liveChatAnswer(q, history: history, record: record, onStep: stepSink.add, onText: textSink.add)
                current.messages.append(ChatMessage(role: .assistant, text: answer, steps: steps))
                current.updated = Date()
                save(current)
                controller.liveChatsToSummarize.insert(current.id)
            } catch {
                Log.error("Live chat failed: \(error)")
                let friendly = FriendlyError(error, context: .chatting)
                if friendly.shouldShow(failures: 1) { self.error = friendly }
            }
            running = false
            partial = ""
            focused = true
        }
    }

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

/// The quick questions over the field, from the live transcript. Its own view, so only this row follows the
/// transcript's updates.
private struct LiveChipsRow: View {
    @ObservedObject var model: LiveTranscriptModel
    let owner: String
    let start: Date
    let ask: (String) -> Void

    var body: some View {
        let entries = model.transcript.entries(owner: owner, lines: model.visibleLines)
        let open = LiveQuestions.forOwner(entries, owner: owner, now: Date().timeIntervalSince(start))
        let chips = LiveChips.chips(entries, owner: owner, openQuestions: open.count)
        if !chips.isEmpty {
            FlowLayout(spacing: Space.s) {
                ForEach(chips) { chip in
                    Button { ask(chip.question) } label: {
                        Text(chip.label).font(.system(size: 12)).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
                            .padding(.horizontal, 11).frame(height: 26)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(chip.question)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick questions")
        }
    }
}
