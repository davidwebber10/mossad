import Foundation

/// Who was in the call, against the events around it, for an invite that neither a link nor a title proved. Pure.
///
/// Only a voice named by its own score counts: a voice named from the invite (`CallRecord.fromInvite`) is no proof of
/// that invite. An invited person is a saved voice of the invite by the rule of `InviteRoster`: the person's id, an
/// address, or the whole name, never a first name alone.
public enum InviteCheck {
    /// An event that ended this long before the recording started, or starts this long after it ended, can be the call's.
    public static let near: TimeInterval = CalendarMatcher.readWindow

    public enum Verdict: Equatable, Sendable {
        /// The event with more of the call's named voices invited than any other: the call's, sure.
        case confirmed(CalendarEventInfo)
        /// Voices named for sure, and none of them invited to the event picked, and no other event wins: another call.
        case noInvite
        /// The voices say nothing: the event picked stays, as a guess.
        case guess
    }

    /// The events that can be the call: each with the platform's call link (and the call's link, when it has one) that
    /// overlaps the recording, ended up to `near` before it started, or starts up to `near` after it ended.
    public static func candidates(platform: Platform, link: String?, start: Date, end: Date, in events: [CalendarEventInfo]) -> [CalendarEventInfo] {
        events.filter { e in
            let text = (e.text.removingPercentEncoding ?? e.text).lowercased()
            return !e.isAllDay && e.end >= start.addingTimeInterval(-near) && e.start <= end.addingTimeInterval(near)
                && CalendarMatcher.hasCallLink(e, platform: platform) && (link.map { text.contains($0.lowercased()) } ?? true)
        }
    }

    /// `voices`: the names of the voices named for sure in the recording, without the owner. `invited`: the saved voices
    /// an event invites (`invitedVoices`).
    public static func decide(picked: CalendarEventInfo?, candidates: [CalendarEventInfo], voices: Set<String>,
                              invited: (CalendarEventInfo) -> Set<String>) -> Verdict {
        let counts = candidates.map { ($0, invited($0).intersection(voices).count) }
        if let top = counts.max(by: { $0.1 < $1.1 }), top.1 > 0, counts.filter({ $0.1 == top.1 }).count == 1 {
            return .confirmed(top.0)
        }
        guard !voices.isEmpty else { return .guess }
        let held = picked.map { invited($0).intersection(voices).count } ?? 0
        return held == 0 ? .noInvite : .guess
    }

    /// The saved voices each event invites, by `InviteRoster`'s rule, without the owner's.
    public static func invitedVoices(profiles: [VoiceProfile], people: [Person]) -> (CalendarEventInfo) -> Set<String> {
        let owners = Set(profiles.filter(\.isOwner).map(\.name))
        return { e in
            guard let invite = CallInvite(event: e, sure: true) else { return [] }
            return InviteRoster(invite: invite, profiles: profiles, people: people).invited.subtracting(owners)
        }
    }
}

/// What the calendar gives a recording: its event surely, its event as a guess, or no invite.
public enum InviteAnswer: Equatable, Sendable {
    case sure(CalendarEventInfo)
    case guess(CalendarEventInfo)
    case none

    /// The link (`meetingID`, else `titleLink`) or the title key proves an event; a link that no event holds is no invite.
    /// Else the overlap's event is a guess, which the voices (`voices`, nil before they are named) confirm, replace, or
    /// take away (`InviteCheck`). A room keeps the matcher's word: its voices are on one track.
    public static func of(platform: Platform, link: String?, titleKey: String?, start: Date, end: Date, events: [CalendarEventInfo],
                          voices: Set<String>?, invited: (CalendarEventInfo) -> Set<String>) -> InviteAnswer {
        let found = CalendarMatcher.match(for: platform, meetingID: link, titleKey: link == nil ? titleKey : nil, start: start, end: end, in: events)
        if let found, found.sure { return .sure(found.event) }
        if platform == .inPerson { return found.map { .guess($0.event) } ?? .none }
        guard link == nil || found != nil else { return .none }
        guard let voices else { return found.map { .guess($0.event) } ?? .none }
        let candidates = InviteCheck.candidates(platform: platform, link: link, start: start, end: end, in: events)
        switch InviteCheck.decide(picked: found?.event, candidates: candidates, voices: voices, invited: invited) {
        case .confirmed(let e): return .sure(e)
        case .noInvite: return .none
        case .guess: return found.map { .guess($0.event) } ?? .none
        }
    }
}
