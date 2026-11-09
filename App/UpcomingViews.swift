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
    @State private var hovering = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            let soon = meeting.start.timeIntervalSince(context.date) < 600
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
                if let link = meeting.link, soon || hovering {
                    Button("Join") { NSWorkspace.shared.open(link) }.controlSize(.small)
                } else {
                    Text(durationLabel(meeting.end.timeIntervalSince(meeting.start))).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.secondary).fixedSize().padding(.top, 1)
                }
            }
        }
        .onHover { hovering = $0 }
    }

    /// " · Zoom · Will record": Mossad records any call it detects; an invite with no call link is only a reminder.
    private var detail: String {
        guard let p = meeting.platform else { return " · No call link" }
        guard controller.isOn else { return " · \(p.shortName)" }
        return " · \(p.shortName) · " + (controller.noRecord.choice(for: meeting) == .record ? "Will record" : "Won't record")
    }
}

/// An upcoming meeting: when, who, the call link, and what happened at the earlier meetings with this title.
struct UpcomingDetailView: View {
    @EnvironmentObject var controller: AppController
    let meeting: UpcomingMeeting

    var body: some View {
        let earlier = meeting.earlier(in: controller.meetings)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title).font(.system(size: 20, weight: .bold)).kerning(-0.3).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Text("\(dayWord(meeting.start)) · \((meeting.start..<max(meeting.end, meeting.start)).formatted(.interval.hour().minute()))")
                        if let p = meeting.platform { Text("· \(p.displayName)") }
                    }
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if let link = meeting.link {
                            Button("Join \(meeting.platform?.displayName ?? "the call")") { NSWorkspace.shared.open(link) }
                                .buttonStyle(.borderedProminent)
                        }
                        Picker("Recording", selection: Binding(get: { controller.noRecord.choice(for: meeting) },
                                                               set: { controller.setRecording($0, for: meeting) })) {
                            Text("Record").tag(RecordingChoice.record)
                            Text("Don't record this meeting").tag(RecordingChoice.skipThisMeeting)
                            Text("Don't record this series").tag(RecordingChoice.skipSeries)
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    .padding(.top, 4)
                }
                if !meeting.attendees.isEmpty {
                    Card("Invited") {
                        Text(meeting.attendees.joined(separator: ", ")).textSelection(.enabled)
                    }
                }
                if let last = earlier.first {
                    Card("Last time, \(last.start.formatted(.dateTime.month(.abbreviated).day()))") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let h = last.headline { Text(h) }
                            let open = last.actionItems
                            if !open.isEmpty {
                                Text("Action items").font(.system(size: 12, weight: .semibold)).padding(.top, 4)
                                ForEach(Array(open.enumerated()), id: \.offset) { _, item in
                                    Text("•  \(item.text)").foregroundStyle(.secondary)
                                }
                            }
                            Button("Open the meeting") { controller.openMeeting(last.id) }.buttonStyle(.link)
                        }
                    }
                }
                if earlier.count > 1 {
                    Card("Earlier in this series") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(earlier.dropFirst().prefix(8), id: \.id) { r in
                                Button { controller.openMeeting(r.id) } label: {
                                    HStack {
                                        Text(r.start.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                        Text(r.headline ?? r.title).lineLimit(1)
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if earlier.isEmpty {
                    Text("No earlier meeting with this title.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(EdgeInsets(top: 18, leading: 24, bottom: 24, trailing: 24))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
