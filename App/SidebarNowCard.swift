import MossadCore
import SwiftUI

extension AppController {
    /// The call that records now, as the sidebar's Now card shows it.
    struct NowCall: Equatable {
        let id: String
        let since: Date
    }

    /// A call or a room recording on this Mac, also while paused; in a preview, the made-up one of `MOSSAD_NOW`. Its
    /// id is the live record's own when the list has it: in the repeated hour at the end of daylight time, the id of
    /// the start can be an older call's.
    var nowCall: NowCall? {
        guard let start = nowStart ?? previewNow else { return nil }
        guard let live = meetings.first(where: { $0.isLive(recordingSince: start.since) }) else { return start }
        return NowCall(id: live.id, since: start.since)
    }

    /// The Go menu's "Current Call": the live page, as a click on the card opens it.
    func openNowCall() {
        if let id = nowCall?.id { openMeeting(id) }
    }
}

/// The call that records now, at the top of the sidebar: its title, then one state line with the recording dot
/// (`NowCard.stateLine`), so the card keeps one height. A click opens its live page from any page; the card reads
/// as selected while that page shows. It never dims with the window: during a call the call app is in front, and
/// this is where the owner looks for the mute state.
struct SidebarNowCard: View {
    @EnvironmentObject var controller: AppController
    /// In Calendar mode the Meetings page reports here which meeting it shows full-pane.
    @ObservedObject var navigation: NavigationModel
    let now: AppController.NowCall
    @State private var hovering = false

    private var record: CallRecord? { controller.meetings.first { $0.id == now.id } }

    private var shown: Bool {
        let part = navigation.meetingsPart
        return NowCard.isShown(liveID: now.id, onMeetings: controller.section == .meetings, calendarMode: part?.page == "calendar",
                               selected: controller.selectedMeetingID, openedFullPane: part?.item)
    }

    var body: some View {
        let title = NowCard.title(record)
        let on = shown
        let shape = RoundedRectangle(cornerRadius: Chrome.navRowRadius, style: .continuous)
        TimelineView(.periodic(from: now.since, by: 1)) { context in
            Button {
                if !on { controller.openMeeting(now.id) }
            } label: {
                VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                    Text(title)
                        .font(.system(size: Rhythm.bodySize, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        StatusDot(color: controller.isPaused ? Palette.tertiaryMark : Palette.recording, size: 7, pulsing: !controller.isPaused)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                        Text(NowCard.stateLine(elapsed: elapsed(now.since, context.date), paused: controller.isPaused, mute: controller.shownMute))
                            .monospacedDigit()
                            .lineLimit(1)
                            .foregroundStyle(stateColor)
                    }
                    .font(.system(size: Rhythm.secondarySize, weight: .medium))
                }
                .padding(.horizontal, Chrome.navRowPadding).padding(.vertical, Rhythm.itemGap)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    // The selection lies over the tint, as on the list's rows, so a selected card still reads as recording.
                    ZStack {
                        shape.fill(Palette.recordingTint)
                        shape.fill(on ? Palette.selection : hovering ? Palette.fill.opacity(0.5) : .clear)
                        // The selection fill alone hardly shows on the tint; the edge in the recording color does.
                        if on { shape.strokeBorder(Palette.recording.opacity(0.6), lineWidth: 1) }
                    }
                }
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(NowCard.accessibilityLabel(title: title, seconds: context.date.timeIntervalSince(now.since),
                                                           paused: controller.isPaused, mute: controller.shownMute))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        }
        .onHover { hovering = $0 }
        .contextMenu { if let record { MeetingMenuItems(record: record, deleting: .constant(nil)) } }
        .help("Open the call that records now")
    }

    /// A mute or a pause is what the owner looks here for, so it is never the card's quietest text.
    private var stateColor: Color {
        if controller.isPaused { return Palette.ink }
        return controller.shownMute.shows ? Palette.accent : Palette.secondary
    }
}
