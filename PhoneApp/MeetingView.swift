import MossadCore
import SwiftUI

/// One meeting: the summary, the transcript, and the coach's review.
struct MeetingView: View {
    @EnvironmentObject var store: PhoneStore
    let record: CallRecord
    @State private var tab = Section.summary

    enum Section: String, CaseIterable { case summary = "Summary", transcript = "Transcript", coach = "Coach" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.start.formatted(.dateTime.weekday(.wide).month(.wide).day().hour().minute()) + " · \(record.platform.displayName)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(people).font(.footnote).foregroundStyle(.secondary)
                }
                Picker("View", selection: $tab) {
                    ForEach(Section.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .summary: SummarySection(record: record)
                case .transcript: TranscriptSection(record: record)
                case .coach: CoachSection(review: store.coach(record.id))
                }
            }
            .padding()
        }
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var people: String {
        Set(record.speakerNames.values).sorted().joined(separator: ", ")
    }
}

/// `**bold**` and links in summary text.
func rich(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

private struct SummarySection: View {
    let record: CallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let summary = record.summary {
                blocks(summary)
            } else {
                Text("No summary for this meeting.").foregroundStyle(.secondary)
            }
            ForEach(record.topics, id: \.self) { topic in
                DisclosureGroup {
                    blocks(topic.summary).padding(.top, 6)
                } label: {
                    Text(topic.title).font(.headline)
                }
            }
            if !record.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action items").font(.headline)
                    ForEach(Array(record.actionItems.enumerated()), id: \.offset) { _, item in
                        Label {
                            Text(rich((item.owner.map { "**\($0)** " } ?? "") + item.task)).font(.subheadline)
                        } icon: { Image(systemName: "circle").foregroundStyle(.secondary) }
                    }
                }
            }
            if !record.decisions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Decisions").font(.headline)
                    ForEach(record.decisions, id: \.self) { d in
                        Label(d, systemImage: "checkmark.seal").font(.subheadline)
                    }
                }
            }
        }
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
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(TranscriptBlock.blocks(record)) { block in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(block.speaker).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(clock(block.start)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(block.lines.map(\.text).joined(separator: " ")).font(.subheadline).textSelection(.enabled)
                }
            }
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct CoachSection: View {
    let review: CoachReview?

    var body: some View {
        if let review {
            VStack(alignment: .leading, spacing: 16) {
                Text(review.headline).font(.headline)
                Text(review.overview).foregroundStyle(.secondary)
                if let v = review.value {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting value: \(v.rating.rawValue.capitalized)").font(.subheadline.weight(.semibold))
                        Text(v.reason).font(.subheadline).foregroundStyle(.secondary)
                        if v.action != .keep { Text(v.suggestion).font(.subheadline) }
                    }
                }
                points("What worked", review.strengths, tint: .green)
                points("Try next time", review.improvements, tint: .orange)
            }
        } else {
            Text("The coach has not reviewed this meeting.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func points(_ title: String, _ list: [CoachPoint], tint: Color) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline).foregroundStyle(tint)
                ForEach(list, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.title).font(.subheadline.weight(.semibold))
                        Text(p.observation).font(.subheadline)
                        Text("“\(p.quote)”").font(.subheadline).italic().foregroundStyle(.secondary)
                        if let t = p.tryInstead { Text("Try: \(t)").font(.subheadline) }
                    }
                }
            }
        }
    }
}
