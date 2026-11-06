import MossadCore
import SwiftUI

/// The band at the top of a meeting: where and when, the title, the length, and the lanes player. The tabs sit
/// on its lower edge.
struct MeetingHeader: View {
    @EnvironmentObject var controller: AppController
    let record: CallRecord
    let people: MeetingPeople
    let lanes: [SpeakerLanes.Lane]
    @ObservedObject var player: AudioPlayer
    var retentionDays: Int?
    var maxLanes = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            meta
            HStack(alignment: .lastTextBaseline, spacing: Space.xl) {
                EditableMeetingTitle(record: record, size: 26)
                    .frame(maxWidth: 740, alignment: .leading)
                Spacer(minLength: 0)
                if record.status != .recording {
                    Text(longClock(length))
                        .font(.system(size: 26, weight: .semibold)).tracking(26 * -0.02).monospacedDigit()
                        .foregroundStyle(Palette.secondary)
                        .fixedSize()
                        .accessibilityLabel("Length \(record.lengthText)")
                }
            }
            .padding(.top, 6)
            banner
            // Also while the call processes or when nobody spoke: the audio plays before there are lanes.
            if record.status != .recording {
                LanesPlayer(player: player, record: record, people: people, lanes: lanes, retentionDays: retentionDays, maxLanes: maxLanes)
                    .padding(.top, 38)
            }
        }
        .frame(maxWidth: 980, alignment: .leading)
        .padding(.horizontal, 36)
        .padding(.top, 30)
        .padding(.bottom, record.status == .recording ? Space.xl : 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.band)
        .hairline(.bottom)
    }

    /// The audio's length once it loads, else the call's.
    private var length: TimeInterval {
        player.duration > 0 ? player.duration : record.end.timeIntervalSince(record.start)
    }

    /// Wraps onto a second line rather than clip when a meeting has many tags.
    private var meta: some View {
        FlowLayout(spacing: Space.s) {
            HStack(spacing: Space.s) {
                PlatformDot(platform: record.platform)
                Text(when).font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            }
            .frame(minHeight: 20)
            if let kind = record.kind { TagChip(text: kind) }
            if record.titleSource == .generated { NamedByMossadTag().frame(minHeight: 20) }
            if record.status == .written { TagRow(record: record) }
            if record.status == .written, !record.unknownSpeakers.isEmpty {
                let n = record.unknownSpeakers.count
                Button { controller.namingCallID = record.id } label: {
                    NeedsYouChip(text: "\(n) \(n == 1 ? "voice needs" : "voices need") names")
                }
                .buttonStyle(.plain)
                .help("Name the voices Mossad does not know")
            }
        }
    }

    /// "In person · Today, 10:17 AM – 12:02 PM".
    private var when: String {
        let day = Self.day(record.start)
        if record.status == .recording {
            return "\(record.platform.displayName) · \(day), started \(record.start.formatted(date: .omitted, time: .shortened))"
        }
        let range = (record.start..<max(record.end, record.start)).formatted(.interval.hour().minute())
        return "\(record.platform.displayName) · \(day), \(range)"
    }

    /// "Today", "Yesterday", a weekday within the week, else the date.
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) || cal.isDateInYesterday(date) { return dayWord(date) }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return dayWord(date)
    }

    @ViewBuilder
    private var banner: some View {
        if let step = ProcessingStep(status: record.status) {
            ProcessingCard(record: record, step: step).padding(.top, Space.l)
        } else if record.status == .failed {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.accentFill)
                Text(failureText).foregroundStyle(Palette.ink)
                Spacer()
                Button("Retry now") { controller.retry(record.id) }.controlSize(.small)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, Space.m).padding(.vertical, 9)
            .background(Palette.accentTint, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .padding(.top, Space.l)
        }
    }

    private var failureText: String {
        let step = record.failedStep.flatMap { ProcessingStep(status: $0) }?.title ?? "Processing"
        return "\(step) failed" + (record.failureReason.map { ": \($0)" } ?? "")
    }
}
