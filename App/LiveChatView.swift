import MossadCore
import SwiftUI

/// The Chat tab of the call that records now: questions about what was said so far, answered from the live
/// transcript, the invite, and the owner's history. Quick questions sit over the field. The chat is saved with the
/// other chats under this meeting, so the meeting's Chat tab shows the same conversation after the call.
struct LiveChatView: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    @ObservedObject var session: ChatSession
    var top: CGFloat = 14
    /// Set by "Ask about this call…": focus the field once.
    @Binding var focusRequest: Bool
    /// Shows a moment of an answer in the live transcript.
    let showMoment: (TimeInterval) -> Void
    @State private var question = ""
    @FocusState private var focused: Bool

    private var messages: [ChatMessage] { session.chat?.messages ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    if messages.isEmpty && !session.running { welcome }
                    ForEach(messages) { m in
                        ChatExchangeRow(message: m, callID: record.id).id(m.id)
                    }
                    if session.running {
                        ChatAnswering(steps: session.steps, partial: session.partial, callID: record.id, waiting: "Reading the call…").id("running")
                    }
                    if let error = session.error {
                        ErrorCard(error: error, retry: error.canRetry ? { session.retry(record: record, controller: controller) } : nil)
                    }
                }
                // Room for the quick questions and the floating composer.
                .detailColumn(top: top, bottom: 128)
            }
            .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo(messages.last?.id, anchor: .top) } }
            .onChange(of: session.partial) { _, _ in proxy.scrollTo("running", anchor: .bottom) }
        }
        .floatingComposer(composerStack)
        .environment(\.chatMomentVerb, "Show")
        .environment(\.openURL, OpenURLAction { url in
            if let link = ChatLink.parse(url), link.callID == record.id, let at = link.at {
                showMoment(at)
                return .handled
            }
            if controller.openLink(url) { return .handled }
            return ChatThread.opens(url) ? .systemAction : .discarded
        })
        .onAppear(perform: takeFocus)
        .onChange(of: focusRequest) { _, _ in takeFocus() }
        .onChange(of: session.running) { _, running in if !running { focused = true } }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            Text("Ask about this call").font(.system(size: Rhythm.leadSize, weight: .medium))
            Text(controller.liveOffReason.map { "There is no live transcript in this call. \($0) Answers can still use the invite and your earlier meetings." }
                 ?? "Answers come from what was said so far, the invite, and your earlier meetings. Times in an answer show the moment in the live transcript.")
                .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: ChatThread.answerMax, alignment: .leading)
    }

    private var composerStack: some View {
        VStack(spacing: Rhythm.itemGap) {
            if !session.running, controller.liveOffReason == nil {
                LiveChipsRow(model: controller.live, owner: controller.ownerName, record: record,
                             invitedOthers: invitedOthers, openPoints: LivePointRules.open(controller.livePointList(), marks: controller.livePoints.marks).count,
                             recorded: { controller.liveRecorded }) { q in
                    question = ""
                    session.send(q, record: record, controller: controller)
                }
            }
            FloatingComposer(prompt: messages.isEmpty ? "Ask about this call" : "Ask a follow-up", text: $question,
                             focused: $focused, hasLeading: session.chat != nil, send: send) {
                if session.chat != nil {
                    Button { session.newChat(); focused = true } label: {
                        IconImage(.compose, size: 15).foregroundStyle(Palette.secondary)
                            .frame(width: 22, height: Detail.composerSend).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.running)
                    .help("New chat about this call")
                    .accessibilityLabel("New chat")
                }
            }
        }
    }

    private var invitedOthers: Int? {
        let n = (record.invitees ?? []).filter { $0.isSelf != true }.count
        return n > 0 ? n : nil
    }

    private func send() {
        guard !session.running else { return }
        let q = question
        question = ""
        session.send(q, record: record, controller: controller)
    }

    private func takeFocus() {
        guard focusRequest else { return }
        focusRequest = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
        }
    }
}

/// The quick questions over the field, from the live transcript. It reads the transcript once a second, not on each
/// of its four updates a second.
private struct LiveChipsRow: View {
    let model: LiveTranscriptModel
    let owner: String
    let record: CallRecord
    let invitedOthers: Int?
    let openPoints: Int
    let recorded: () -> TimeInterval
    let ask: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let entries = model.transcript.entries(owner: owner, lines: model.visibleLines)
            let open = LiveQuestions.forOwner(entries, owner: owner, now: recorded(), invitedOthers: invitedOthers,
                                              room: record.platform == .inPerson)
            let chips = LiveChips.chips(entries, owner: owner, openQuestions: open.count, openPoints: openPoints)
            if !chips.isEmpty {
                FlowLayout(spacing: Space.s) {
                    ForEach(chips) { chip in
                        Button { ask(chip.question) } label: {
                            Text(chip.label).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.ink).lineLimit(1).fixedSize()
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
}
