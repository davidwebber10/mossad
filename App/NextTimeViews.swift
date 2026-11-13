import MossadCore
import SwiftUI

// MARK: Shared parts

/// A moment of a meeting: opens it and plays from there.
struct SeriesMoment: View {
    @EnvironmentObject var controller: AppController
    let callID: String
    var at: TimeInterval?
    var label: String?

    var body: some View {
        Button {
            if let at { controller.openMeeting(callID, at: at) } else { controller.openMeeting(callID) }
        } label: {
            HStack(spacing: Space.xs) {
                IconImage(at == nil ? .chevronRight : .play, size: 8)
                Text(label ?? at.map(clock) ?? "Open meeting").monospacedDigit()
            }
            .font(.system(size: Rhythm.secondarySize, weight: .semibold))
            .foregroundStyle(Palette.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(at == nil ? "Open the meeting" : "Open the meeting and play from \(clock(at!))")
    }
}

/// A small quiet button: "Keep", "Undo".
struct QuietButton: View {
    let title: String
    var accent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: Rhythm.secondarySize, weight: .semibold))
                .foregroundStyle(accent ? Palette.onAccent : Palette.ink)
                .padding(.horizontal, 10).frame(height: 24)
                .background(accent ? Palette.accentFill : Palette.fill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: The owner's points

/// The owner's open points of one list, in their order: edit in place, mark done, move, delete, and add at the end.
struct NextTimeList: View {
    @EnvironmentObject var controller: AppController
    let points: [NextTimePoint]
    /// What a new point is for.
    let add: (String) -> Void
    var placeholder = "Add a point for next time"
    var canAdd = true
    @State private var draft = ""
    @State private var editing: UUID?
    @State private var editText = ""
    @FocusState private var focus: Field?

    enum Field: Hashable { case add, edit(UUID) }

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            ForEach(Array(points.enumerated()), id: \.element.id) { n, p in
                row(p, index: n)
                    .draggable(p.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        guard let moved = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                        move(moved, before: p.id)
                        return true
                    }
            }
            if canAdd { addRow }
        }
    }

    private var addRow: some View {
            HStack(spacing: Space.m) {
                IconImage(.plus, size: 12).foregroundStyle(Palette.tertiary).frame(width: 16)
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: Rhythm.bodySize))
                    .focused($focus, equals: .add)
                    .onSubmit {
                        guard case let text = draft.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
                        add(text)
                        draft = ""
                        focus = .add
                    }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(Palette.fill.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.top, points.isEmpty ? 0 : 6)
    }

    private func row(_ p: NextTimePoint, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Button { controller.changeNextTime { $0.toggleDone(p.id) } } label: {
                Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 14, height: 14).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Mark done")
            .accessibilityLabel("Mark \(p.text) done")
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                if editing == p.id {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .edit(p.id))
                        .onSubmit { commit(p) }
                        .onExitCommand { editing = nil }
                } else {
                    Text(p.text).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) { startEdit(p) }
                }
                note(p)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Edit") { startEdit(p) }
                Button("Move up") { reorder(p.id, by: -1) }.disabled(index == 0)
                Button("Move down") { reorder(p.id, by: 1) }.disabled(index == points.count - 1)
                Divider()
                Button("Delete", role: .destructive) { controller.changeNextTime { $0.delete(p.id) } }
            } label: {
                IconImage(.more, size: 14).foregroundStyle(Palette.tertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(p.text)")
        }
        .font(.system(size: Rhythm.bodySize))
        .padding(.vertical, 6).padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    /// "Carried from Nov 3" or "Suggested by the coach".
    @ViewBuilder
    private func note(_ p: NextTimePoint) -> some View {
        let carried = (p.carried ?? []).count
        let parts = [carried > 0 ? "Not discussed in the last \(carried == 1 ? "meeting" : "\(carried) meetings")" : nil,
                     p.suggestion != nil ? "Kept from the coach" : nil, p.isForPerson ? p.personName.map { "For \($0)" } : nil].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · ")).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
        }
        if p.isOpen, let m = p.lastMention { MentionNote(mention: m) }
    }

    private func startEdit(_ p: NextTimePoint) {
        editText = p.text
        editing = p.id
        focus = .edit(p.id)
    }

    private func commit(_ p: NextTimePoint) {
        if case let text = editText.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != p.text { controller.changeNextTime { $0.update(p.id) { $0.text = text } } }
        editing = nil
    }

    private func reorder(_ id: UUID, by: Int) {
        var ids = points.map(\.id)
        guard let i = ids.firstIndex(of: id), ids.indices.contains(i + by) else { return }
        ids.swapAt(i, i + by)
        controller.changeNextTime { $0.reorder(ids) }
    }

    private func move(_ id: UUID, before target: UUID) {
        guard id != target else { return }
        var ids = points.map(\.id)
        guard ids.contains(id) else { return }
        ids.removeAll { $0 == id }
        ids.insert(id, at: ids.firstIndex(of: target) ?? ids.count)
        controller.changeNextTime { $0.reorder(ids) }
    }
}

