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

/// One upcoming calendar event in the meeting list.
struct UpcomingRow: View {
    static let shown = 5
    let meeting: UpcomingMeeting

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 8) {
                if let p = meeting.platform {
                    PlatformSquare(platform: p, size: 12)
                } else {
                    Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 12)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title).lineLimit(1)
                    Text(upcomingWhen(meeting, now: context.date)).font(.system(size: 11))
                        .foregroundStyle(meeting.start.timeIntervalSince(context.date) < 600 ? Color.accentColor : .secondary)
                }
                Spacer(minLength: 4)
                if let link = meeting.link {
                    Button("Join") { NSWorkspace.shared.open(link) }.controlSize(.mini)
                }
            }
            .padding(.vertical, 2)
        }
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
                    if let link = meeting.link {
                        Button("Join \(meeting.platform?.displayName ?? "the call")") { NSWorkspace.shared.open(link) }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                    }
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
