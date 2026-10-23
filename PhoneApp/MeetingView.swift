import MossadCore
import SwiftUI

/// One meeting: the summary, the transcript, and the coach's review.
struct MeetingView: View {
    @EnvironmentObject var store: PhoneStore
    let record: CallRecord
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
                case .transcript: TranscriptSection(record: record)
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

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(TranscriptBlock.blocks(record)) { block in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(block.speaker).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(clock(block.start)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(block.lines.map(\.text).joined(separator: " ")).font(.subheadline).textSelection(.enabled)
                }
            }
        }
        .padding(.top, 4)
    }
}
