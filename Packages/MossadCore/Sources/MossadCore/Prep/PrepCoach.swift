import Foundation

/// The input of the "Coach" section on an upcoming meeting's page: what the coach already knows about the
/// invited people. The page gives this value to one small view (`PrepCoachSection` in the app) and shows the
/// section only when `isEmpty` is false.
///
/// Today it holds what the coach's memory has per person. A new coach can add fields here (advice for this
/// meeting, a goal to watch) and draw them in that view; nothing else on the page reads this type.
public struct PrepCoach: Sendable, Equatable {
    public struct Person: Sendable, Equatable, Identifiable {
        public var id: String { name }
        /// A saved person who is invited, on a sure match.
        public var name: String
        /// The coach's read on working with them (`CoachPerson.brief`), when one is written.
        public var brief: PersonBrief?
        /// The coach's own short note on them from the reviews (`CoachPerson.note`), when it has words.
        public var note: String?
        /// What the owner confirmed about them, read by the person's id.
        public var learnings: [String] = []
        /// The person's id, when the name is one saved person on a sure match: for the cover of the card.
        public var personID: String?
        /// How to present to them, built by code from shown traits. Nil until the person has a card.
        public var card: PersonaCard?
        /// Whether the page shows the whole card for this person: for 2 people at most, the ones with the most shown
        /// traits. The others show the headline.
        public var showsCard = false
        /// Shown traits, for the order of the cards.
        public var traits = 0

        /// The card's headline, or the older read's line until the person has a card.
        public var headline: String? { card?.headline.nonBlank ?? brief?.headline.nonBlank }
    }

    /// The page shows the whole card for this many people at most.
    public static let fullCards = 2

    /// In the order of the invite. A person the coach has nothing on is not here.
    public var people: [Person]

    public var isEmpty: Bool { people.isEmpty }

    public init(people: [Person] = []) {
        self.people = people
    }

    /// `people` are the invited people Mossad knows; `coach` is `CoachProfile.people`.
    public init(people names: [String], coach: [String: CoachPerson]) {
        people = names.compactMap { name in
            guard let known = coach[name] else { return nil }
            let note = known.note.nonBlank
            guard known.brief != nil || note != nil else { return nil }
            return Person(name: name, brief: known.brief, note: note)
        }
    }

    /// The same from the coach's memory, read by the person's id where the name is one saved person on a sure
    /// match: a name written last name first, and a person with a new name, read what was learned of them.
    /// `reads` are the reads of how each person thinks, by person id (`PersonaReads`): an invited person on a sure
    /// match only.
    public init(people names: [String], profile: CoachProfile, saved: CoachPeople, reads: [String: PersonaSummary] = [:]) {
        people = names.compactMap { name in
            let known = profile.note(on: name, people: saved)?.value
            let id = saved.id(of: name)
            let learnings = id.map { profile.learnings(about: $0, people: saved).map(\.text) } ?? []
            let note = known?.note.nonBlank
            let read = id.flatMap { reads[saved.canonical($0)] }
            guard known?.brief != nil || note != nil || !learnings.isEmpty || read?.card != nil else { return nil }
            var p = Person(name: name, brief: known?.brief, note: note, learnings: learnings)
            p.personID = id
            p.card = read?.card
            p.traits = read?.traits.count ?? 0
            return p
        }
        let full = Set(people.enumerated().filter { $0.element.card != nil }.sorted { ($0.element.traits, -$0.offset) > ($1.element.traits, -$1.offset) }
            .prefix(Self.fullCards).map(\.element.name))
        for i in people.indices { people[i].showsCard = full.contains(people[i].name) }
    }
}
