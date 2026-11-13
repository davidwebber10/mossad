import MossadCore
import SwiftUI

/// The parts of a chat thread on the Mac, shared by the Chat page, a meeting's Chat tab, and the live call's chat:
/// the owner's question as a bubble on the right in the accent, the answer on the left at the column's width.
enum ChatThread {
    /// The widest a question bubble gets.
    static let bubbleMax: CGFloat = 520
    /// The measure of an answer.
    static let answerMax = Rhythm.measure
    static let bodyFont = Rhythm.reading
    /// The bubble: the accent text color in light mode, where the fill color is too light for white text.
    static let bubbleFill = Color(light: 0xA84D14, dark: 0xE8964E)

    /// The links an answer may open outside Mossad. An answer can quote an invite from outside, so no other scheme.
    static func opens(_ url: URL) -> Bool {
        ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }
}

extension EnvironmentValues {
    /// The quick panel's sizes: a smaller bubble, no extra room before a question, and no note on live answers
    /// (every answer there is from the call).
    @Entry var chatCompact = false
}

/// One message: a question bubble, or an answer with its lookups and what it did.
struct ChatExchangeRow: View {
    let message: ChatMessage
    /// The meeting the chat is about, so a bare time in an answer is a chip too.
    var callID: String?
    /// The chat the message is in, for a card's click and a receipt's Undo.
    var chatID: UUID?
    @Environment(\.chatCompact) private var compact

    var body: some View {
        switch message.role {
        case .user: ChatQuestionBubble(text: message.text).padding(.top, compact ? 0 : Space.l)
        case .assistant:
            VStack(alignment: .leading, spacing: compact ? Rhythm.itemGap : Rhythm.rowGap) {
                ChatAnswer(text: message.text, steps: message.steps, callID: callID, live: message.live == true)
                if let actions = message.actions, !actions.isEmpty, let chatID {
                    ChatActionRows(actions: actions, chatID: chatID, messageID: message.id)
                }
            }
        }
    }
}

/// What an answer did and proposes: a receipt for each done action (what, where, Undo while it holds), and a card
/// for each one that waits ("Do it", "Not now"). The quick panel shows each in one line.
struct ChatActionRows: View {
    @EnvironmentObject var controller: AppController
    let actions: [ChatActionRecord]
    let chatID: UUID
    let messageID: UUID
    @Environment(\.chatCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : Rhythm.itemGap) {
            ForEach(actions) { a in
                if a.state == .proposed { card(a) } else { receipt(a) }
            }
        }
        .frame(maxWidth: ChatThread.answerMax, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func receipt(_ a: ChatActionRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Rhythm.itemGap) {
            Image(systemName: icon(a.state)).font(.system(size: 11, weight: .semibold)).foregroundStyle(a.state == .done ? Palette.okText : Palette.tertiary)
            Text(words(a)).font(Rhythm.secondary).foregroundStyle(a.state == .done ? Palette.ink : Palette.secondary)
                .strikethrough(a.state == .undone).lineLimit(compact ? 1 : 3).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let place = a.place.flatMap(URL.init(string:)), a.state != .undone {
                Button("Open") { _ = controller.openLink(place) }.buttonStyle(SettingsTextButtonStyle(color: Palette.accent))
            }
            if a.state == .done, a.undo != nil {
                Button("Undo") { controller.undoChatAction(chatID: chatID, messageID: messageID, actionID: a.id) }
                    .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .semibold))
                    .accessibilityLabel("Undo: \(a.summary)")
            }
        }
        .frame(minHeight: compact ? AskPanelSizing.actionRow : nil)
        .accessibilityElement(children: .contain)
    }

    private func card(_ a: ChatActionRecord) -> some View {
        let live = controller.isRecording && a.request.kind.needsClick && a.request.kind != .batch
        return VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            if !compact { Text("Waiting for you").font(.system(size: Rhythm.noteSize, weight: .medium)).foregroundStyle(Palette.tertiary) }
            HStack(alignment: .firstTextBaseline, spacing: Rhythm.itemGap) {
                Text(a.summary).font(Rhythm.secondary).foregroundStyle(Palette.ink)
                    .lineLimit(compact ? 1 : 4).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                Button("Not now") { controller.answerActionCard(chatID: chatID, messageID: messageID, actionID: a.id, doIt: false) }
                    .buttonStyle(SettingsTextButtonStyle())
                Button("Do it") { controller.answerActionCard(chatID: chatID, messageID: messageID, actionID: a.id, doIt: true) }
                    .buttonStyle(SettingsTextButtonStyle(color: Palette.accent, weight: .semibold))
                    .disabled(live)
                    .help(live ? "After the call" : a.summary)
            }
        }
        .padding(.horizontal, compact ? 0 : Rhythm.listRowPadding).padding(.vertical, compact ? 0 : Rhythm.itemGap)
        .frame(minHeight: compact ? AskPanelSizing.actionRow : nil)
        .background { if !compact { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.fill) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting for you: \(a.summary)")
    }

    private func icon(_ s: ChatActionRecord.State) -> String {
        switch s {
        case .done: "checkmark"
        case .undone: "arrow.uturn.backward"
        case .declined, .proposed: "minus"
        case .failed: "exclamationmark"
        }
    }

    private func words(_ a: ChatActionRecord) -> String {
        switch a.state {
        case .done, .proposed: a.summary
        case .undone: "Undone: \(a.summary)"
        case .declined: "Not done: \(a.summary)"
        case .failed: "Could not do it: \(a.summary)"
        }
    }
}

