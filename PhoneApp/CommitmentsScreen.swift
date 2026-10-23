import MossadCore
import SwiftUI

/// What you promised in your calls, most urgent first. Tap the circle to finish one; tap the row to edit it.
struct CommitmentsScreen: View {
    @EnvironmentObject var store: PhoneStore
    @State private var editing: Commitment?
    @State private var adding: Commitment?
    @State private var showDone = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(CommitmentGroup.make(store.commitments.visible).filter { showDone || $0.kind != .done }) { group in
                    Section {
                        ForEach(group.items) { c in
                            CommitmentRow(commitment: c) { store.toggleDone(c.id) }
                                .onTapGesture { editing = c }
                                .swipeActions(edge: .leading) {
                                    Button(c.done == nil ? "Done" : "Undo") { store.toggleDone(c.id) }.tint(.green)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) { store.deleteCommitment(c.id) }
                                }
                        }
                    } header: {
                        Text("\(group.kind.title) · \(group.items.count)")
                            .foregroundStyle(group.kind == .overdue ? Color.red : Color.secondary)
                    }
                }
            }
            .overlay {
                if store.commitments.visible.isEmpty {
                    ContentUnavailableView("No commitments yet", systemImage: "checkmark.circle",
                                           description: Text("After each call, Mossad on your Mac finds what you promised to do, with due dates when you gave one."))
                }
            }
            .navigationTitle("Commitments")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(showDone ? "Hide done" : "Show done") { withAnimation { showDone.toggle() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add", systemImage: "plus") {
                        adding = Commitment(text: "", to: nil, callID: nil, callTitle: nil, madeAt: Date(), due: nil)
                    }
                }
            }
            .refreshable { await store.sync() }
            .sheet(item: $editing) { c in
                NavigationStack {
                    CommitmentEditor(commitment: c, save: store.saveCommitment, delete: { store.deleteCommitment(c.id) },
                                     openMeeting: { id, _ in store.openMeeting(id) })
                }
            }
            .sheet(item: $adding) { c in
                NavigationStack { CommitmentEditor(commitment: c, isNew: true, save: store.saveCommitment, delete: nil) }
            }
        }
    }
}
