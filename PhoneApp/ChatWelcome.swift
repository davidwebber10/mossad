import MossadCore
import SwiftUI

/// The empty chat: a greeting with the day at a glance, and four starting points built from your own meetings.
struct ChatWelcome: View {
    @EnvironmentObject var store: PhoneStore
    let ask: (String) -> Void

    struct Starter: Identifiable {
        var id: String { title }
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let prompt: String
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
                    .padding(.bottom, 6)
                Text(greeting).font(.title.bold())
                Text(glance).font(.body).foregroundStyle(.secondary)
                if store.languageModel == nil {
                    Label("Turn on “Use my AI key on my iPhone” in Mossad’s Settings on your Mac.", systemImage: "key")
                        .font(.footnote).foregroundStyle(.orange).padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            Spacer(minLength: 24)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(starters) { s in
                    Button { ask(s.prompt) } label: { StarterCard(starter: s) }
                        .buttonStyle(.plain)
                        .disabled(store.languageModel == nil)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
    }

    private var firstName: String { store.owner.split(separator: " ").first.map(String.init) ?? "" }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        return firstName.isEmpty ? part : "\(part), \(firstName)"
    }

    private var today: [CallRecord] { store.meetings.filter { Calendar.current.isDateInToday($0.start) } }

    private var glance: String {
        let seconds = today.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        let day = today.isEmpty ? "No meetings yet today." : "\(today.count) \(today.count == 1 ? "meeting" : "meetings") today, \(duration(seconds))."
        return "\(day) Ask about any meeting, or ask how you are doing."
    }

    private var lastWeek: [CallRecord] { store.meetings.filter { $0.start > Date().addingTimeInterval(-7 * 86_400) } }

    private var starters: [Starter] {
        let owed = lastWeek.flatMap(\.actionItems).filter { $0.owner == store.owner }.count
        let latest = store.meetings.first { store.scores[$0.id] != nil }
        var counts: [String: Int] = [:]
        for r in store.meetings.prefix(30) {
            for n in Set(r.speakerNames.values) where n != store.owner && !n.hasPrefix("Speaker") { counts[n, default: 0] += 1 }
        }
        let person = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }

        var list = [
            today.isEmpty
                ? Starter(symbol: "calendar", tint: .blue, title: "Recap my week", detail: "\(lastWeek.count) meetings",
                          prompt: "Recap my meetings from the last 7 days: what was decided, and what still needs me.")
                : Starter(symbol: "sun.max.fill", tint: .orange, title: "Recap today", detail: "\(today.count) \(today.count == 1 ? "meeting" : "meetings")",
                          prompt: "Recap my meetings today: what was decided, and what I need to do next."),
            Starter(symbol: "checklist", tint: .green, title: "What I owe", detail: owed == 0 ? "Last 7 days" : "\(owed) action \(owed == 1 ? "item" : "items")",
                    prompt: "What do I owe people from the last 7 days? Group it by person, and flag anything overdue."),
            Starter(symbol: "person.wave.2.fill", tint: .purple, title: "Coach me",
                    detail: latest.flatMap { store.scores[$0.id] }.map { "Last score \($0)/5" } ?? "From your reviews",
                    prompt: "How did I do in my recent meetings, and what one thing should I work on next? Be specific."),
        ]
        if let person {
            list.append(Starter(symbol: "person.2.fill", tint: .teal, title: "Before I meet \(person.key.split(separator: " ").first ?? "")",
                                detail: "\(person.value) meetings together",
                                prompt: "I'm meeting \(person.key) next. What is open between us, what did we agree, and what should I bring up?"))
        } else {
            list.append(Starter(symbol: "hourglass", tint: .teal, title: "Where time goes", detail: "Low-value meetings",
                                prompt: "Which of my meetings were low value, and what should I change about them?"))
        }
        return list
    }
}

private struct StarterCard: View {
    let starter: ChatWelcome.Starter

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: starter.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(starter.tint)
                .frame(width: 34, height: 34)
                .background(starter.tint.opacity(0.16), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(starter.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(starter.detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
    }
}
