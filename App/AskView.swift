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

/// A question about all your meetings, answered by Claude from the relevant notes, with links to the moments.
struct AskView: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var asked = ""
    @State private var answer: MeetingQA.Answer?
    @State private var error: String?
    @State private var asking = false
    @FocusState private var focused: Bool

    private let examples = ["What did we decide about Supermetrics?", "What do I owe Mitch?", "What came up about the budget this month?"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                TextField("Ask about your meetings", text: $question)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(send)
                if asking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if let answer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(asked).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Text((try? AttributedString(markdown: answer.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer.text))
                            .font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                        if !answer.citations.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("SOURCES").font(.system(size: 10, weight: .semibold)).kerning(0.4).foregroundStyle(.tertiary)
                                ForEach(Array(answer.citations.enumerated()), id: \.offset) { _, c in citation(c) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 420)
            } else if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Theme.recording)
            } else if !asking {
                VStack(alignment: .leading, spacing: 6) {
                    Text("For example").font(.system(size: 11)).foregroundStyle(.tertiary)
                    ForEach(examples, id: \.self) { e in
                        Button(e) { question = e; send() }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.accentColor)
                    }
                }
            }
            HStack {
                Text("Claude reads the notes of the meetings that match your question.").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear { focused = true }
    }

    private func citation(_ c: MeetingQA.Citation) -> some View {
        let r = controller.meetings.first { $0.id == c.callID }
        return Button {
            dismiss()
            if let at = c.at { controller.openMeeting(c.callID, at: at) } else { controller.openMeeting(c.callID) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r?.title ?? "Meeting").fontWeight(.medium).lineLimit(1)
                Text(r.map { shortTime($0.start) } ?? "").foregroundStyle(.secondary)
                if let at = c.at { Text(clock(at)).foregroundStyle(Color.accentColor).monospacedDigit() }
                Text("“\(c.quote)”").italic().foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking else { return }
        asking = true
        error = nil
        answer = nil
        asked = q
        Task {
            do { answer = try await controller.ask(q) } catch { self.error = "\(error)" }
            asking = false
        }
    }
}
