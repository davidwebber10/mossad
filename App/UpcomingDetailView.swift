import MossadCore
import SwiftUI

/// The page of an upcoming meeting, the "before" twin of a meeting's page: the same header band (who is invited
/// where the lanes are, the record choice and Join where the player's controls are), then what to know before the
/// call in the summary's label column. The numbers are made off the main thread (`MeetingPrepStore`); this view
/// only shows them.
struct UpcomingDetailView: View {
    @EnvironmentObject var controller: AppController
    let meeting: UpcomingMeeting
    @State private var data: (id: String, prep: MeetingPrep)?
    @State private var wide = true
    /// True when the page takes longer than a moment: then it says that it is working.
    @State private var slow = false
    @State private var invitedCache = InvitedCache()
    /// The tasks marked done on this page. They stay on it as done, so a click can be taken back.
    @State private var doneHere: (id: String, tasks: Set<UUID>) = ("", [])

    /// With the label column beside it, a row must still hold a task and its moment. Narrower, the labels go above.
    private static let wideWidth: CGFloat = 600

    var body: some View {
        let key = MeetingPrepStore.Key(meeting, keep: doneHere.id == meeting.id ? doneHere.tasks : [], controller: controller)
        // The page made last stays while a new one is made, but never another meeting's.
        let shown = MeetingPrepStore.shared.cached(meeting.id, key: key) ?? (data?.id == meeting.id ? data?.prep : nil)
        // The band names the invited people at once; the numbers can take a moment the first time.
        let invited = shown?.invited ?? invitedCache.get(key) {
            MeetingPrep.invited(meeting.attendees, owner: controller.ownerName, directory: PersonDirectory(profiles: controller.library.profiles),
                                ownerEmails: [UserDefaults.standard.string(forKey: "ownerEmail") ?? ""])
        }
        GeometryReader { g in
            VStack(spacing: 0) {
                UpcomingHeader(meeting: meeting, invited: invited, prep: shown, wide: wide, maxRows: Self.maxRows(height: g.size.height))
                    .id(meeting.id)
                    .zIndex(1)
                ScrollViewReader { proxy in
                    ScrollView {
                        content(shown).detailColumn(top: 28)
                    }
                    // Development hook for screenshots: MOSSAD_SCROLL_TO names a group's label, such as "The series".
                    .onChange(of: shown?.hasFacts) { _, _ in
                        guard DevHooks.preview, let target = ProcessInfo.processInfo.environment["MOSSAD_SCROLL_TO"] else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .top)
            .clipped()
        }
        .background(Palette.window)
        .environment(\.personOpener, controller.personOpener)
        // "Last recorded together" is a link to that meeting.
        .environment(\.openURL, OpenURLAction { url in controller.openLink(url) ? .handled : .systemAction })
        .environment(\.analyticsWide, wide)
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.wideWidth } action: { wide = $0 }
        .task(id: key) {
            slow = false
            let waiting = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { slow = true }
            }
            // What the records and the tasks say comes first; the history of talk can take a while after a launch.
            // A page that already shows keeps its facts until the new ones come.
            let store = MeetingPrepStore.shared
            if data?.id != meeting.id, store.cached(meeting.id, key: key) == nil {
                let first = await store.first(for: meeting, key: key, controller: controller)
                waiting.cancel()
                guard !Task.isCancelled else { return }
                withAnimation(.smooth) { data = (meeting.id, first) }
            }
            let whole = await store.prep(for: meeting, key: key, controller: controller)
            waiting.cancel()
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { data = (meeting.id, whole) }
        }
    }

    /// The band without people (meta, title, controls, and padding) is about 200 pt tall, and a person's line can
    /// wrap onto a second one.
    private static let bandWithoutPeople: CGFloat = 200
    static let personRow: CGFloat = 36

    /// As many people as leave the page under the band its reserve, from 2 to 8; the rest open on a click.
    static func maxRows(height: CGFloat) -> Int {
        min(8, max(2, Int((height - bandWithoutPeople - Detail.lanesReserve) / personRow)))
    }

    /// Marks a task done or open again. A task marked done here stays on the page.
    private func toggle(_ task: Commitment) {
        var tasks = doneHere.id == meeting.id ? doneHere.tasks : []
        if task.done == nil { tasks.insert(task.id) }
        doneHere = (meeting.id, tasks)
        controller.toggleDone(task.id)
    }

    @ViewBuilder
    private func content(_ prep: MeetingPrep?) -> some View {
        if let prep {
            if prep.lastTime == nil, prep.promises.isEmpty, prep.series == nil, prep.coach.isEmpty, prep.tasksKnown {
                EmptyState(symbol: "calendar.badge.clock", title: "Nothing to prepare yet",
                           message: prep.people.isEmpty ? "Mossad has no earlier meeting with this title, and it does not know the invited people yet."
                               : "Mossad has no earlier meeting of this series or with these people.")
            } else {
                VStack(alignment: .leading, spacing: 26) {
                    if let line = prep.inOneLine {
                        MeetingAnalyticsGroup("Before this meeting") {
                            Text(line).font(.system(size: 16, weight: .medium)).lineSpacing(3).foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    if let last = prep.lastTime { PrepLastTime(last: last, toggle: toggle) }
                    if !prep.tasksKnown {
                        MeetingAnalyticsGroup("You promised") {
                            Text("Mossad could not read your tasks, so this page shows none of them and no state of your action items.")
                                .foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !prep.promises.isEmpty {
                        MeetingAnalyticsGroup("You promised") { PrepPromises(promises: prep.promises, more: prep.morePromises, toggle: toggle) }
                    }
                    if let series = prep.series {
                        MeetingAnalyticsGroup("The series") { PrepSeries(series: series, planned: meeting.end.timeIntervalSince(meeting.start)) }
                    }
                    if !prep.coach.isEmpty {
                        MeetingAnalyticsGroup("Coach") { PrepCoachSection(input: prep.coach) }
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your earlier meetings…").font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
            }
            .opacity(slow ? 1 : 0)
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        }
    }
}

/// The invited people of the open invite, kept between body passes. A class, so filling it during a body pass
/// does not count as a state change.
private final class InvitedCache {
    private var key: MeetingPrepStore.Key?
    private var value: [MeetingPrep.Invited] = []

    func get(_ key: MeetingPrepStore.Key, make: () -> [MeetingPrep.Invited]) -> [MeetingPrep.Invited] {
        if key == self.key { return value }
        value = make()
        self.key = key
        return value
    }
}
