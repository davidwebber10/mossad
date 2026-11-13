import AppKit
import MossadCore
import SwiftUI

/// The quick panel's content: the header, the chat (the same chat as the live Chat tab, or a quick chat about all
/// meetings with no call), the quick questions, the field, and the keys. The thread grows to `threadMax`, then
/// scrolls.
struct AskPanelView: View {
    static let width: CGFloat = 640
    static let threadMax = AskPanelSizing.threadLimit
    static let radius: CGFloat = 18
    /// The panel's edge: a little stronger than the hairlines inside it.
    static let border = Color(light: 0x1C1A17, lightAlpha: 0.12, dark: 0xFFFFFF, darkAlpha: 0.12)

    @EnvironmentObject var controller: AppController
    @ObservedObject var model: AskPanelModel
    let actions: AskPanelActions

    var body: some View {
        let mode = model.mode(controller)
        VStack(spacing: 0) {
            AskPanelHeader(model: model, mode: mode, actions: actions)
            content(mode)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(Self.border, lineWidth: 1))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { actions.height($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: mode) { _, _ in model.track(controller) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .quick ? "Ask about your meetings" : "Ask about this call")
    }

    @ViewBuilder
    private func content(_ mode: AskPanelMode) -> some View {
        switch mode {
        case .call(let id):
            AskPanelChat(session: controller.liveChatSession(id), model: model, mode: mode,
                         record: controller.meetings.first { $0.id == id }, actions: actions)
        case .quick:
            AskPanelChat(session: controller.quickChatSession(), model: model, mode: mode, record: nil, actions: actions)
        case .noTranscript(_, let reason):
            AskPanelNotice(text: reason.panelText, button: reason.fix.map { fix in (fix.label, false, { controller.openSettings(for: fix) }) })
        case .ended(let id):
            AskPanelNotice(text: "The call ended. This chat is saved with the meeting, and you can continue it there.",
                           button: ("Open the meeting", true, { controller.openAskInWindow(.ended(id)) }))
        }
    }
}

// MARK: Header

private struct AskPanelHeader: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var model: AskPanelModel
    let mode: AskPanelMode
    let actions: AskPanelActions

    var body: some View {
        HStack(spacing: 8) {
            switch mode {
            case .quick:
                Text("Mossad").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink)
            case .ended(let id):
                dot(Palette.tertiaryMark)
                title(id)
                Text("Ended, \(minutes(to: model.endedAt ?? Date())) min").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            case .call(let id), .noTranscript(let id, _):
                dot(Palette.recording)
                title(id)
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Text("\(controller.isPaused ? "Paused" : "Recording"), \(minutes(to: context.date)) min")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if mode == .quick, controller.quickChat?.chat != nil {
                HeaderButton(label: "New chat", help: "Start a new chat") {
                    IconImage(.compose, size: 15)
                } action: {
                    controller.quickChat?.newChat()
                    controller.rememberQuickChat(nil)
                    model.focusRequest += 1
                }
                .disabled(controller.quickChat?.running == true)
            }
            HeaderButton(label: "Open in the Mossad window",
                         help: "Open this chat in the Mossad window (⌘↩)") {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 13, weight: .medium))
            } action: {
                controller.openAskInWindow(mode)
            }
            HeaderButton(label: "Close", help: "Hide; the chat stays (esc)") {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
            } action: {
                actions.hide()
            }
        }
        .padding(.leading, 16).padding(.trailing, 10)
        .frame(height: 44)
        .background(PanelDragArea())
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }

    private func title(_ id: String) -> some View {
        Text(controller.meetings.first { $0.id == id }?.title ?? controller.recordingTitle ?? "This call")
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
            .accessibilityAddTraits(.isHeader)
    }

    private func minutes(to date: Date) -> Int {
        let since = model.since ?? model.recording(controller)?.since ?? date
        return max(0, Int(date.timeIntervalSince(since) / 60))
    }
}

