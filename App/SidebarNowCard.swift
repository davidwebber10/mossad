import MossadCore
import SwiftUI

extension AppController {
    /// The call that records now, as the sidebar's Now card shows it.
    struct NowCall: Equatable {
        let id: String
        let since: Date
    }

    /// A call or a room recording on this Mac; in a preview, the made-up one of `MOSSAD_NOW`.
    var nowCall: NowCall? {
        if case .recording(_, let since) = status { return NowCall(id: CallRecorder.callID(for: since), since: since) }
        return previewNow
    }
}

/// The call that records now, at the top of the sidebar: its title, then the recording dot and the time so far with
/// "paused" or the mute words. A click opens its live page from any page; the card reads as selected while that
/// page shows.
struct SidebarNowCard: View {
    @EnvironmentObject var controller: AppController
    /// In Calendar mode the Meetings page reports here which meeting it shows full-pane.
    @ObservedObject var navigation: NavigationModel
    let now: AppController.NowCall
    @Environment(\.appearsActive) private var appearsActive
    @State private var hovering = false

    private var record: CallRecord? { controller.meetings.first { $0.id == now.id } }

    private var shown: Bool {
        let part = navigation.part(.meetings)
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
                        let time = elapsed(now.since, context.date)
                        // One line when it fits; else the note goes on a line of its own, never cut in the middle.
                        ViewThatFits(in: .horizontal) {
                            Text(controller.shownMute.recordingLine(elapsed: time, paused: controller.isPaused))
                                .lineLimit(1)
                            VStack(alignment: .leading, spacing: Rhythm.pairGap) {
                                Text("Recording \(time)").lineLimit(1)
                                if let note = controller.shownMute.note(paused: controller.isPaused) { Text(note).lineLimit(2) }
                            }
                        }
                        .monospacedDigit()
                    }
                    .font(.system(size: Rhythm.secondarySize, weight: .medium))
                    .foregroundStyle(Palette.secondary)
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
        .opacity(appearsActive ? 1 : 0.55)
    }
}
