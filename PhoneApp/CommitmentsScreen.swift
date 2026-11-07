import MossadCore
import SwiftUI

/// What you promised, as the Mac lists it: overdue first in the accent, then what has a date, then the rest
/// grouped by the person you promised. Done holds the finished ones. Swipe to finish or delete.
struct CommitmentsScreen: View {
    enum Mode: String, CaseIterable { case open = "Open", done = "Done" }

    @EnvironmentObject var store: PhoneStore
    @State private var mode = Mode.open
    @State private var editing: Commitment?
    @State private var adding: Commitment?
    @State private var dating: Commitment?

    private var groups: [CommitmentGroup] { CommitmentGroup.make(store.commitments.visible) }
    private var openGroups: [CommitmentGroup] { groups.filter { $0.kind != .done } }
    private var doneItems: [Commitment] { groups.first { $0.kind == .done }?.items ?? [] }

    var body: some View {
        NavigationStack {
            List {
                PhoneSegments(options: Mode.allCases.map { ($0, $0.rawValue) }, selection: $mode)
                    .frame(maxWidth: .infinity)
                    .plainRow(top: 0)
                switch mode {
                case .open: openList
                case .done: doneList
                }
                NavigationLink {
                    ActionItemsView()
                } label: {
                    Label("Action items from meetings", systemImage: "checklist")
                        .textRole(.body).foregroundStyle(Palette.ink)
                }
                .plainRow(top: Space.xl)
            }
            .listStyle(.plain)
            .overlay { empty }
            .phonePage()
            .navigationTitle("Commitments")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add a commitment", systemImage: "plus") {
                        adding = Commitment(text: "", to: nil, callID: nil, callTitle: nil, madeAt: Date(), due: nil)
                    }
                    .tint(Palette.ink)
                }
            }
            .refreshable { await store.sync() }
            .sheet(item: $editing) { c in
                NavigationStack {
                    CommitmentEditor(commitment: c, save: store.saveCommitment, delete: { store.deleteCommitment(c.id) },
                                     openMeeting: { id, at in store.showMoment(id, at: at) })
                }
            }
            .sheet(item: $adding) { c in
                NavigationStack { CommitmentEditor(commitment: c, isNew: true, save: store.saveCommitment, delete: nil) }
            }
            .sheet(item: $dating) { c in
                DueSheet(commitment: c) { due in
                    var changed = c
                    changed.due = due
                    store.saveCommitment(changed)
                    dating = nil
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    @ViewBuilder
    private var empty: some View {
        if store.commitments.visible.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "No commitments yet",
                       message: "After each call, Mossad finds what you promised to do, with due dates when you gave one.")
        } else if mode == .open, openGroups.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "Nothing open", message: "New ones appear here after your next call.")
        } else if mode == .done, doneItems.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "Nothing done yet",
                       message: "Mark a commitment done with its circle, and it moves here.")
        }
    }

    @ViewBuilder
    private var openList: some View {
        ForEach(Array(openGroups.enumerated()), id: \.element.id) { i, group in
            CommitmentSectionTitle(title: group.kind.title, count: group.items.count, accent: group.kind == .overdue, note: nil)
                .plainRow(top: i == 0 ? Space.l : Space.xl)
            if group.kind == .noDate {
                ForEach(CommitmentPersonGroup.make(group.items)) { person in
                    CommitmentPersonHeading(group: person).plainRow(top: 0)
                    ForEach(person.items) { c in row(c, showPerson: false) }
                }
            } else {
                ForEach(group.items) { c in row(c, showPerson: true) }
            }
        }
    }

    @ViewBuilder
    private var doneList: some View {
        if !doneItems.isEmpty {
            CommitmentSectionTitle(title: "Done", count: doneItems.count, accent: false, note: nil).plainRow(top: Space.l)
            ForEach(doneItems) { c in row(c, showPerson: true) }
        }
    }

    private func row(_ c: Commitment, showPerson: Bool) -> some View {
        CommitmentRow(commitment: c, showPerson: showPerson, open: { activate(c) }, toggleDone: { store.toggleDone(c.id) }) {
            trailing(c)
        }
        .padding(.vertical, 10)
        .listRowInsets(EdgeInsets(top: 0, leading: Space.l, bottom: 0, trailing: Space.l))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Palette.hairline)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 28 }
        .swipeActions(edge: .leading) {
            Button(c.done == nil ? "Done" : "Not done", systemImage: "checkmark") { store.toggleDone(c.id) }.tint(Palette.ok)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteCommitment(c.id) }
            Button("Edit", systemImage: "pencil") { editing = c }
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editing = c }
            if c.done == nil { Button(c.due == nil ? "Add a date" : "Change date", systemImage: "calendar") { dating = c } }
            if let id = c.callID { Button("Open the meeting", systemImage: "arrow.up.right") { store.showMoment(id, at: c.at) } }
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteCommitment(c.id) }
        }
    }

    @ViewBuilder
    private func trailing(_ c: Commitment) -> some View {
        if let done = c.done {
            Text("Done \(done.formatted(.dateTime.month(.abbreviated).day()))")
                .textRole(.secondary).foregroundStyle(Palette.secondary).fixedSize()
        } else if c.due == nil {
            Button("Add a date") { dating = c }
                .buttonStyle(.plain)
                .textRole(.secondary)
                .foregroundStyle(Palette.secondary)
                .fixedSize()
        } else {
            CommitmentDue(commitment: c)
        }
    }

    /// A commitment from a call opens the meeting where it was said; one added by hand opens the editor.
    private func activate(_ c: Commitment) {
        if let id = c.callID, store.meeting(id) != nil { store.showMoment(id, at: c.at) } else { editing = c }
    }
}

private extension View {
    /// A list row that is part of the page, not a cell: no background, no separator, the page's gutter.
    func plainRow(top: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: Space.l, bottom: 0, trailing: Space.l))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// Today, Tomorrow, Next week, or a day on the calendar; a pick sets it at once.
private struct DueSheet: View {
    let commitment: Commitment
    let pick: (Date?) -> Void
    @State private var day = Date()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(spacing: Space.s) {
                    Button("Today") { pick(Calendar.current.startOfDay(for: Date())) }
                    Button("Tomorrow") { pick(Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))) }
                    Button("Next week") { pick(Calendar.current.startOfDay(for: Date().addingTimeInterval(7 * 86_400))) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                DatePicker("Due", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                if commitment.due != nil {
                    Button("Remove date", role: .destructive) { pick(nil) }
                }
                Spacer(minLength: 0)
            }
            .padding(Space.l)
            .navigationTitle(commitment.text)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { pick(Calendar.current.startOfDay(for: day)) }
                }
            }
            .onAppear { day = commitment.due ?? Date() }
        }
    }
}