/// "Came up on Nov 12, in a meeting Mossad has only the notes of ▸ 12:04": words that are true whether or not the
/// owner listened. The lists hold open points only, so it never shows on a closed one.
struct MentionNote: View {
    let mention: NextTimePoint.Mention

    var body: some View {
        HStack(spacing: Space.s) {
            Text("Came up on \(mention.date.formatted(.dateTime.month(.abbreviated).day())), in a meeting Mossad has only the notes of")
                .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
            SeriesMoment(callID: mention.callID, at: mention.at)
        }
        .help("\u{201C}\(mention.quote)\u{201D}")
    }
}

/// A point that was discussed: where, with its moment, and the way to take it back.
struct DiscussedRow: View {
    @EnvironmentObject var controller: AppController
    let point: NextTimePoint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            IconImage(.checkSmall, size: 14).foregroundStyle(Palette.accent).frame(width: 14)
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                Text(point.text).foregroundStyle(Palette.secondary).strikethrough(color: Palette.tertiaryMark)
                HStack(spacing: Space.s) {
                    if let d = point.done {
                        // The day of the meeting, not of the check.
                        let day = d.callID.flatMap { id in controller.meetings.first { $0.id == id }?.start } ?? d.date
                        Text(d.byOwner ? "Marked done \(shortDay(day))" : "Discussed \(shortDay(day))")
                            .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
                        // Only a meeting that exists: a chip to a skipped call would open "Select a meeting".
                        if let call = d.callID, controller.meetings.contains(where: { $0.id == call }) { SeriesMoment(callID: call, at: d.at) }
                    }
                }
                if let q = point.done?.quote {
                    Text("\u{201C}\(q)\u{201D}").font(.system(size: Rhythm.secondarySize)).italic().foregroundStyle(Palette.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            QuietButton(title: "Undo") { controller.changeNextTime { $0.toggleDone(point.id) } }
                .help(point.done?.byOwner == false ? "Not discussed after all: the point goes back to the list" : "Open the point again")
        }
        .font(.system(size: Rhythm.bodySize))
        .padding(.vertical, 6).padding(.horizontal, 8)
    }
}

// MARK: The coach's suggestions

/// The coach's suggestions, apart from the owner's points: each with its source, Keep, and Dismiss. A no lowers
/// that kind, as on the Findings deck; "Never" stops the kind until Undo.
struct SuggestionList: View {
    @EnvironmentObject var controller: AppController
    let series: MeetingSeries
    let suggestions: [SeriesSuggestion]
    @State private var last: (key: String, words: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: Rhythm.pairGap) {
            if let last {
                HStack(spacing: Space.s) {
                    Text(last.words).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                    Button("Undo") {
                        controller.changeNextTime { $0.takeBack(last.key) }
                        self.last = nil
                    }
                    .buttonStyle(.plain).font(.system(size: Rhythm.secondarySize, weight: .semibold)).foregroundStyle(Palette.accent)
                }
                .padding(.horizontal, 8).padding(.bottom, 4)
            }
            OffKinds(answers: controller.series.book.answers)
            if suggestions.isEmpty {
                Text("No suggestions now. The coach suggests a point only from something Mossad knows: an open action item, a task of yours that is due, a decision left open, a question with no answer, or your coach goal.")
                    .font(.system(size: Rhythm.bodySize)).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(suggestions) { s in row(s) }
        }
    }

