import MossadCore
import SwiftUI

/// Everything you promised in your calls, most urgent first. Mark them done, date them, edit, or add your own.
struct CommitmentsView: View {
    @EnvironmentObject var controller: AppController
    @State private var book = CommitmentBook()
    @State private var editing: Commitment?
    @State private var adding: Commitment?
    @State private var showDone = false
    @State private var query = ""

    private var shown: [CommitmentGroup] {
        let list = book.visible.filter { c in
            query.isEmpty || c.text.localizedCaseInsensitiveContains(query) || (c.to ?? "").localizedCaseInsensitiveContains(query)
                || (c.callTitle ?? "").localizedCaseInsensitiveContains(query)
        }
        return CommitmentGroup.make(list).filter { showDone || $0.kind != .done }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if book.visible.isEmpty {
                DetailEmptyState(symbol: "checkmark.circle", title: "No commitments yet",
                                 message: "After each call, Mossad finds what you promised to do, with due dates when you gave one. You can also add your own.")
            } else {
                List {
                    ForEach(shown) { group in
                        Section {
                            ForEach(group.items) { c in
                                CommitmentRow(commitment: c) { controller.toggleDone(c.id) }
                                    .padding(.vertical, 4)
                                    .onTapGesture { if let id = c.callID { open(id, c.at) } else { editing = c } }
                                    .contextMenu {
                                        Button("Edit…") { editing = c }
                                        Button(c.done == nil ? "Mark done" : "Mark not done") { controller.toggleDone(c.id) }
                                        if let id = c.callID {
                                            Button("Open the meeting") { open(id, c.at) }
                                        }
                                        Divider()
                                        Button("Delete", role: .destructive) { controller.deleteCommitment(c.id) }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(group.kind.title)
                                Text("\(group.items.count)").foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(group.kind == .overdue ? Color.red : Color.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.top, 8)
        .background(Theme.background)
        .navigationTitle("Commitments")
        .navigationSubtitle(subtitle)
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $showDone) { Label("Show done", systemImage: "checkmark.circle") }
                    .help("Show done commitments")
                Button {
                    adding = Commitment(text: "", to: nil, callID: nil, callTitle: nil, madeAt: Date(), due: nil)
                } label: { Label("Add", systemImage: "plus") }
                    .help("Add a commitment")
            }
        }
        .task(id: controller.commitmentsVersion) { book = controller.commitmentBook }
        .sheet(item: $editing) { c in
            NavigationStack {
                CommitmentEditor(commitment: c, save: controller.saveCommitment, delete: { controller.deleteCommitment(c.id) },
                                 openMeeting: { open($0, $1) })
            }
            .frame(minWidth: 420, minHeight: 380)
        }
        .sheet(item: $adding) { c in
            NavigationStack { CommitmentEditor(commitment: c, isNew: true, save: controller.saveCommitment, delete: nil) }
                .frame(minWidth: 420, minHeight: 300)
        }
    }

    private var subtitle: String {
        let overdue = book.visible.filter { $0.status() == .overdue }.count
        let open = book.visible.filter { $0.done == nil }.count
        return open == 0 ? "Nothing open" : "\(open) open" + (overdue > 0 ? " · \(overdue) overdue" : "")
    }

    private func open(_ callID: String, _ at: TimeInterval?) {
        if let at { controller.showMoment(callID, at: at) } else { controller.openMeeting(callID) }
    }
}
