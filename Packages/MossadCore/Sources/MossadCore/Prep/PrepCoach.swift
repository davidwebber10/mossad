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

        /// The brief's one line: the best way to work with them.
        public var headline: String? { brief?.headline.nonBlank }
    }

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
}