private struct HeaderButton<Label: View>: View {
    let label: String
    let help: String
    @ViewBuilder let icon: Label
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon.foregroundStyle(Palette.secondary)
                .frame(width: 28, height: 28)
                .background(hovering ? Palette.fill : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The header moves the panel.
private struct PanelDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

// MARK: Notice

/// No live transcript, or the call ended: one sentence and one button in place of the chat.
private struct AskPanelNotice: View {
    let text: String
    /// The label, whether it is the accent, and the action.
    let button: (String, Bool, () -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            Text(text).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let button {
                Button(action: button.2) {
                    Text(button.0).font(.system(size: 13, weight: button.1 ? .semibold : .medium))
                        .foregroundStyle(button.1 ? Palette.onAccent : Palette.ink)
                        .padding(.horizontal, 14).frame(height: 30)
                        .background(button.1 ? Palette.accentFill : Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }
}

// MARK: Chat

private struct AskPanelChat: View {
    @EnvironmentObject var controller: AppController
    @ObservedObject var session: ChatSession
    @ObservedObject var model: AskPanelModel
    let mode: AskPanelMode
    let record: CallRecord?
    let actions: AskPanelActions
    @State private var threadHeight: CGFloat = 0
    /// The owner's points row as shown: the thread gives way to it (`AskPanelSizing`).
    @State private var pointsHeight: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The field's text, kept on the model by chat, so a call that starts or ends does not lose it.
    private var draftKey: String { mode.callID ?? "quick" }
    private var question: Binding<String> {
        Binding(get: { model.drafts[draftKey] ?? "" }, set: { model.drafts[draftKey] = $0 })
    }
    /// The owner shares the screen (as far as Mossad can tell): the chat is covered until they choose to see it.
    private var covered: Bool { controller.ownerSharing == true && !model.showDuringShare }

    private var messages: [ChatMessage] { session.chat?.messages ?? [] }
    private var live: Bool { mode.callID != nil }
    private var hasThread: Bool { !messages.isEmpty || session.running || session.error != nil }
    private var threadMax: CGFloat { AskPanelSizing.threadMax(points: showsPoints ? pointsHeight : 0) }
    private var scrolls: Bool { threadHeight > threadMax }
    private var showsPoints: Bool { live && !covered && record != nil }

    var body: some View {
        VStack(spacing: 0) {
            if covered {
                ShareCover { model.showDuringShare = true }
            } else if hasThread {
                thread
            }
            if showsPoints, let record {
                AskPanelPoints(model: controller.livePoints, record: record, divided: hasThread) { pointsHeight = $0 }
            }
            if live, !session.running, model.isOpen, !covered, let record {
                PanelChipsRow(model: controller.live, owner: controller.ownerName, record: record, compact: hasThread,
                              divided: scrolls && pointsHeight == 0,
                              openPoints: LivePointRules.open(controller.livePointList(), marks: controller.livePoints.marks).count,
                              messages: messages, recorded: { controller.liveRecorded }) { ask($0) }
            }
            field
            footer
        }
        .environment(\.chatCompact, true)
        .environment(\.chatMomentVerb, "Show")
        .onAppear { focusSoon() }
        .onChange(of: model.focusRequest) { _, _ in focusSoon() }
        .onChange(of: session.running) { _, running in if !running { focused = true } }
        .onChange(of: session.returned) { _, text in
            // A waiting question that was not asked comes back to the field.
            guard let text else { return }
            session.returned = nil
            if question.wrappedValue.isEmpty { question.wrappedValue = text }
        }
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        let dividers = ChatDividers.lines(messages, now: context.date)
                        VStack(alignment: .leading, spacing: Space.l) {
                            ForEach(messages) { m in
                                if let line = dividers[m.id] { AgeDivider(text: line) }
                                ChatExchangeRow(message: m, callID: mode.callID)
                                    .environment(\.openURL, OpenURLAction { open($0, in: m.id) })
                                    .environment(\.chatMomentPeek, peek(for: m.id))
                                    .id(m.id)
                            }
                        }
                    }
                    if session.running { answering.id("running") }
                    if let queued = session.queued {
                        VStack(alignment: .trailing, spacing: 4) {
                            ChatQuestionBubble(text: queued)
                            Text("Waits for this answer").font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Waits for this answer: \(queued)")
                    }
                    if let error = session.error {
                        ErrorCard(error: error, retry: error.canRetry ? { session.retry(record: record, controller: controller) } : nil)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.leading, 20).padding(.trailing, 24).padding(.top, 18).padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { threadHeight = $0 }
            }
            // The answer on its way: its times are not in a saved message yet, so they get no peek.
            .environment(\.openURL, OpenURLAction { open($0, in: nil) })
            .frame(height: min(threadHeight, threadMax))
            .scrollIndicators(scrolls ? .automatic : .never)
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.scrollRequest) { _, _ in
                Task { @MainActor in proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo(messages.last?.id, anchor: .top) } }
            .onChange(of: session.partial) { _, _ in proxy.scrollTo("running", anchor: .bottom) }
            .onChange(of: model.peek?.seconds) { _, _ in
                guard let id = model.peek?.message else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var answering: some View {
        if live, session.steps.isEmpty, session.partial.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.accent)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                Text("Listening to the call…").font(.system(size: 13)).foregroundStyle(Palette.secondary)
            }
            .accessibilityElement(children: .combine)
        } else {
            ChatAnswering(steps: session.steps, partial: session.partial, callID: mode.callID,
                          waiting: live ? "Listening to the call…" : "Thinking…")
        }
    }

    /// The live transcript under the block of the chip that was clicked, in that message only.
    private func peek(for message: UUID) -> ChatMomentPeek? {
        guard live, let p = model.peek, p.message == message else { return nil }
        return ChatMomentPeek(seconds: p.seconds, content: AnyView(
            LivePeekView(model: controller.live, at: TimeInterval(p.seconds), owner: controller.ownerName,
                         room: record?.platform == .inPerson)))
    }

    /// A time in an answer about this call opens the peek under it, and closes it on a second click. Command-click
    /// shows it in the main window. A time of another meeting, or with no call, opens that meeting there.
    private func open(_ url: URL, in message: UUID?) -> OpenURLAction.Result {
        if let link = ChatLink.parse(url), let at = link.at, live, link.callID == mode.callID {
            if NSEvent.modifierFlags.contains(.command) {
                controller.showLiveMoment(callID: link.callID, at: at)
            } else if let message {
                let seconds = Int(at)
                let closing = model.peek.map { $0.message == message && $0.seconds == seconds } == true
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                    model.peek = closing ? nil : (message, seconds)
                }
                if !closing { AccessibilityNotification.Announcement("Live transcript at \(LivePeekLine.clock(at))").post() }
            }
            return .handled
        }
        if controller.openLink(url) {
            actions.hide()
            return .handled
        }
        return ChatThread.opens(url) ? .systemAction : .discarded
    }

    // MARK: Field

    private var prompt: String {
        if session.running { return "Type your next question; it waits for this answer" }
        if !messages.isEmpty { return "Ask a follow-up…" }
        return live ? "Ask about this call…" : "Ask about your meetings…"
    }

    private var field: some View {
        HStack(spacing: 12) {
            if !session.running {
                IconImage(.sparkle, size: 20).foregroundStyle(Palette.accent)
            }
            TextField(prompt, text: question)
                .textFieldStyle(.plain)
                .font(.system(size: session.running ? 15 : 17))
                .foregroundStyle(Palette.ink)
                .focused($focused)
                .onSubmit(send)
                .accessibilityLabel(live ? "Ask about this call" : "Ask about your meetings")
            if session.running {
                Button { session.stop() } label: {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Palette.ink).frame(width: 10, height: 10)
                        .frame(width: 32, height: 32)
                        .background(Palette.fill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Stop the answer")
                .accessibilityLabel("Stop the answer")
            } else {
                Button(action: send) {
                    IconImage(.arrowUp, size: 15).foregroundStyle(Palette.onAccent)
                        .frame(width: 32, height: 32)
                        .background(Palette.accentFill, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Ask (↩)")
                .accessibilityLabel("Ask")
            }
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: session.running ? 52 : 56)
        .overlay(alignment: .top) { if session.running { Rectangle().fill(Palette.hairline).frame(height: 1) } }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            KeyHint(keys: ["↵"], label: "Ask")
            KeyHint(keys: ["⌘↵"], label: "Open in window")
            Spacer(minLength: 8)
            KeyHint(keys: (controller.activeAskShortcut.map { [$0.symbols] } ?? []) + ["esc"], label: "Hide, the chat stays")
        }
        .font(.system(size: 11.5)).foregroundStyle(Palette.secondary)
        .padding(.horizontal, 16)
        .frame(height: 32)
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 1) }
    }

    // MARK: Actions

    private func send() {
        let q = question.wrappedValue
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The first moment of a call, before its record is read: the question stays in the field.
        guard !live || record != nil else { return }
        question.wrappedValue = ""
        ask(q)
    }

    private func ask(_ q: String) {
        model.peek = nil
        session.send(q, record: record, controller: controller)
    }

    private func focusSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }
}

