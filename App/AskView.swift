import MossadCore
import SwiftUI

/// Opens the Ask sheet. ⌘K from the Meetings pane.
struct AskButton: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Button { controller.askOpen = true } label: {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help("Ask your meetings (⌘K)")
        .accessibilityLabel("Ask your meetings")
    }
}

/// A chat about all your meetings. Claude answers from the meetings the question points to (by the people,
/// the dates, or the words in it), and links each answer to the meetings and moments it comes from.
struct AskView: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var turns: [Exchange] = []
    @State private var asking = false
    @FocusState private var focused: Bool

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: MeetingQA.Answer?
        var error: String?
    }

    private let examples = [
        "What did Mitch and I agree to last call, and was there a deadline?",
        "Which meetings this month talked about the budget?",
        "What do I owe people from this week?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Ask your meetings", systemImage: "sparkles").font(.system(size: 14, weight: .semibold))
                Spacer()
                if !turns.isEmpty { Button("New chat") { turns = []; focused = true }.controlSize(.small) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if turns.isEmpty { suggestions }
                        ForEach(turns) { exchange in
                            ExchangeView(exchange: exchange, close: { dismiss() }).id(exchange.id)
                        }
                        if asking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading your meetings").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .id("asking")
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: turns.count) { _, _ in withAnimation { proxy.scrollTo(turns.last?.id, anchor: .top) } }
            }
            Divider()
            HStack(spacing: 10) {
                TextField(turns.isEmpty ? "Ask about your meetings" : "Ask a follow-up", text: $question, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(question.trimmingCharacters(in: .whitespaces).isEmpty || asking ? Color.secondary : Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking)
                .accessibilityLabel("Ask")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(14)
        }
        .frame(width: 680, height: 600)
        .onAppear { focused = true }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about what people said, agreed to, or decided, or find meetings by person, topic, or date.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(examples, id: \.self) { e in
                Button(e) { question = e; send() }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
            }
        }
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        let history = turns.compactMap { t in t.answer.map { MeetingQA.Turn(question: t.question, answer: $0.text) } }
        turns.append(Exchange(question: q))
        question = ""
        asking = true
        let index = turns.count - 1
        Task {
            do { turns[index].answer = try await controller.ask(q, history: history) } catch { turns[index].error = "\(error)" }
            asking = false
            focused = true
        }
    }
}

private struct ExchangeView: View {
    @EnvironmentObject var controller: AppController
    let exchange: AskView.Exchange
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(exchange.question)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
            if let error = exchange.error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.recording)
            }
            if let answer = exchange.answer {
                Text((try? AttributedString(markdown: answer.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer.text))
                    .font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                let meetings = answer.meetings.compactMap { id in controller.meetings.first { $0.id == id } }
                if !meetings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MEETINGS").font(.system(size: 10, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary)
                        ForEach(meetings, id: \.id) { r in
                            Button { close(); controller.openMeeting(r.id) } label: {
                                HStack(spacing: 8) {
                                    PlatformSquare(platform: r.platform, size: 12)
                                    Text(r.title).fontWeight(.medium).lineLimit(1)
                                    Text("\(shortTime(r.start)) · \(r.lengthText)").foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !answer.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SOURCES").font(.system(size: 10, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary)
                        ForEach(Array(answer.citations.enumerated()), id: \.offset) { _, c in citation(c) }
                    }
                }
            }
        }
    }

    private func citation(_ c: MeetingQA.Citation) -> some View {
        let r = controller.meetings.first { $0.id == c.callID }
        return Button {
            close()
            if let at = c.at { controller.openMeeting(c.callID, at: at) } else { controller.openMeeting(c.callID) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let at = c.at { Text(clock(at)).foregroundStyle(Color.accentColor).monospacedDigit() }
                Text("“\(c.quote)”").italic().lineLimit(2)
                Spacer()
                Text(r?.title ?? "").foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the meeting and play from here")
    }
}
