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
                EditableMeetingTitle(record: record, size: Detail.titleSize)
                    .frame(maxWidth: Detail.titleMax, alignment: .leading)
                Spacer(minLength: 0)
                if record.status == .recording {
                    TimelineView(.periodic(from: record.start, by: 1)) { context in
                        clockText(context.date.timeIntervalSince(record.start))
                    }
                    .accessibilityLabel("Recording time")
                } else {
                    clockText(length).accessibilityLabel("Length \(record.lengthText)")
                }
            }
            .padding(.top, 6)
            if record.status == .recording { LiveBand(record: record) }
            banner
            // Also while the call processes or when nobody spoke: the audio plays before there are lanes.
            if record.status != .recording {
                LanesPlayer(player: player, record: record, people: people, lanes: lanes, retentionDays: retentionDays, maxLanes: maxLanes)
                    .padding(.top, 38)
            }
        }
        .bandColumn()
        .padding(.vertical, Detail.bandPadding)
        .bandFrame()
        .background(Palette.band)
        .hairline(.bottom)
    }

    private func clockText(_ seconds: TimeInterval) -> some View {
        Text(longClock(seconds))
            .font(.system(size: Detail.titleSize, weight: .semibold)).tracking(Detail.titleSize * -0.02).monospacedDigit()
            .foregroundStyle(Palette.secondary)
            .fixedSize()
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
            if let source = record.sourceLabel { SourceMark(text: source).frame(minHeight: 20) }
            // The notes in Google Docs, for a notes-only meeting and for a recording that has them.
            if let url = record.gemini?.url {
                Link(destination: url) { SourceMark(text: "Notes by Gemini ↗") }
                    .frame(minHeight: 20)
                    .help("Opens Gemini's notes in Google Docs")
            }
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
        if let step = ProcessingStep(status: record.status), record.summary != nil {
            ProcessingCard(record: record, step: step).padding(.top, Space.l)
        } else if record.status == .failed {
            ErrorCard(error: failure, retryTitle: "Retry now", retry: { controller.retry(record.id) }, note: "The audio is saved.")
                .padding(.top, Space.l)
        }
    }

    /// What failed and what to do. A call that never reached a step (a track could not be read) says so.
    private var failure: FriendlyError {
        if let f = record.friendlyFailure { return f }
        let step = record.failedStep.flatMap { ProcessingStep(status: $0) }
        return FriendlyError(kind: .other, context: step.map(FriendlyError.Context.init(step:)) ?? .transcribing,
                             said: record.attempts == 0 ? "The recording was interrupted, and a track could not be read." : nil, retries: false)
    }
}