/// While the owner shares the screen, the chat is covered: people in the call could see it.
private struct ShareCover: View {
    let show: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text("You seem to be sharing your screen, so the chat is hidden. People in the call could see it.")
                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: show) {
                Text("Show the chat").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }
}

/// "Asked 17 minutes ago" between an older part of the chat and a newer one.
private struct AgeDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Palette.hairline).frame(height: 1)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.secondary).fixedSize()
            Rectangle().fill(Palette.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "⌥⌘M or esc Hide, the chat stays".
private struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, key in
                if i > 0 { Text("or") }
                Text(key).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Palette.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            Text(label).padding(.leading, 2)
        }
        .lineLimit(1).fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(keys.joined(separator: " or "))")
    }
}

// MARK: Quick questions

/// The live Chat tab's quick questions, at the panel's sizes. It reads the transcript once a second.
private struct PanelChipsRow: View {
    let model: LiveTranscriptModel
    let owner: String
    let record: CallRecord
    /// Under a thread: smaller chips.
    let compact: Bool
    /// Under a thread that scrolls: a hairline over them.
    let divided: Bool
    let openPoints: Int
    let messages: [ChatMessage]
    let recorded: () -> TimeInterval
    let ask: (String) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let lastAsked = AskPanelChips.recentQuestion(messages, now: context.date)
            let entries = model.transcript.entries(owner: owner, lines: model.visibleLines)
            let open = LiveQuestions.forOwner(entries, owner: owner, now: max(recorded(), entries.last?.time ?? 0), invitedOthers: invitedOthers,
                                              room: record.platform == .inPerson)
            let chips = AskPanelChips.chips(entries, owner: owner, openQuestions: open.count, openPoints: openPoints, lastAsked: lastAsked)
            if !chips.isEmpty {
                FlowLayout(spacing: Space.s) {
                    ForEach(chips) { chip in
                        Button { ask(chip.question) } label: {
                            Text(chip.label).font(.system(size: compact ? 12 : 12.5, weight: chip.accent ? .medium : .regular))
                                .foregroundStyle(chip.accent ? Palette.accent : Palette.ink)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, compact ? 11 : 12).frame(height: compact ? 26 : 28)
                                .background(chip.accent ? Palette.accentTint : Palette.fill, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(chip.question)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, divided ? 16 : compact ? 10 : 14).padding(.bottom, compact ? 2 : 4)
                .overlay(alignment: .top) { if divided { Rectangle().fill(Palette.hairline).frame(height: 1) } }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Quick questions")
            }
        }
    }

    private var invitedOthers: Int? {
        let n = (record.invitees ?? []).filter { $0.isSelf != true }.count
        return n > 0 ? n : nil
    }
}

// MARK: Peek

/// The live transcript at a moment: the line there marked, with one line before and after.
struct LivePeekView: View {
    @ObservedObject var model: LiveTranscriptModel
    let at: TimeInterval
    let owner: String
    let room: Bool

    var body: some View {
        let lines = LivePeek.lines(model.transcript, lines: model.visibleLines, at: at, owner: owner, room: room)
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text("This moment is not in the live transcript.").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 4)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(line.clock).monospacedDigit().foregroundStyle(line.marked ? Palette.accent : Palette.secondary)
                        .frame(width: 40, alignment: .leading)
                    Text("\(Text(line.name).fontWeight(.semibold)) \(line.text)")
                        .foregroundStyle(line.marked ? Palette.ink : Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 13)).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, line.marked ? 6 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(line.marked ? Palette.accent.opacity(0.12) : .clear)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live transcript at \(LivePeekLine.clock(at))")
    }
}
