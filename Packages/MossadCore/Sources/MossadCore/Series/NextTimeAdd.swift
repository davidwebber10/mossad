import Foundation

/// Adds a point from words such as "TB" or "Sam": the Chat tool, the MCP, and the search command use it.
public enum NextTimeAdd {
    public enum Target: Equatable, Sendable {
        case series(MeetingSeries)
        case person(id: String, name: String)
    }

    public enum Outcome: Equatable, Sendable {
        case added(NextTimePoint)
        /// Several series fit the words: their titles, to choose from.
        case choose([String])
        case notFound(String)
    }

    /// The series whose title holds the words, or that is the only one with this person as a usual attendee.
    public static func series(_ query: String, in all: [MeetingSeries]) -> [MeetingSeries] {
        let q = PeopleDuplicates.normalized(query)
        guard !q.isEmpty else { return [] }
        let exact = all.filter { PeopleDuplicates.normalized($0.title) == q }
        if !exact.isEmpty { return exact }
        let words = Set(q.split(separator: " "))
        let byTitle = all.filter { s in
            let title = PeopleDuplicates.normalized(s.title)
            // Whole words only: "TB" is not in "Football".
            return words.isSubset(of: Set(title.split { !$0.isLetter && !$0.isNumber }))
        }
        if !byTitle.isEmpty { return byTitle }
        return all.filter { s in s.usualPeople.contains { ChatTools.name(query, matches: $0) } }
    }

    /// Resolves the words and adds the point to the book.
    public static func add(_ text: String, series query: String?, person: String?, series all: [MeetingSeries], people: PersonReferences,
                           book: inout NextTimeBook, at date: Date = Date()) -> Outcome {
        guard text.nonBlank != nil else { return .notFound("The point has no words.") }
        if let query = query?.nonBlank {
            var found = series(query, in: all)
            // A person narrows several series: "the TB with Sam".
            if found.count > 1, let person = person?.nonBlank {
                let with = found.filter { $0.usualPeople.contains { ChatTools.name(person, matches: $0) } }
                if !with.isEmpty { found = with }
            }
            if found.count == 1, let p = book.add(text, series: found[0], at: date) { return .added(p) }
            if found.count > 1 { return .choose(found.map(\.title)) }
            return .notFound("No recurring meeting matches \u{201C}\(query)\u{201D}. Known: \(all.prefix(12).map(\.title).joined(separator: "; ")).")
        }
        if let person = person?.nonBlank {
            guard let id = people.id(for: person), let name = people.name(of: id) else {
                return .notFound("No saved person is surely \u{201C}\(person)\u{201D}. Use their whole name.")
            }
            if let p = book.add(text, personID: id, personName: name, at: date) { return .added(p) }
        }
        return .notFound("Say the recurring meeting or the person.")
    }
}

extension ChatTools {
    static var nextTimeDefinition: ToolSpec {
        ToolSpec(name: "add_next_time_point",
                 description: "Saves a point the owner wants to raise later, not now: at the next meeting of a recurring meeting (series: words of its title, such as \"TB\" or \"Weekly sync\") or the next time they see a person (person: their name). Give series, person, or both (a person narrows several series). text is the point in the owner's words, short. Tell the owner where you saved it.",
                 schema: ["type": "object", "properties": [
                    "text": ["type": "string"], "series": ["type": "string"], "person": ["type": "string"],
                 ] as [String: Any], "required": ["text"]])
    }

    /// The recurring meetings as the records say: the calendar is not read here.
    var series: [MeetingSeries] {
        let people = paths.flatMap { PeopleStore.peek(in: $0.people) } ?? []
        let directory = PersonDirectory(people.filter(\.isLive).map { .init(name: $0.displayName, email: $0.emails.first?.address) })
        return SeriesCatalog.build(records: records, upcoming: [], owner: owner, directory: directory)
    }

    func addNextTimePoint(_ input: [String: Any]) -> String {
        guard let paths else { return "Not available here." }
        guard let text = (input["text"] as? String)?.nonBlank else { return "The point has no words." }
        var outcome = NextTimeAdd.Outcome.notFound("")
        do {
            try NextTimeBook.change(in: paths.nextTime) { book in
                outcome = NextTimeAdd.add(text, series: input["series"] as? String, person: input["person"] as? String, series: series, people: saved, book: &book)
            }
        } catch {
            return "Could not save: the list of points cannot be read."
        }
        switch outcome {
        case .added(let p):
            return p.seriesTitle.map { "Saved for the next \($0): \(p.text)" } ?? "Saved for the next time you see \(p.personName ?? "them"): \(p.text)"
        case .choose(let titles): return "Several recurring meetings match; ask which one: \(titles.joined(separator: "; "))."
        case .notFound(let why): return why
        }
    }
}
