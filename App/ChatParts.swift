import MossadCore
import SwiftUI

/// The parts of a chat thread on the Mac, shared by the Chat page, a meeting's Chat tab, and the live call's chat:
/// the owner's question as a bubble on the right in the accent, the answer on the left at the column's width.
enum ChatThread {
    /// The widest a question bubble gets.
    static let bubbleMax: CGFloat = 520
    /// The measure of an answer.
    static let answerMax: CGFloat = 720
    static let bodyFont = Font.system(size: 13.5)
}

/// One message: a question bubble, or an answer with its lookups.
struct ChatExchangeRow: View {
    let message: ChatMessage
    /// The meeting the chat is about, so a bare time in an answer is a chip too.
    var callID: String?

    var body: some View {
        switch message.role {
        case .user: ChatQuestionBubble(text: message.text).padding(.top, Space.s)
        case .assistant: ChatAnswer(text: message.text, steps: message.steps, callID: callID)
        }
    }
}

struct ChatQuestionBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 80)
            Text(text)
                .font(ChatThread.bodyFont).lineSpacing(3)
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Palette.accentFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: ChatThread.bubbleMax, alignment: .trailing)
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
    @State private var showSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChatMarkdown(text: text, bodyFont: ChatThread.bodyFont, timeChips: true, callID: callID)
                .foregroundStyle(Palette.ink)
            if !steps.isEmpty {
                Button { withAnimation(.snappy(duration: 0.2)) { showSteps.toggle() } } label: {
                    Label("\(steps.count) \(steps.count == 1 ? "lookup" : "lookups")", systemImage: showSteps ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11)).foregroundStyle(Palette.tertiary)
                }
                .buttonStyle(.plain)
                if showSteps {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        Text(s).font(.system(size: 11)).foregroundStyle(Palette.tertiary).padding(.leading, 16)
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
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                Label(s, systemImage: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            if partial.isEmpty {
                Text(steps.isEmpty ? waiting : "Reading…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
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
