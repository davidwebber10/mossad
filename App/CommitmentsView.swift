import MossadCore
import SwiftUI

/// Everything you promised in your calls: overdue first in the accent, then what has a date, then the rest grouped
/// by the person you promised, so you can clear one person at a time. Done holds the finished ones.
struct CommitmentsView: View {
    enum Mode: String, CaseIterable { case open = "Open", done = "Done" }

    @EnvironmentObject var controller: AppController
    @State private var book = CommitmentBook()
    @State private var editing: Commitment?
    @State private var adding: Commitment?
    @State private var mode = Mode.open
    @State private var query = ""

    private var matching: [Commitment] {
        book.visible.filter { c in
            query.isEmpty || c.text.localizedCaseInsensitiveContains(query) || (c.to ?? "").localizedCaseInsensitiveContains(query)
                || (c.callTitle ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [CommitmentGroup] { CommitmentGroup.make(matching) }
    private var openGroups: [CommitmentGroup] { groups.filter { $0.kind != .done } }
    private var doneItems: [Commitment] { groups.first { $0.kind == .done }?.items ?? [] }

    var body: some View {
        DetailColumn { toolbar } content: { page }
        .task(id: controller.commitmentsVersion) { book = controller.commitmentBook }
        .onAppear {
            // Development hook for screenshots: MOSSAD_COMMITMENTS=done opens the Done view.
            if CommandLine.arguments.contains("--ui-preview"), ProcessInfo.processInfo.environment["MOSSAD_COMMITMENTS"] == "done" {
                mode = .done
            }
        }
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

    @ViewBuilder
    private var page: some View {
        if book.visible.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "No tasks yet",
                       message: "After each call, Mossad finds what you promised to do, with due dates when you gave one. You can also add your own.",
                       action: ("Add a task", add))
                .pageCentered()
        } else if mode == .open, openGroups.isEmpty, query.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "Nothing open", message: keptText)
                .pageCentered()
        } else if mode == .done, doneItems.isEmpty, query.isEmpty {
            EmptyState(symbol: "checkmark.circle", title: "Nothing done yet",
                       message: "Mark a task done with its circle, and it moves here.")
                .pageCentered()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch mode {
                    case .open: openList
                    case .done: doneList
                    }
                    if (mode == .open ? openGroups.isEmpty : doneItems.isEmpty) && !query.isEmpty {
                        Text("No tasks match “\(query)”.")
                            .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    }
                }
                .frame(maxWidth: Detail.listMax, alignment: .leading)
                .padding(.horizontal, Detail.gutter).padding(.top, Detail.bodyTop).padding(.bottom, Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var toolbar: some View {
        PageToolbar(title: "Tasks", subtitle: subtitle) {
            ToolbarSegmented(selection: $mode, options: Mode.allCases.map { .init(value: $0, label: $0.rawValue) },
                           accessibilityLabel: "Show")
                .help("Open or done tasks")
            ToolbarSearchField(prompt: "Search tasks", query: $query)
            ToolbarCircleButton(icon: .plus, label: "Add", help: "Add a task", action: add)
        }
    }

    // MARK: Open

    @ViewBuilder
    private var openList: some View {
        ForEach(Array(openGroups.enumerated()), id: \.element.id) { i, group in
            CommitmentSectionTitle(title: group.kind.title, count: group.items.count, accent: group.kind == .overdue,
                         note: group.kind == .noDate ? "Grouped by who you promised" : nil)
                .padding(.top, i == 0 ? 0 : 36)
            if group.kind == .noDate {
                ForEach(CommitmentPersonGroup.make(group.items)) { person in
                    CommitmentPersonHeading(group: person)
                    ForEach(person.items) { c in row(c, showPerson: false) }
                }
            } else {
                ForEach(group.items) { c in row(c, showPerson: true) }
            }
        }
    }

    // MARK: Done

    @ViewBuilder
    private var doneList: some View {
        if !doneItems.isEmpty {
            CommitmentSectionTitle(title: "Done", count: doneItems.count, accent: false, note: nil)
            ForEach(doneItems) { c in row(c, showPerson: true) }
        }
    }

    // MARK: Rows

    private func row(_ c: Commitment, showPerson: Bool) -> some View {
        CommitmentRow(commitment: c, showPerson: showPerson, open: { activate(c) }, toggleDone: { controller.toggleDone(c.id) }) {
            trailing(c)
        }
        .padding(.vertical, c.status() == .overdue ? 11 : 10)
        .hairline()
        .contextMenu { menu(c) }
        .accessibilityElement(children: .contain)
        .accessibilityActions { menu(c) }
    }

    @ViewBuilder
    private func trailing(_ c: Commitment) -> some View {
        if let done = c.done {
            Text("Done \(done.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                .fixedSize()
        } else {
            VStack(alignment: .trailing, spacing: 3) {
                CommitmentDue(commitment: c)
                DueDateButton(commitment: c) { due in
                    var changed = c
                    changed.due = due
                    controller.saveCommitment(changed)
                }
            }
        }
    }

    @ViewBuilder
    private func menu(_ c: Commitment) -> some View {
        Button("Edit…") { editing = c }
        Button(c.done == nil ? "Mark done" : "Mark not done") { controller.toggleDone(c.id) }
        if let id = c.callID {
            Button("Open the meeting") { open(id, c.at) }
        }
        Divider()
        Button("Delete", role: .destructive) { controller.deleteCommitment(c.id) }
    }

    // MARK: Text and actions

    private var subtitle: String {
        let overdue = book.visible.filter { $0.status() == .overdue }.count
        let open = book.visible.filter { $0.done == nil }.count
        return open == 0 ? "Nothing open" : "\(open) open" + (overdue > 0 ? " · \(overdue) overdue" : "")
    }

    /// "You kept all 31 commitments from the last 30 days."
    private var keptText: String {
        let since = Date().addingTimeInterval(-30 * 86_400)
        let kept = book.visible.filter { ($0.done ?? .distantPast) > since }.count
        let then = "New ones appear here after your next call."
        switch kept {
        case 0: return then
        case 1: return "You kept your one task from the last 30 days. " + then
        default: return "You kept all \(kept) tasks from the last 30 days. " + then
        }
    }

    private func add() {
        adding = Commitment(text: "", to: nil, callID: nil, callTitle: nil, madeAt: Date(), due: nil)
    }

    /// A commitment from a call opens the meeting at the moment it was said; one added by hand opens the editor.
    private func activate(_ c: Commitment) {
        if let id = c.callID { open(id, c.at) } else { editing = c }
    }

    private func open(_ callID: String, _ at: TimeInterval?) {
        if let at { controller.showMoment(callID, at: at) } else { controller.openMeeting(callID) }
    }
}

/// "Add a date", "Pick a new date", or "Change date": opens a calendar in a popover; a day sets it at once.
private struct DueDateButton: View {
    let commitment: Commitment
    let set: (Date?) -> Void
    @State private var picking = false
    @State private var hovering = false

    private var title: String {
        guard commitment.due != nil else { return "Add a date" }
        return commitment.status() == .overdue ? "Pick a new date" : "Change date"
    }

    var body: some View {
        Button(title) { picking = true }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(hovering ? Palette.ink : Palette.secondary)
            .underline(hovering, color: Palette.secondary)
            .fixedSize()
            .onHover { hovering = $0 }
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                DuePicker(due: commitment.due) { due in
                    picking = false
                    set(due)
                }
            }
    }
}

private struct DuePicker: View {
    let due: Date?
    let pick: (Date?) -> Void
    @State private var day = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Button("Today") { pick(Calendar.current.startOfDay(for: Date())) }
                Button("Tomorrow") { pick(Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))) }
                Button("Next week") { pick(Calendar.current.startOfDay(for: Date().addingTimeInterval(7 * 86_400))) }
            }
            .buttonStyle(.mossadFill)
            DatePicker("Due", selection: Binding(get: { day }, set: { day = $0; pick(Calendar.current.startOfDay(for: $0)) }),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            if due != nil {
                Button("Remove date", role: .destructive) { pick(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.recording)
            }
        }
        .padding(Space.m)
        .onAppear { day = due ?? Date() }
    }
}

extension View {
    /// Centered in the page.
    func pageCentered() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
