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

    /// What the check changes on a meeting, only on proof: another event than the record has, proved by a link, a title,
    /// or the voices; or "no invite" for a link (a whole read holds no event of it) when the record has an invite. Nil
    /// changes nothing: a pick of the overlap is main's answer, and missing evidence never takes an invite away.
    public static func change(_ r: CallRecord, _ answer: InviteAnswer) -> InviteAnswer? {
        switch answer {
        case .proved(let e):
            return r.calendarTitle == e.title && r.plannedStart == (e.isAllDay ? nil : e.start) ? nil : answer
        case .noInvite:
            return r.calendarTitle != nil || !r.attendees.isEmpty ? answer : nil
        case .picked, .nothing:
            return nil
        }
    }
}
