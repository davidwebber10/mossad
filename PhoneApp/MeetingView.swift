import MossadCore
import SwiftUI

/// One meeting: the summary, the transcript, and the coach's review.
struct MeetingView: View {
    @EnvironmentObject var store: PhoneStore
    let record: CallRecord
    /// Words to find in the transcript, from the Search tab.
    var find = ""
    @State private var query = ""
    // Development hook for screenshots: `MOSSAD_SECTION=coach`.
    @State private var tab = Section(rawValue: ProcessInfo.processInfo.environment["MOSSAD_SECTION"]?.capitalized ?? "") ?? .summary
    @State private var review: CoachReview?

    enum Section: String, CaseIterable { case summary = "Summary", transcript = "Transcript", coach = "Coach" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Picker("View", selection: $tab) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .summary: SummarySection(record: record)
                case .transcript: TranscriptSection(record: record, query: $query)
                case .coach:
                    if let review { CoachSection(record: record, review: review) } else {
                        ContentUnavailableView("No review", systemImage: "person.wave.2",
                                               description: Text("The coach has not reviewed this meeting."))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.coachVersion) { review = store.coach(record.id) }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.title).font(.title2.bold())
            HStack(spacing: 6) {
                Image(systemName: record.platform.symbol).foregroundStyle(record.platform.tint)
                Text("\(record.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())) · \(duration(record.end.timeIntervalSince(record.start)))")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if !people.isEmpty {
                Text(people.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if !record.tags.isEmpty {
                Text(record.tags.map { "#\($0)" }.joined(separator: "  ")).font(.footnote).foregroundStyle(.tint)
            }
        }
        .padding(.top, 8)
    }

    private var people: [String] { Set(record.speakerNames.values).sorted() }
}

private struct SummarySection: View {
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                if let summary = record.summary { blocks(summary) } else {
                    Text("No summary for this meeting.").foregroundStyle(.secondary)
                }
            }
            if !record.topics.isEmpty {
                Card {
                    CardTitle(text: "Topics", symbol: "list.bullet.rectangle")
                    ForEach(record.topics, id: \.self) { topic in
                        DisclosureGroup {
                            blocks(topic.summary).padding(.top, 6)
                        } label: {
                            Text(topic.title).font(.headline).foregroundStyle(.primary)
                        }
                    }
                }
            }
            if !record.actionItems.isEmpty {
                Card {
                    CardTitle(text: "Action items", symbol: "checklist")
                    ForEach(Array(record.actionItems.enumerated()), id: \.offset) { _, item in
                        Label {
                            Text(rich((item.owner.map { "**\($0)** " } ?? "") + item.task))
                        } icon: { Image(systemName: "circle").foregroundStyle(.tertiary) }
                    }
                }
            }
            if !record.decisions.isEmpty {
                Card {
                    CardTitle(text: "Decisions", symbol: "checkmark.seal")
                    ForEach(record.decisions, id: \.self) { Text(rich("•  " + $0)) }
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blocks(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SummaryBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): Text(rich(text))
                case .heading(let text): Text(text).font(.headline)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(items, id: \.self) { Text(rich("•  " + $0)) }
                    }
                }
            }
        }
    }
}

private struct TranscriptSection: View {
    let record: CallRecord
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = TranscriptBlock.blocks(record)
        let shown = q.isEmpty ? all : all.filter { text($0).localizedCaseInsensitiveContains(q) }
        LazyVStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $query)
                    .focused($focused).submitLabel(.search).autocorrectionDisabled()
                if !query.isEmpty {
                    Text("\(matches(in: shown, q))").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(.tertiarySystemFill), in: .capsule)
            if !q.isEmpty && shown.isEmpty {
                ContentUnavailableView.search(text: q)
            }
            ForEach(shown) { block in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(block.speaker).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(clock(block.start)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(highlighted(text(block), q)).font(.subheadline).textSelection(.enabled)
                }
            }
        }
        .padding(.top, 4)
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
            out[lower..<upper].backgroundColor = .yellow.opacity(0.45)
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