    private func row(_ s: SeriesSuggestion) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            IconImage(.sparkle, size: 13).foregroundStyle(Palette.accent).frame(width: 14)
            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                Text(s.text).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s) {
                    Text(s.source.label).font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
                    if let call = s.source.callID { SeriesMoment(callID: call, at: s.source.at) }
                }
            }
            Spacer(minLength: 8)
            QuietButton(title: "Keep", accent: true) {
                controller.changeNextTime { book in
                    book.add(s.text, series: series, suggestion: s.key)
                    book.answer(s, .keep)
                }
                last = (s.key, "Moved to your points.")
            }
            .help("Move it into your points for next time")
            Menu {
                Button("Dismiss") { dismiss(s, .dismiss) }
                Button("Never suggest \(s.kind.title.lowercased())") { dismiss(s, .never) }
            } label: {
                Text("Dismiss").font(.system(size: Rhythm.secondarySize, weight: .semibold)).foregroundStyle(Palette.ink)
            } primaryAction: {
                dismiss(s, .dismiss)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Not useful: the coach suggests fewer of this kind")
        }
        .font(.system(size: Rhythm.bodySize))
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(Palette.accentTint.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func dismiss(_ s: SeriesSuggestion, _ verdict: SuggestionAnswer.Verdict) {
        controller.changeNextTime { $0.answer(s, verdict) }
        last = (s.key, verdict == .never ? "No more \(s.kind.title.lowercased()) for now." : "Dismissed. The coach suggests fewer of this kind.")
    }
}

/// The kinds of suggestion that are off, blocked with "Never" or lowered by dismissals, with the way to turn them on.
private struct OffKinds: View {
    @EnvironmentObject var controller: AppController
    let answers: [SuggestionAnswer]

    var body: some View {
        let training = SuggestionTraining(answers: answers)
        ForEach(training.off, id: \.self) { kind in
            HStack(spacing: Space.s) {
                Text("Off: \(kind.title)\(training.isBlocked(kind) ? "" : ", after your dismissals")")
                    .font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.secondary)
                Button("Turn on") { controller.changeNextTime { $0.allowAgain(kind) } }
                    .buttonStyle(.plain).font(.system(size: Rhythm.secondarySize, weight: .semibold)).foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, 8)
        }
    }
}

// MARK: For other pages

/// "Next time I see Sam": the owner's points for one person. A small section any page can show (the person page
/// can include it); it edits the same list as the series pages.
struct PersonNextTimeSection: View {
    @EnvironmentObject var controller: AppController
    let personID: String
    let name: String
    /// The person page's layout: the title in the label column at the left.
    var inColumn = false

