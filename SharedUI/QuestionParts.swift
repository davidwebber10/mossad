import MossadCore
import SwiftUI

/// The coach's questions, one at a time: what it concluded, the moment that led there, and Yes, Not quite, or
/// No. One calm moment, not a form.
struct QuestionsPanel: View {
    let questions: [CoachQuestion]
    let answer: (UUID, CoachQuestion.Status, String?) -> Void
    /// Opens the quoted moment, when the question came from a call.
    var openMoment: ((String, TimeInterval) -> Void)?
    @State private var correcting = false
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        if let q = questions.first {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble").foregroundStyle(.tint)
                    Text("Is this right?").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if questions.count > 1 {
                        Text("1 of \(questions.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(q.statement).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if !q.evidence.isEmpty {
                        Button {
                            if let id = q.callID { openMoment?(id, q.at ?? 0) }
                        } label: {
                            Text(q.evidence).font(.callout).italic().foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(openMoment == nil || q.callID == nil)
                        .help("Show this moment in the call")
                    }
                }
                .id(q.id)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                if correcting {
                    HStack(spacing: 8) {
                        TextField("What is right?", text: $note, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .focused($noteFocused)
                            .onSubmit { send(q, .corrected) }
                        Button("Save") { send(q, .corrected) }
                            .buttonStyle(.borderedProminent)
                            .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") { withAnimation(.snappy) { correcting = false } }
                    }
                } else {
                    HStack(spacing: 8) {
                        Button("Yes") { send(q, .confirmed) }.buttonStyle(.borderedProminent)
                        Button("Not quite…") {
                            withAnimation(.snappy) { correcting = true }
                            noteFocused = true
                        }
                        .buttonStyle(.bordered)
                        Button("No") { send(q, .rejected) }.buttonStyle(.bordered)
                    }
                }
                Text("Your answer shapes how the coach reads your calls.").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
            .animation(.snappy, value: q.id)
            .sensoryFeedback(.success, trigger: questions.count)
        }
    }

    private func send(_ q: CoachQuestion, _ status: CoachQuestion.Status) {
        let text = note
        withAnimation(.snappy) {
            correcting = false
            note = ""
            answer(q.id, status, status == .corrected ? text : nil)
        }
    }
}

/// The questions the owner already answered, with what became of each.
struct AnsweredQuestions: View {
    let questions: [CoachQuestion]

    var body: some View {
        ForEach(questions.filter { $0.status != .open }.suffix(12).reversed()) { q in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol(q.status)).foregroundStyle(color(q.status)).font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.statement).strikethrough(q.status == .rejected).foregroundStyle(q.status == .rejected ? .secondary : .primary)
                    if let note = q.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .font(.callout)
        }
    }

    private func symbol(_ s: CoachQuestion.Status) -> String {
        switch s {
        case .confirmed: "checkmark.circle.fill"
        case .corrected: "pencil.circle.fill"
        case .rejected: "xmark.circle.fill"
        case .open: "circle"
        }
    }

    private func color(_ s: CoachQuestion.Status) -> Color {
        switch s {
        case .confirmed: .green
        case .corrected: .orange
        case .rejected, .open: .secondary
        }
    }
}
