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

    @State private var relation: PersonRelation?
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if profile.isOwner || stats.meetings.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 12)], spacing: 12) {
                        stat("Meetings", "\(stats.meetings.count)")
                        stat("Total talk time", talkText(stats.totalTalk))
                        stat("Average talk share", stats.averageShare.map { "\(Int(($0 * 100).rounded()))%" } ?? "None")
                        stat("Action items", "\(stats.actionItems.count)")
                    }
                } else if let r = relation {
                    PersonBriefCard(name: profile.name, brief: controller.coachProfile.people[profile.name]?.brief, refreshing: refreshing,
                                    refresh: stats.meetings.count >= 2 ? {
                                        refreshing = true
                                        Task {
                                            await controller.writePersonBriefs([profile.name])
                                            refreshing = false
                                        }
                                    } : nil,
                                    openCall: { controller.openMeeting($0) })
                    RelationSections(relation: r, owner: controller.ownerName, color: color)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                if !stats.meetings.isEmpty {
                    WeightedColumns(weights: stats.oftenWith.isEmpty ? [1] : [2, 1]) {
                        talkByMeeting
                        if !stats.oftenWith.isEmpty { oftenWith }
                    }
                }
                if profile.isOwner, !stats.actionItems.isEmpty { actionItems }
                meetings
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .task(id: "\(profile.name)-\(controller.meetings.count)-\(controller.commitmentsVersion)") { await loadRelation() }
    }

    /// Reads the shared meetings' coach ratings off the main actor.
    private func loadRelation() async {
        guard !profile.isOwner else { return }
        let name = profile.name, owner = controller.ownerName, records = controller.meetings, paths = controller.paths
        let commitments = controller.commitmentBook.visible
        let r = await Task.detached(priority: .userInitiated) {
            let shared = records.filter { $0.speakerNames.values.contains(name) }
            let reviews = Dictionary(uniqueKeysWithValues: shared.compactMap { r in CoachReview.load(in: paths.callDirectory(r.id)).map { (r.id, $0) } })
            return PersonRelation(name: name, owner: owner, records: records, reviews: reviews, commitments: commitments)
        }.value
        withAnimation(.smooth) { relation = r }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            PersonMark(name: profile.name, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(profile.name).font(.title2.weight(.semibold)).lineLimit(1)
                    if profile.isOwner {
                        Text("You").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Theme.field, in: Capsule())
                    }
                }
                Text(summaryLine).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Menu {
                Button("Rename…", systemImage: "pencil", action: rename)
                Menu("Merge into", systemImage: "arrow.triangle.merge") {
                    ForEach(others, id: \.name) { target in Button(target.name) { merge(target) } }
                }
                .disabled(profile.isOwner || others.isEmpty)
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive, action: delete).disabled(profile.isOwner)
            } label: {
                Image(systemName: "ellipsis").accessibilityLabel("Actions")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .fixedSize()
        }
    }

    /// "jo@example.com · Since Mar 2026 · 14 meetings · 6 voice samples"
    private var summaryLine: String {
        var parts: [String] = []
        if let email = profile.email { parts.append(email) }
        if let first = stats.firstHeard { parts.append("Since " + first.formatted(.dateTime.month(.abbreviated).year())) }
        parts.append("\(stats.meetings.count) \(stats.meetings.count == 1 ? "meeting" : "meetings")")
        parts.append("\(profile.embeddings.count) voice \(profile.embeddings.count == 1 ? "sample" : "samples")")
        return parts.joined(separator: " · ")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        Card(title) {
            Text(value).font(.system(.title2, design: .rounded, weight: .semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
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
