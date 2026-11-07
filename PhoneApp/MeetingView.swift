import MossadCore
import SwiftUI

/// One meeting as the canvas draws it on the phone: where and when, the title, the lanes, then Summary,
/// Transcript, Coach, and Chat under one glass control. A time anywhere opens the transcript at that moment.
struct MeetingView: View {
    @EnvironmentObject var store: PhoneStore
    let record: CallRecord
    /// Words to find in the transcript, from Search.
    var find = ""
    @State private var query = ""
    /// The moment being read: from a lane, a decision, or a commitment. The lanes draw it as the playhead.
    @State private var moment: TimeInterval?
    // Development hook for screenshots: `MOSSAD_SECTION=coach`.
    @State private var tab = Section(rawValue: ProcessInfo.processInfo.environment["MOSSAD_SECTION"]?.capitalized ?? "") ?? .summary
    @State private var review: CoachReview?

    enum Section: String, CaseIterable { case summary = "Summary", transcript = "Transcript", coach = "Coach", chat = "Chat" }

    private var lanes: [SpeakerLanes.Lane] {
        SpeakerLanes.make(record, names: MarkdownWriter.displayNames(record), ownerName: store.owner)
    }

    private var length: TimeInterval {
        max(record.end.timeIntervalSince(record.start), lanes.lazy.compactMap { $0.segments.last?.upperBound }.max() ?? 0, 1)
    }

    var body: some View {
        let lanes = lanes
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    header
                    if !record.utterances.isEmpty {
                        PhoneLanes(lanes: lanes, duration: length, moment: moment, decisions: record.decisions,
                                   bookmarks: record.transcriptMarkers.filter(\.isBookmark)) { read(at: $0) }
                            // A chart: past this size the names would leave no room for the lanes; VoiceOver reads each lane.
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
                    PhoneSegments(options: Section.allCases.map { ($0, $0.rawValue) }, selection: $tab)
                        .frame(maxWidth: .infinity)
                    switch tab {
                    case .summary:
                        SummarySection(record: record) { read(at: $0) }
                    case .transcript:
                        TranscriptSection(record: record, lanes: lanes, query: $query, moment: moment)
                    case .coach:
                        if let review { CoachSection(record: record, review: review) } else {
                            EmptyState(symbol: "text.bubble", title: "No review for this call",
                                       message: "The coach reviews calls on your Mac. Its review appears here once it syncs.")
                        }
                    case .chat: PhoneMeetingChat(record: record)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.bottom, Space.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
            .task(id: tab == .transcript ? moment : nil) {
                guard tab == .transcript, let moment,
                      let block = TranscriptBlock.blocks(record).last(where: { $0.start <= moment + 0.5 }) else { return }
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation { proxy.scrollTo(block.id, anchor: .center) }
            }
        }
        .phonePage()
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The title is on the page, so the bar keeps only the back button; the title stays for VoiceOver and the back menu.
            ToolbarItem(placement: .principal) { Text("") }
        }
        .task(id: store.coachVersion) { review = store.coach(record.id) }
        // A commitment or a chat link asked for a moment in this meeting.
        .task(id: store.moment) {
            guard let m = store.moment, m.callID == record.id else { return }
            store.moment = nil
            read(at: m.at)
        }
        .onAppear {
            // A search that matched the transcript, not the title, opens the transcript at it.
            // Development hook for screenshots: `MOSSAD_FIND=<words>`.
            let q = (find.isEmpty ? ProcessInfo.processInfo.environment["MOSSAD_FIND"] ?? "" : find).trimmingCharacters(in: .whitespaces)
            guard query.isEmpty, !q.isEmpty, !q.hasPrefix("#"), !record.title.localizedCaseInsensitiveContains(q),
                  record.utterances.contains(where: { $0.text.localizedCaseInsensitiveContains(q) }) else { return }
            query = q
            tab = .transcript
        }
    }

    /// Opens the transcript at a moment, with the playhead there.
    private func read(at t: TimeInterval?) {
        moment = t
        query = ""
        withAnimation(.snappy) { tab = .transcript }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                PlatformDot(platform: record.platform).accessibilityHidden(true)
                Text(when).lineLimit(2)
            }
            .textRole(.secondary)
            .foregroundStyle(Palette.secondary)
            .accessibilityElement(children: .combine)
            Text(record.title)
                .textRole(.title)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            if record.titleSource == .generated {
                Label("Named by Mossad", systemImage: "sparkle")
                    .textRole(.secondary)
                    .foregroundStyle(Palette.secondary)
                    .padding(.horizontal, Space.s).padding(.vertical, 2)
                    .background(Palette.fill, in: Capsule())
            }
            // Before the transcript exists, who was invited says who the meeting was with.
            if record.utterances.isEmpty, !record.attendees.isEmpty {
                Text("With " + record.attendees.joined(separator: ", "))
                    .textRole(.secondary).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            if !record.tags.isEmpty {
                Text(record.tags.map { "#\($0)" }.joined(separator: "  "))
                    .textRole(.secondary).foregroundStyle(Palette.accent)
            }
        }
        .padding(.top, Space.s)
    }

    /// "In person · Today, 10:17 AM · 1 h 45 min"
    private var when: String {
        let cal = Calendar.current
        let day = cal.isDateInToday(record.start) ? "Today" : cal.isDateInYesterday(record.start) ? "Yesterday"
            : record.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(record.platform.displayName) · \(day), \(record.start.formatted(date: .omitted, time: .shortened)) · \(duration(record.end.timeIntervalSince(record.start)))"
    }
}