    var body: some View {
        let title = "Next time I see \(SeriesNames.first(name))"
        Group {
            if inColumn {
                LabelColumn(label: title) { list }
            } else {
                VStack(alignment: .leading, spacing: Rhythm.itemGap) {
                    Text(title).textRole(.label).foregroundStyle(Palette.secondary).accessibilityAddTraits(.isHeader)
                    list
                }
            }
        }
        .task(id: controller.peopleStamp) { controller.refreshSeries() }
        .task {
            // Chat, the MCP, and the phone write the points too.
            while !Task.isCancelled {
                controller.series.reload(controller.paths)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var list: some View {
        // The people as saved now: a merge on the People page shows before the catalog is made again.
        let points: [NextTimePoint]
        if let people = controller.library.identity?.people.people {
            points = controller.series.book.points(forPerson: personID, people: people)
        } else {
            let refs = controller.series.people
            points = controller.series.book.points(forPerson: personID, canonical: { refs.canonical($0) })
        }
        return NextTimeList(points: points, add: { text in controller.changeNextTime { $0.add(text, personID: personID, personName: name) } },
                            placeholder: "Add a point for \(SeriesNames.first(name))")
    }
}

/// The prep page's first group: the owner's own points for this meeting, its series' and its people's.
struct PrepYourPoints: View {
    @EnvironmentObject var controller: AppController
    let meeting: UpcomingMeeting

    var body: some View {
        let series = SeriesCatalog.series(of: meeting, in: controller.series.all)
        let own = series.map { controller.series.book.points(of: $0).open } ?? []
        let refs = controller.series.people
        // Each invited person with points of their own, as a list of its own: a drag never mixes two lists.
        let people = (controller.series.invitedIDs[meeting.id] ?? []).compactMap { id -> (id: String, name: String)? in
            guard !controller.series.book.points(forPerson: id, canonical: { refs.canonical($0) }).isEmpty else { return nil }
            return (id, refs.name(of: id) ?? id)
        }
        if series != nil || !people.isEmpty {
            MeetingAnalyticsGroup("Your points") {
                VStack(alignment: .leading, spacing: Rhythm.rowGap) {
                    if let series {
                        NextTimeList(points: own, add: { text in controller.changeNextTime { $0.add(text, series: series) } })
                    }
                    ForEach(people, id: \.id) { p in PersonNextTimeSection(personID: p.id, name: p.name) }
                    if let series {
                        Button { controller.openSeries(series.id) } label: {
                            HStack(spacing: Space.xs) {
                                Text("All of \(series.title)")
                                IconImage(.chevronRight, size: 9)
                            }
                            .font(.system(size: Rhythm.secondarySize, weight: .semibold)).foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

enum SeriesNames {
    static func first(_ name: String) -> String { name.contains("@") ? name : String(name.split(separator: " ").first ?? Substring(name)) }
}

/// Under a meeting: the owner's points it discussed (with the moment), and the ones it left for next time.
struct MeetingPointsGroup: View {
    @EnvironmentObject var controller: AppController
    let callID: String

    /// Whether the group shows anything for this meeting. The page leaves the group out when it does not, so an
    /// empty group takes no section gap; the page reads the book itself (`loadsPoints`).
    static func hasContent(_ book: NextTimeBook, callID: String) -> Bool {
        !book.discussed(in: callID).isEmpty || !book.mentioned(in: callID).isEmpty
            || book.visible.contains { $0.isOpen && ($0.carried ?? []).contains(callID) }
    }

    var body: some View {
        let book = controller.series.book
        let discussed = book.discussed(in: callID)
        let carried = book.visible.filter { $0.isOpen && ($0.carried ?? []).contains(callID) }
        // A meeting the owner missed (notes only, with no line of theirs) closes and carries nothing: its open points that came up are listed.
        let mentioned = book.mentioned(in: callID)
        VStack(spacing: 0) {
            if !mentioned.isEmpty {
                LabelColumn(label: "Your open points in these notes") {
                    VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                        ForEach(mentioned) { p in
                            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                                Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 14, height: 14)
                                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                                    Text(p.text)
                                    if let m = p.mentions?.first(where: { $0.callID == callID }) {
                                        HStack(spacing: Space.s) {
                                            Text("Still open. Mossad has only the notes of this meeting").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
                                            SeriesMoment(callID: callID, at: m.at)
                                        }
                                        Text("\u{201C}\(m.quote)\u{201D}").font(.system(size: Rhythm.secondarySize)).italic().foregroundStyle(Palette.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 8)
                            }
                            .font(.system(size: Rhythm.bodySize))
                            .padding(.vertical, 6).padding(.horizontal, 8)
                        }
                    }
                }
            }
            if !discussed.isEmpty || !carried.isEmpty {
                LabelColumn(label: "Your points") {
                    VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                        ForEach(discussed) { DiscussedRow(point: $0) }
                        ForEach(carried) { p in
                            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                                Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 14, height: 14)
                                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                                    Text(p.text)
                                    Text("Not discussed: carried to the next meeting").font(.system(size: Rhythm.secondarySize)).foregroundStyle(Palette.tertiary)
                                }
                                Spacer(minLength: 8)
                                QuietButton(title: "It was discussed") {
                                    controller.changeNextTime { $0.update(p.id) { $0.done = .init(callID: callID, at: nil, quote: nil, date: Date(), byOwner: true) } }
                                }
                            }
                            .padding(.vertical, 6).padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
        .loadsPoints()
    }
}

extension View {
    /// Reads the owner's points book when the view appears, so a page that shows points never waits for another view
    /// to read it. Put it on a view that always exists.
    func loadsPoints() -> some View { modifier(LoadsPoints()) }
}

private struct LoadsPoints: ViewModifier {
    @EnvironmentObject var controller: AppController

    func body(content: Content) -> some View {
        content.task { controller.series.owner = controller; controller.series.reload(controller.paths) }
    }
}
