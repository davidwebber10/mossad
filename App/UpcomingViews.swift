import AppKit
import MossadCore
import SwiftUI

/// "in 25 min", "now", "Tue 9:00 AM".
func upcomingWhen(_ m: UpcomingMeeting, now: Date = Date()) -> String {
    if m.start <= now { return "Now" }
    let minutes = Int(m.start.timeIntervalSince(now) / 60)
    if minutes < 60 { return "in \(max(1, minutes)) min" }
    return Calendar.current.isDateInToday(m.start)
        ? m.start.formatted(date: .omitted, time: .shortened)
        : m.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
}

/// One upcoming calendar event in the meeting list: a hollow dot because it has not happened, the title in
/// secondary, "2:00 PM · Zoom · Will record", and its planned length.
struct UpcomingRow: View {
    static let shown = 5
    @EnvironmentObject var controller: AppController
    let meeting: UpcomingMeeting
    var body: some View {
        // Every 15 s, so Join comes within the last minute before the start.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let soon = meeting.start.timeIntervalSince(context.date) < 600
            let joinable = meeting.start.timeIntervalSince(context.date) <= 60
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let p = meeting.platform {
                        PlatformDot(platform: p, hollow: true)
                    } else {
                        Circle().strokeBorder(Palette.ring, lineWidth: 1.5).frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary).lineLimit(1)
                    HStack(spacing: 0) {
                        Text(upcomingWhen(meeting, now: context.date)).foregroundStyle(soon ? Palette.accent : Palette.secondary)
                        Text(detail).foregroundStyle(Palette.secondary)
                    }
                    .font(.system(size: 12))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Join only when the call is about to start or running; before that, whether Mossad records it.
                if let link = meeting.link, joinable {
                    Button("Join") { NSWorkspace.shared.open(link) }.controlSize(.small)
                } else if meeting.platform != nil {
                    RecordChoiceControl(meeting: meeting, size: .compact)
                } else {
                    Text(durationLabel(meeting.end.timeIntervalSince(meeting.start))).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.secondary).fixedSize().padding(.top, 1)
                }
            }
        }
    }

    /// " · Zoom · 30 min": the record control at the right says whether Mossad records it. An invite with no call
    /// link is only a reminder.
    private var detail: String {
        guard let p = meeting.platform else { return " · No call link" }
        return " · \(p.shortName) · \(durationLabel(meeting.end.timeIntervalSince(meeting.start)))"
        return " · \(p.shortName) · " + (controller.noRecord.choice(for: meeting) == .record ? "Will record" : "Won't record")
    }
}

/// Whether Mossad records an upcoming call: a small pill ("Will record", "Won't record") that opens the three
/// choices. In the list it works without opening the meeting.
struct RecordChoiceControl: View {
    enum Size { case compact, regular }
    @EnvironmentObject var controller: AppController
    let meeting: UpcomingMeeting
    let size: Size
    @State private var hovering = false

    var body: some View {
        let choice = controller.noRecord.choice(for: meeting)
        let damaged = controller.noRecord.unreadable
        let records = choice == .record && !damaged && controller.isOn
        Menu {
            pick(.record, "Record", "Mossad records this call when it starts.", choice)
            pick(.skipThisMeeting, "Don't record this meeting", "Only this one; the next one records.", choice)
            pick(.skipSeries, "Don't record this series", "Every meeting with this title and link.", choice)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: records ? "record.circle" : "pause.circle")
                    .font(.system(size: size == .compact ? 10 : 12, weight: .semibold))
                    .foregroundStyle(records ? Palette.recording : Palette.tertiary)
                Text(label(choice, damaged: damaged))
                    .font(.system(size: size == .compact ? 11 : 12.5, weight: .medium))
                    .foregroundStyle(records ? Palette.ink : Palette.secondary)
                Image(systemName: "chevron.down").font(.system(size: size == .compact ? 7 : 8, weight: .bold)).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, size == .compact ? 8 : 10).padding(.vertical, size == .compact ? 3 : 5)
            .background(hovering ? Palette.selection : Palette.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hovering = $0 }
        .help(damaged ? "The do-not-record list could not be read; reset it in Settings, Recording." : "Choose whether Mossad records this call")
        .accessibilityLabel("Recording: \(label(choice, damaged: damaged))")
    }

    private func label(_ choice: RecordingChoice, damaged: Bool) -> String {
        if damaged { return "Not recorded" }
        if !controller.isOn { return "Mossad is off" }
        switch choice {
        case .record: return "Will record"
        case .skipThisMeeting: return "Won't record"
        case .skipSeries: return "Series off"
        }
    }

    @ViewBuilder
    private func pick(_ value: RecordingChoice, _ title: String, _ detail: String, _ current: RecordingChoice) -> some View {
        Button { controller.setRecording(value, for: meeting) } label: {
            if value == current { Label(title, systemImage: "checkmark") } else { Text(title) }
            Text(detail)
        }
    }
}
