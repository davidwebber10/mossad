import MossadCore
import SwiftUI

/// What the coach and Chat remember about you. Swipe to make them forget; add what they should know.
struct CoachMemoryView: View {
    @EnvironmentObject var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @State private var newFact = ""
    @State private var kind = CoachFact.Kind.allCases[0]

    var body: some View {
        NavigationStack {
            List {
                let p = store.profile
                if !p.focus.isEmpty { Section("Your focus") { Text(p.focus) } }
                if !p.summary.isEmpty { Section("How you communicate") { Text(p.summary) } }
                if !p.patterns.isEmpty {
                    Section("Patterns") {
                        ForEach(p.patterns, id: \.self) { pattern in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: pattern.kind == .strength ? "plus.circle.fill" : "arrow.up.forward.circle.fill")
                                        .foregroundStyle(pattern.kind == .strength ? .green : .orange)
                                    Text(pattern.name).font(.subheadline.weight(.semibold))
                                }
                                Text(pattern.note).font(.subheadline).foregroundStyle(.secondary)
                                Text("\(pattern.trend.rawValue.capitalized) · seen in \(pattern.seen) calls").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !p.guidance.isEmpty {
                    Section {
                        ForEach(p.guidance) { g in Text(g.text) }
                            .onDelete { offsets in for i in offsets { store.removeGuidance(p.guidance[i].text) } }
                    } header: { Text("What you told the coach") }
                }
                ForEach(CoachFact.Kind.allCases, id: \.self) { kind in
                    let facts = p.facts(kind)
                    if !facts.isEmpty {
                        Section(kind.title) {
                            ForEach(facts) { Text($0.text) }
                                .onDelete { offsets in for i in offsets { store.removeFact(facts[i].text) } }
                        }
                    }
                }
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(CoachFact.Kind.allCases, id: \.self) { Text($0.title) }
                    }
                    TextField("Something to remember", text: $newFact, axis: .vertical)
                    Button("Remember") {
                        store.addFact(kind, newFact.trimmingCharacters(in: .whitespacesAndNewlines))
                        newFact = ""
                    }
                    .disabled(newFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Add")
                } footer: {
                    Text("Chat and the coach use these in every answer and review, on the Mac and here.")
                }
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
