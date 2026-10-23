import MossadCore
import SwiftUI

extension Platform {
    var symbol: String {
        switch self {
        case .zoom: "video.fill"
        case .meet: "person.3.fill"
        case .teams: "person.2.wave.2.fill"
        case .inPerson: "mic.fill"
        }
    }

    var tint: Color {
        switch self {
        case .zoom: .blue
        case .meet: .green
        case .teams: .indigo
        case .inPerson: .orange
        }
    }
}

extension CallRecord {
    var minutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }
}

/// "45 min" or "1 h 20 min".
func duration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds / 60)
    return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
}

/// "4:05" or "1:02:03".
func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// `**bold**` and links in summary text.
func rich(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}

func scoreColor(_ score: Int) -> Color { score >= 4 ? .green : score == 3 ? .yellow : .orange }

/// A rounded surface on the grouped background, for content that is not a list.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 20))
    }
}

struct CardTitle: View {
    let text: String
    var symbol: String?

    var body: some View {
        Group {
            if let symbol { Label(text, systemImage: symbol) } else { Text(text) }
        }
        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

/// The coach's score for a meeting, as a small colored "4".
struct ScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.caption.weight(.bold)).monospacedDigit()
            .foregroundStyle(scoreColor(score))
            .frame(width: 24, height: 24)
            .background(scoreColor(score).opacity(0.16), in: .circle)
            .accessibilityLabel("Coach score \(score) of 5")
    }
}

/// A big number with a label, for the grids on People and Analytics.
struct StatTile: View {
    let value: String
    let label: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.footnote).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}

struct MeetingRow: View {
    let record: CallRecord
    var score: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.platform.symbol)
                .font(.subheadline).foregroundStyle(record.platform.tint)
                .frame(width: 36, height: 36)
                .background(record.platform.tint.opacity(0.14), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    if let score { ScoreBadge(score: score) }
                }
                Text("\(record.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) · \(record.minutes) min")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if let h = record.headline {
                    Text(h).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if !record.tags.isEmpty {
                    Text(record.tags.map { "#\($0)" }.joined(separator: "  ")).font(.caption).foregroundStyle(.tint).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
