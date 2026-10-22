import MossadCore
import SwiftUI

/// What the coach knows: your focus, your patterns, and what it learned about you.
struct CoachView: View {
    @EnvironmentObject var store: PhoneStore

    var body: some View {
        NavigationStack {
            List {
                let p = store.profile
                if p.summary.isEmpty && p.focus.isEmpty {
                    Text("Turn on the communication coach in Mossad on your Mac. Its notes appear here.").foregroundStyle(.secondary)
                }
                if !p.focus.isEmpty { Section("Your focus") { Text(p.focus) } }
                if !p.summary.isEmpty { Section("How you communicate") { Text(p.summary) } }
                if !p.patterns.isEmpty {
                    Section("Patterns") {
                        ForEach(p.patterns, id: \.self) { pattern in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pattern.name).font(.subheadline.weight(.semibold))
                                Text(pattern.note).font(.subheadline).foregroundStyle(.secondary)
                                Text("\(pattern.trend.rawValue.capitalized) · seen in \(pattern.seen) calls").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                ForEach(CoachFact.Kind.allCases, id: \.self) { kind in
                    let facts = p.facts(kind)
                    if !facts.isEmpty { Section(kind.title) { ForEach(facts) { Text($0.text) } } }
                }
            }
            .navigationTitle("Coach")
            .refreshable { await store.sync() }
        }
    }
}
