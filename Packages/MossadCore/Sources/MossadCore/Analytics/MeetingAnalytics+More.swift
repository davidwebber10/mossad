import Foundation

extension MeetingAnalytics {
    // MARK: Participation

    /// The invited people against the voices. Nil for a call with no invite.
    static func participation(_ r: CallRecord, speakers: [Speaker], people: PersonDirectory) -> Participation? {
        guard !r.attendees.isEmpty else { return nil }
        let named = speakers.filter { !$0.isUnknown }
        let context = named.map(\.name)
        // The speakers as a directory of their own, so an invited "Dana" finds the speaker Dana Lee even when
        // nobody saved her as a person.
        let voices = PersonDirectory(named.map { PersonDirectory.Person(name: $0.name, email: nil) })
        var seen: Set<String> = []
        var invited: [Participation.Attendee] = []
        for a in r.attendees {
            let isEmail = a.contains("@")
            let person = people.person(for: a, among: context)
            let voice = person.flatMap { voices.person(for: $0) } ?? (isEmail ? nil : voices.person(for: a, among: context))
            let label = isEmail ? (person ?? a) : a
            guard seen.insert(PeopleDuplicates.normalized(label)).inserted else { continue }
            invited.append(Participation.Attendee(label: label, email: isEmail ? a : nil, person: person,
                                                  speaker: voice.flatMap { v in named.first { $0.name == v }?.id }))
        }
        let heard = Set(invited.compactMap(\.speaker))
        // The invite is the owner's own calendar, so the owner is never a guest who came without one.
        return Participation(invited: invited, uninvited: named.filter { !heard.contains($0.id) && !$0.isOwner }.map(\.id),
                             unnamedVoices: speakers.filter(\.isUnknown).count)
    }

    // MARK: Outcomes

    /// Decisions, action items by owner, and the owner's tasks from this call. Nil when there is none of them.
    static func outcomes(_ r: CallRecord, speakers: [Speaker], commitments: [Commitment]) -> Outcomes? {
        let tasks = commitments.filter { $0.callID == r.id && !$0.deleted }
            .map { Outcomes.TaskRef(id: $0.id, text: $0.text, done: $0.done != nil) }
        guard !r.decisions.isEmpty || !r.actionItems.isEmpty || !tasks.isEmpty else { return nil }
        let names = Set(speakers.filter { !$0.isUnknown }.map(\.name))
        var order: [String] = []
        var byOwner: [String: Outcomes.Owner] = [:]
        for item in r.actionItems {
            // An owner written as a first name is the one speaker with that name, as a person's page counts it.
            let name = item.owner.flatMap { PersonStatistics.speaker(forOwner: $0, among: names) ?? $0.nonBlank }
            let key = name.map(PeopleDuplicates.normalized) ?? ""
            if byOwner[key] == nil {
                order.append(key)
                byOwner[key] = Outcomes.Owner(name: name, speaker: speakers.first { $0.name == name }?.id, tasks: [])
            }
            byOwner[key]!.tasks.append(item.task)
        }
        let owners = order.enumerated().map { (index: $0.offset, owner: byOwner[$0.element]!) }
            .sorted { a, b in
                if (a.owner.name == nil) != (b.owner.name == nil) { return b.owner.name == nil }
                return a.owner.tasks.count != b.owner.tasks.count ? a.owner.tasks.count > b.owner.tasks.count : a.index < b.index
            }
            .map(\.owner)
        return Outcomes(decisions: r.decisions.count, actionItems: r.actionItems.count, owners: owners, tasks: tasks)
    }

    // MARK: Screens

    /// Share sessions by presenter, in the order they first shared. Nil for a call with no screens.
    static func screens(_ r: CallRecord) -> Screens? {
        guard let screens = r.screens, !screens.isEmpty else { return nil }
        var order: [String] = []
        var by: [String: Screens.Presenter] = [:]
        for session in ShareSession.group(screens) {
            let key = session.presenter ?? ""
            if by[key] == nil {
                order.append(key)
                by[key] = Screens.Presenter(name: session.presenter, sessions: 0, screens: 0, seconds: 0, first: session.start)
            }
            by[key]!.sessions += 1
            by[key]!.screens += session.count
            by[key]!.seconds += max(0, session.end - session.start)
        }
        return Screens(presenters: order.map { by[$0]! })
    }

    // MARK: Cost

    private static let transcriptionPurposes: Set<UsageEvent.Purpose> = [.transcription, .live]

    /// What was logged for this call, at list prices; for a call from before the log, the estimate Analytics
    /// uses. Nil when the call cost nothing (a local model, or nothing to transcribe).
    static func cost(_ r: CallRecord, usage: [UsageEvent]) -> Cost? {
        let logged = usage.filter { $0.callID == r.id }
        let events = logged.isEmpty ? Pricing.estimates(for: [r], logged: []) : logged
        var byPurpose: [UsageEvent.Purpose: Double] = [:]
        for e in events { byPurpose[e.purpose, default: 0] += Pricing.cost(e) }
        let total = byPurpose.values.reduce(0, +)
        guard total > 0 else { return nil }
        let transcription = byPurpose.filter { transcriptionPurposes.contains($0.key) }.values.reduce(0, +)
        let lines = UsageEvent.Purpose.allCases.compactMap { p in byPurpose[p].flatMap { $0 > 0 ? Cost.Line(purpose: p, dollars: $0) : nil } }
        return Cost(total: total, transcription: transcription, ai: total - transcription, lines: lines, estimated: logged.isEmpty)
    }
}
