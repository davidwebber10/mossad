import MossadCore
import SwiftUI

/// The empty chat as the canvas draws it: the accent sparkle, what Chat can answer, and four questions built from
/// your own meetings, one per row.
struct ChatWelcome: View {
    @EnvironmentObject var store: PhoneStore
    let ask: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s) {
                Image(systemName: "sparkle")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text("Ask about your meetings").textRole(.title).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Who said what, what people agreed to and by when, what was decided. Answers link to the moment.")
                    .textRole(.secondary).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.languageModel == nil {
                    Label("Turn on “Use my AI key on my iPhone” in Mossad’s Settings on your Mac.", systemImage: "key")
                        .textRole(.secondary).foregroundStyle(Palette.accent)
                        .padding(.top, 4)
                }
                ExampleQuestions(questions: questions, enabled: store.languageModel != nil, ask: ask)
                    .padding(.top, Space.m)
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.xl)
        }
    }

    private var today: [CallRecord] { store.meetings.filter { Calendar.current.isDateInToday($0.start) } }

    /// The person met most in the last thirty meetings, for a question about them.
    private var person: String? {
        var counts: [String: Int] = [:]
        for r in store.meetings.prefix(30) {
            for n in Set(r.speakerNames.values) where n != store.owner && !n.hasPrefix("Speaker") { counts[n, default: 0] += 1 }
        }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// Built from what is here: the day's meetings, what is overdue, and the person met most.
    private var questions: [String] {
        let open = store.commitments.visible.filter { $0.done == nil }
        let overdue = open.filter { $0.status() == .overdue }.count
        return [
            today.isEmpty ? "What was decided this week, and what still needs me?" : "What was decided today, and what do I need to do next?",
            overdue > 0 ? "\(overdue) of my commitments are overdue. Which should I do first?"
                : open.isEmpty ? "What did I agree to in my last meeting?" : "What do I owe people from this week's meetings?",
            person.map { "Before I meet \($0.split(separator: " ").first.map(String.init) ?? $0): what is open between us, and what should I bring up?" }
                ?? "Which of my meetings were low value, and what should I change?",
            "How did I do in my recent meetings, and what one thing should I work on?",
        ]
    }
}

/// Example questions as quiet rows with hairlines between them; a tap asks it.
struct ExampleQuestions: View {
    let questions: [String]
    var enabled = true
    let ask: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(questions, id: \.self) { q in
                Button { ask(q) } label: {
                    Text(q)
                        .textRole(.body)
                        .foregroundStyle(enabled ? Palette.ink : Palette.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 13)
                        .padding(.horizontal, 2)
                        .overlay(alignment: .bottom) { Hairline() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
    }
}
