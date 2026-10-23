import MossadCore
import SwiftUI

extension Commitment.Status {
    var tint: Color {
        switch self {
        case .overdue: .red
        case .dueToday: .orange
        case .upcoming: .secondary
        case .noDate: .secondary
        case .done: .green
        }
    }
}

/// One commitment: a circle to mark it done, what it is, who it was for and where, and when it is due.
struct CommitmentRow: View {
    let commitment: Commitment
    /// Off inside a meeting, where the meeting is already clear.
    var showSource = true
    let toggleDone: () -> Void

    var body: some View {
        let status = commitment.status()
        HStack(alignment: .top, spacing: 10) {
            Button(action: toggleDone) {
                Image(systemName: commitment.done == nil ? "circle" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(commitment.done == nil ? Color.secondary : Color.green)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(commitment.done == nil ? "Mark done" : "Mark not done")
            .sensoryFeedback(.success, trigger: commitment.done != nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(commitment.text)
                    .strikethrough(commitment.done != nil)
                    .foregroundStyle(commitment.done == nil ? Color.primary : Color.secondary)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let due = commitment.due, commitment.done == nil {
                Text(dueText(due, status))
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(status.tint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(status.tint.opacity(status == .upcoming ? 0.1 : 0.14), in: Capsule())
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: String {
        var parts: [String] = []
        if let to = commitment.to { parts.append("To \(to)") }
        if !showSource {
            return parts.joined(separator: " · ")
        } else if let title = commitment.callTitle {
            parts.append("\(title), \(commitment.madeAt.formatted(.dateTime.month(.abbreviated).day()))")
        } else {
            parts.append("Added \(commitment.created.formatted(.dateTime.month(.abbreviated).day()))")
        }
        return parts.joined(separator: " · ")
    }

    private func dueText(_ due: Date, _ status: Commitment.Status) -> String {
        switch status {
        case .overdue:
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: due), to: Calendar.current.startOfDay(for: Date())).day ?? 0
            return days == 1 ? "1 day late" : "\(days) days late"
        case .dueToday: return "Today"
        default:
            return Calendar.current.isDateInTomorrow(due) ? "Tomorrow" : due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
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
                    VStack(alignment: .leading, spacing: 4) {
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
                    Button("Delete commitment", role: .destructive) {
                        delete()
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New commitment" : "Commitment")
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