struct ChatQuestionBubble: View {
    let text: String
    @Environment(\.chatCompact) private var compact

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 80)
            Text(text)
                .font(ChatThread.bodyFont).lineSpacing(compact ? 2 : Rhythm.readingLineGap)
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, compact ? 14 : 15).padding(.vertical, compact ? 9 : 10)
                .background(ChatThread.bubbleFill, in: RoundedRectangle(cornerRadius: compact ? 17 : 18, style: .continuous))
                .frame(maxWidth: compact ? 420 : ChatThread.bubbleMax, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You asked: \(text)")
    }
}

/// An answer at full column width with no bubble, and its lookups folded under a quiet line.
struct ChatAnswer: View {
    let text: String
    var steps: [String] = []
    var callID: String?
    /// Given during the call, from the live transcript.
    var live = false
    @State private var showSteps = false
    @Environment(\.chatCompact) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            ChatMarkdown(text: text, bodyFont: ChatThread.bodyFont, timeChips: true, callID: callID)
                .foregroundStyle(Palette.ink)
            if live, !compact {
                Label("Asked during the call. Names were not final.", systemImage: "waveform")
                    .font(.system(size: Rhythm.noteSize)).foregroundStyle(Palette.tertiary)
            }
            if !steps.isEmpty {
                Button { withAnimation(.snappy(duration: 0.2)) { showSteps.toggle() } } label: {
                    Label("\(steps.count) \(steps.count == 1 ? "lookup" : "lookups")", systemImage: showSteps ? "chevron.down" : "chevron.right")
                        .font(.system(size: Rhythm.noteSize)).foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain)
                if showSteps {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        Text(s).font(.system(size: Rhythm.noteSize)).foregroundStyle(Palette.tertiary).padding(.leading, 16)
                    }
                }
            }
        }
        .frame(maxWidth: ChatThread.answerMax, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// The answer on its way: the lookups as they run, then the words as they stream, in the answer's own form.
struct ChatAnswering: View {
    let steps: [String]
    var partial = ""
    var callID: String?
    var waiting = "Thinking…"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.rowGap) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                Label(s, systemImage: "magnifyingglass").font(Rhythm.secondary).foregroundStyle(Palette.secondary)
            }
            if partial.isEmpty {
                Text(steps.isEmpty ? waiting : "Reading…").font(Rhythm.secondary).foregroundStyle(Palette.secondary)
                    .phaseAnimator(reduceMotion ? [1] : [0.45, 1]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.8) }
            } else {
                ChatMarkdown(text: partial, bodyFont: ChatThread.bodyFont, timeChips: true, callID: callID)
                    .foregroundStyle(Palette.ink)
            }
        }
        .frame(maxWidth: ChatThread.answerMax, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