private struct SummarySection: View {
    let record: CallRecord
    private var length: TimeInterval { record.end.timeIntervalSince(record.start) }
    let read: (TimeInterval?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let line = oneLine {
                LabelColumn(label: "In one line") {
                    Text(rich(line)).textRole(.lede).lineSpacing(3).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !record.decisions.isEmpty {
                LabelColumn(label: "Decisions") { decisions }
            }
            if !bookmarks.isEmpty {
                LabelColumn(label: "Bookmarks") { bookmarkList }
            }
            MeetingCommitments(callID: record.id) { read($0) }
            if record.summary != nil, record.hasOutcomes != false || !record.actionItems.isEmpty {
                LabelColumn(label: "Action items") { actionItems }
            }
            if let summary = record.summary {
                LabelColumn(label: "Overview") { SummaryBlocks(markdown: summary) }
            } else if record.utterances.isEmpty {
                EmptyState(symbol: "doc.text.magnifyingglass", title: "No summary for this meeting",
                           message: "The summary appears here after Mossad on your Mac writes it.")
            }
            if !record.topics.isEmpty {
                LabelColumn(label: "Topics") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(record.topics.enumerated()), id: \.offset) { i, topic in
                            TopicRow(topic: topic, divided: i < record.topics.count - 1)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    /// The summary's headline; an older meeting without one shows the overview's first sentence.
    private var oneLine: String? {
        if let h = record.headline, !h.isEmpty { return h }
        guard let s = record.summary else { return nil }
        for block in SummaryBlock.parse(s) { if case .paragraph(let p) = block { return firstSentence(p) } }
        return nil
    }

    private var bookmarks: [TranscriptMarker] { record.transcriptMarkers.filter(\.isBookmark) }

    /// Each bookmark with its time and note; a tap reads from there.
    private var bookmarkList: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(bookmarks.enumerated()), id: \.offset) { _, b in
                let note = b.note?.trimmingCharacters(in: .whitespacesAndNewlines)
                Button { read(b.offset) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        HStack(spacing: 4) {
                            Image(systemName: "bookmark.fill").font(.caption2).foregroundStyle(Palette.accent)
                                .accessibilityHidden(true)
                            Text(meetingClock(b.offset, length: length))
                        }
                        .textRole(.secondary).foregroundStyle(Palette.secondary).fixedSize()
                        Group {
                            if let note, !note.isEmpty {
                                Text(note).foregroundStyle(Palette.ink)
                            } else {
                                Text("Bookmark · no note").foregroundStyle(Palette.secondary)
                            }
                        }
                        .textRole(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the transcript at the bookmark")
            }
        }
    }

    /// Each decision with the time it was made; a tap reads from there. Older meetings have no times.
    private var decisions: some View {
        let timed = record.decisions.contains { $0.at != nil }
        return VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(record.decisions.enumerated()), id: \.offset) { _, d in
                Button { if let at = d.at { read(at) } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        if timed {
                            Text(d.at.map { meetingClock($0, length: length) } ?? "")
                                .textRole(.secondary)
                                .foregroundStyle(Palette.secondary)
                                .fixedSize()
                        }
                        Text(rich(d.text)).textRole(.body).foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(d.at == nil)
                .accessibilityHint(d.at == nil ? "" : "Opens the transcript where it was decided")
            }
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        if record.actionItems.isEmpty {
            Text("None").textRole(.body).foregroundStyle(Palette.secondary)
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Array(record.actionItems.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        Image(systemName: "circle").font(.caption).foregroundStyle(Palette.tertiaryMark).accessibilityHidden(true)
                        Text(rich((item.owner.map { "**\($0)** " } ?? "") + item.task)).textRole(.body).foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Summary Markdown as paragraphs, small headings, and bullets.
struct SummaryBlocks: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(Array(SummaryBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): Text(rich(text)).textRole(.body).lineSpacing(3)
                case .heading(let text): Text(text).textRole(.headline).padding(.top, 4)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Text("•").foregroundStyle(Palette.secondary)
                                Text(rich(item))
                            }
                            .textRole(.body)
                        }
                    }
                }
            }
        }
        .foregroundStyle(Palette.ink)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A topic folded to its title; a tap opens its summary.
private struct TopicRow: View {
    let topic: SummaryTopic
    let divided: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button { withAnimation(.snappy) { open.toggle() } } label: {
                HStack {
                    Text(topic.title).textRole(.headline).foregroundStyle(Palette.ink).multilineTextAlignment(.leading)
                    Spacer(minLength: Space.s)
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(Palette.tertiaryMark)
                        .rotationEffect(.degrees(open ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "Open" : "Closed")
            if open { SummaryBlocks(markdown: topic.summary) }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { if divided { Hairline() } }
    }
}

/// "First sentence." of a paragraph, for the line under a title.
func firstSentence(_ text: String) -> String {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let end = t.range(of: #"[.!?](\s|$)"#, options: .regularExpression) else { return t }
    return String(t[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
}

private struct TranscriptSection: View {
    let record: CallRecord
    let lanes: [SpeakerLanes.Lane]
    @Binding var query: String
    var moment: TimeInterval?
    @FocusState private var focused: Bool

    /// One color per speaker, the same as their lane.
    private var hues: [String: Color] {
        var out: [String: Color] = [:]
        for (i, lane) in lanes.enumerated() where out[lane.name] == nil { out[lane.name] = Palette.speaker(i) }
        return out
    }

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = TranscriptBlock.blocks(record)
        let shown = q.isEmpty ? all : all.filter { text($0).localizedCaseInsensitiveContains(q) }
        let marked = moment.flatMap { m in all.last { $0.start <= m + 0.5 }?.id }
        let hues = hues
        LazyVStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary).accessibilityHidden(true)
                TextField("Find in transcript", text: $query)
                    .focused($focused).submitLabel(.search).autocorrectionDisabled()
                    .textRole(.body)
                if !query.isEmpty {
                    Text(matches(in: shown, q)).textRole(.secondary).foregroundStyle(Palette.secondary)
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.tertiaryMark) }
                        .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, Space.m).padding(.vertical, 10)
            .background(Palette.fill, in: Capsule())
            .padding(.bottom, Space.s)
            if !q.isEmpty && shown.isEmpty {
                ContentUnavailableView.search(text: q)
            }
            ForEach(shown) { block in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Circle().fill(hues[block.speaker] ?? Palette.tertiaryMark).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(block.speaker).textRole(.headline).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(meetingClock(block.start, length: record.end.timeIntervalSince(record.start))).textRole(.secondary).foregroundStyle(Palette.secondary)
                    }
                    Text(highlighted(text(block), q)).textRole(.body).foregroundStyle(Palette.ink)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                }
                .padding(.vertical, Space.s)
                .padding(.horizontal, block.id == marked ? Space.m : 0)
                .background(block.id == marked ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                .accessibilityElement(children: .combine)
                .id(block.id)
            }
        }
    }

    private func text(_ block: TranscriptBlock) -> String { block.lines.map(\.text).joined(separator: " ") }

    private func matches(in blocks: [TranscriptBlock], _ q: String) -> String {
        guard !q.isEmpty else { return "" }
        let n = blocks.reduce(0) { $0 + text($1).ranges(of: q, options: .caseInsensitive).count }
        return n == 1 ? "1 match" : "\(n) matches"
    }

    private func highlighted(_ text: String, _ q: String) -> AttributedString {
        var out = AttributedString(text)
        guard !q.isEmpty else { return out }
        for r in text.ranges(of: q, options: .caseInsensitive) {
            guard let lower = AttributedString.Index(r.lowerBound, within: out), let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = Palette.accentTint
            out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return out
    }
}

private extension String {
    func ranges(of needle: String, options: String.CompareOptions) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = [], start = startIndex
        while let r = range(of: needle, options: options, range: start..<endIndex) {
            out.append(r)
            start = r.upperBound
        }
        return out
    }
}

/// What you promised in this call: tap the ring to finish one, tap the text to read where you said it.
private struct MeetingCommitments: View {
    @EnvironmentObject var store: PhoneStore
    let callID: String
    let show: (TimeInterval?) -> Void
    @State private var editing: Commitment?

    var body: some View {
        let mine = store.commitments.visible.filter { $0.callID == callID }
        if !mine.isEmpty {
            LabelColumn(label: "Your commitments") {
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(mine) { c in
                        CommitmentRow(commitment: c, showSource: false, open: { show(c.at) }, toggleDone: { store.toggleDone(c.id) }) {
                            CommitmentDue(commitment: c)
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = c }
                            Button(c.done == nil ? "Mark done" : "Mark not done", systemImage: "checkmark.circle") { store.toggleDone(c.id) }
                            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteCommitment(c.id) }
                        }
                    }
                }
            }
            .sheet(item: $editing) { c in
                NavigationStack {
                    CommitmentEditor(commitment: c, save: store.saveCommitment, delete: { store.deleteCommitment(c.id) })
                }
            }
        }
    }
}
