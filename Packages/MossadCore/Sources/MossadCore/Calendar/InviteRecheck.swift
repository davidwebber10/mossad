import Foundation

/// The meetings written before the voices checked their invite (`InviteCheck`), which `Pipeline.recheckInvites` matches
/// again once. Pure.
public enum InviteRecheck {
    /// How far back the check looks.
    public static let days = 14

    /// A written recording on a call platform, ended since `since`, with no link from its tab (an invite that a link did
    /// not prove), not marked for another profile, and not checked yet.
    public static func due(_ r: CallRecord, since: Date) -> Bool {
        r.status == .written && r.end >= since && r.moveTo == nil && r.meetingID == nil && r.inviteChecked == nil
            && !r.isNotesOnly && Platform.callApps.contains(r.platform)
    }

    /// What a change of the invite changes in the note and the lists.
    public struct Shown: Equatable {
        var title: String?, notSure: Bool?, attendees: [String], planned: Date?, plannedEnd: Date?, series: String?

        public init(_ r: CallRecord) {
            title = r.calendarTitle
            notSure = r.inviteNotSure
            attendees = r.attendees
            planned = r.plannedStart
            plannedEnd = r.plannedEnd
            series = r.calendarSeriesID
        }
    }
}
