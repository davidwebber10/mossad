import MossadCore
import SwiftUI

extension Commitment {
    /// Whole days past the due date: "15 days late".
    func daysLate(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let due else { return 0 }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: due), to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// "15 days late", "Today", "Tomorrow", "Fri, Nov 8"; nil without a date or once done.
    var dueText: String? {
        guard let due, done == nil else { return nil }
        switch status() {
        case .overdue:
            let days = daysLate()
            return days == 1 ? "1 day late" : "\(days) days late"
        case .dueToday: return "Today"
        default:
            return Calendar.current.isDateInTomorrow(due) ? "Tomorrow" : due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    /// "Weekly 1:1, Oct 21", or "Added Oct 21" for one added by hand.
    var sourceText: String {
        let day = (callTitle == nil ? created : madeAt).formatted(.dateTime.month(.abbreviated).day())
        return callTitle.map { "\($0), \(day)" } ?? "Added \(day)"
    }
}

/// One commitment as the canvas draws it: a ring to mark it done (accent when late), what it is, who it was for
/// and where, and something on the right (when it is due, or the page's own date button).
struct CommitmentRow<Trailing: View>: View {
    let commitment: Commitment
    /// Off inside a meeting, where the meeting is already clear.
    var showSource = true
    /// Off under a person's group heading, where the person is already clear.
    var showPerson = true
    /// The text with a search's words in bold, and a line under the row that says why it matched.
    var marked: AttributedString?
    var matchLine: AttributedString?
    /// What a click on the text does: the Mac opens the meeting at the moment. Nil leaves the text inert.
    var open: (() -> Void)?
    let toggleDone: () -> Void
    @ViewBuilder var trailing: Trailing

    @ScaledMetric(relativeTo: .body) private var textSize: CGFloat = CommitmentRowMetrics.text
    @ScaledMetric(relativeTo: .callout) private var detailSize: CGFloat = CommitmentRowMetrics.detail

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            CommitmentRing(commitment: commitment, toggle: toggleDone)
            if let open {
                Button(action: open) { content.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
            } else {
                content
            }
            trailing
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            Text(marked ?? AttributedString(commitment.text))
                .font(.system(size: textSize, weight: .medium))
                .cssLineHeight(size: textSize)
                .strikethrough(commitment.done != nil, color: Palette.secondary)
                .foregroundStyle(commitment.done == nil ? Palette.ink : Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hasDetail {
                HStack(spacing: Space.s) {
                    if showPerson, let to = commitment.to {
                        Circle().fill(PersonMark.color(for: to)).frame(width: 7, height: 7).accessibilityHidden(true)
                    }
                    Text(detail).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: detailSize))
                .foregroundStyle(Palette.secondary)
                .cssLineHeight(size: detailSize)
            }
            if let matchLine {
                Text(matchLine)
                    .font(.system(size: detailSize))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasDetail: Bool { !detail.isEmpty }

    private var detail: String {
        var parts: [String] = []
        if showPerson, let to = commitment.to { parts.append(to) }
        if showSource { parts.append(commitment.sourceText) }
        return parts.joined(separator: " · ")
    }
}

extension CommitmentRow where Trailing == CommitmentDue {
    /// With the due date on the right, as a meeting shows its own commitments.
    init(commitment: Commitment, showSource: Bool = true, toggleDone: @escaping () -> Void) {
        self.init(commitment: commitment, showSource: showSource, toggleDone: toggleDone) { CommitmentDue(commitment: commitment) }
    }
}

enum CommitmentRowMetrics {
    #if os(iOS)
    static let text: CGFloat = 15
    static let detail: CGFloat = 13
    #else
    static let text: CGFloat = 14
    static let detail: CGFloat = 12
    #endif
}

/// The ring that marks a commitment done: accent when it is late, a quiet ring otherwise, a green check once done.
struct CommitmentRing: View {
    let commitment: Commitment
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16

    var body: some View {
        let done = commitment.done != nil
        Button(action: toggle) {
            ZStack {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .foregroundStyle(Palette.ok)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Circle().strokeBorder(commitment.status() == .overdue ? Palette.accentFill : Palette.ring, lineWidth: 1.5)
                }
            }
            .frame(width: size, height: size)
            .padding(3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(-3)
        .padding(.top, 1)
        .animation(.snappy(duration: 0.2), value: done)
        .accessibilityLabel(done ? "Mark not done" : "Mark done")
        .sensoryFeedback(.success, trigger: done)
    }
}

/// When a commitment is due, on the right of its row: late in the accent, the rest in secondary.
struct CommitmentDue: View {
    let commitment: Commitment
    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = CommitmentRowMetrics.detail

    var body: some View {
        if let text = commitment.dueText {
            let late = commitment.status() == .overdue
            Text(text)
                .font(.system(size: size + (late ? 0.5 : 0), weight: late ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(late ? Palette.accent : Palette.secondary)
                .fixedSize()
                .padding(.top, 1)
        }
    }
}

/// Edit, date, finish, or delete a commitment, or add one by hand.
struct CommitmentEditor: View {
    @State var commitment: Commitment
    var isNew = false
    let save: (Commitment) -> Void
    let delete: (() -> Void)?
    var openMeeting: ((String, TimeInterval?) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var hasDue = false
    @State private var due = Date()
    @State private var isDone = false

    var body: some View {
        Form {
            Section {
                TextField("What you promised", text: $commitment.text, axis: .vertical)
                TextField("To (optional)", text: Binding(get: { commitment.to ?? "" }, set: { commitment.to = $0.isEmpty ? nil : $0 }))
            }
            Section {
                Toggle("Due date", isOn: $hasDue.animation())
                if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
                Toggle("Done", isOn: $isDone)
            }
            if let id = commitment.callID, let title = commitment.callTitle {
                Section("Where you said it") {
                    VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                        Text("\(title), \(commitment.madeAt.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()))")
                        if let q = commitment.quote { Text("“\(q)”").italic().foregroundStyle(.secondary) }
                    }
                    if let openMeeting {
                        Button("Open the meeting") {
                            dismiss()
                            openMeeting(id, commitment.at)
                        }
                    }
                }
            }
            if let delete, !isNew {
                Section {
                    Button("Delete task", role: .destructive) {
                        delete()
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New task" : "Task")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    var c = commitment
                    c.text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    c.due = hasDue ? Calendar.current.startOfDay(for: due) : nil
                    c.done = isDone ? (c.done ?? Date()) : nil
                    save(c)
                    dismiss()
                }
                .disabled(commitment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            hasDue = commitment.due != nil
            due = commitment.due ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!
            isDone = commitment.done != nil
        }
    }
}
