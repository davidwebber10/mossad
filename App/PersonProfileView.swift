import MossadCore
import SwiftUI

/// One person's page: who they are, how much they talk, who they meet with, and what they owe.
struct PersonProfileView: View {
    @EnvironmentObject var controller: AppController
    let profile: VoiceProfile
    let stats: PersonStats
    let color: Color
    let others: [VoiceProfile]
    let rename: () -> Void
    let merge: (VoiceProfile) -> Void
    let delete: () -> Void
    let select: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12)], spacing: 12) {
                    stat("Meetings", "\(stats.meetings.count)")
                    stat("Total talk time", talkText(stats.totalTalk))
                    stat("Average talk share", stats.averageShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "None")
                    stat("Last heard", stats.lastHeard.map(dayWord) ?? "Never")
                    stat("First heard", stats.firstHeard.map(dayWord) ?? "Never")
                    stat("Voice samples", "\(profile.embeddings.count)")
                    stat("Action items", "\(stats.actionItems.count)")
                }
                if !stats.meetings.isEmpty {
                    HStack(alignment: .top, spacing: 12) {
                        talkByMeeting
                        if !stats.oftenWith.isEmpty { oftenWith.frame(width: 230) }
                    }
                }
                if !stats.actionItems.isEmpty { actionItems }
                meetings
            }
            .padding(EdgeInsets(top: 18, leading: 24, bottom: 24, trailing: 24))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12).padding(.top, 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.name).font(.system(size: 20, weight: .bold)).kerning(-0.3).lineLimit(1)
                    if profile.isOwner {
                        Text("You").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.field, in: Capsule())
                    }
                }
                if let email = profile.email {
                    Text(email).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Rename", action: rename)
                Menu("Merge into") {
                    ForEach(others, id: \.name) { target in Button(target.name) { merge(target) } }
                }
                .fixedSize()
                .disabled(profile.isOwner || others.isEmpty)
                Button("Delete", role: .destructive, action: delete)
                    .foregroundStyle(.red)
                    .disabled(profile.isOwner)
            }
            .controlSize(.small)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        Card(title) {
            Text(value).font(.system(size: 20, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var talkByMeeting: some View {
        let shown = Array(stats.meetings.prefix(10))
        let longest = max(shown.map(\.talk).max() ?? 0, 1)
        return Card("Talk time by meeting") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(shown, id: \.id) { m in
                    Button { controller.openMeeting(m.id) } label: {
                        HStack(spacing: 10) {
                            Text(m.title).lineLimit(1).frame(width: 150, alignment: .leading)
                            GeometryReader { geo in
                                Capsule().fill(color.opacity(0.85))
                                    .frame(width: max(3, geo.size.width * m.talk / longest), height: 8)
                                    .frame(maxHeight: .infinity)
                            }
                            .frame(height: 16)
                            Text(talkText(m.talk)).foregroundStyle(.secondary).monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(m.title), \(dayWord(m.start))")
                }
            }
        }
    }

    private var oftenWith: some View {
        Card("Often with") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(stats.oftenWith.prefix(8), id: \.name) { co in
                    Button { select(co.name) } label: {
                        HStack(spacing: 8) {
                            Text(co.name).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("\(co.meetings)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var actionItems: some View {
        Card("Action items") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(stats.actionItems.enumerated()), id: \.offset) { _, a in
                    Button { controller.openMeeting(a.meetingID) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "square").font(.system(size: 11)).foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.item.task).multilineTextAlignment(.leading)
                                Text("\(a.meetingTitle) · \(dayWord(a.start))").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var meetings: some View {
        Card("Meetings") {
            if stats.meetings.isEmpty {
                Text("No meetings yet.").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(stats.meetings, id: \.id) { m in
                        Button { controller.openMeeting(m.id) } label: {
                            HStack(spacing: 8) {
                                PlatformSquare(platform: m.platform)
                                Text(m.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(dayWord(m.start)).frame(width: 90, alignment: .trailing)
                                Text(talkText(m.talk)).frame(width: 64, alignment: .trailing)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// "1 h 5 min", "12 min", or "40 s" under a minute.
func talkText(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    let minutes = s / 60
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
}
