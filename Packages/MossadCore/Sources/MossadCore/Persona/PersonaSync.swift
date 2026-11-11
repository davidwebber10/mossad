import Foundation

/// The reduced copy that goes from the Mac to the iPhone, through the owner's server only: for each person the
/// shown traits, the card, and pointers to the moments. Built from a list of allowed fields: no hidden candidate,
/// no evidence, and no words of the person. The phone reads it and never sends it.
public struct SyncedPersonas: Codable, Equatable, Sendable {
    public static let fileName = "personas-shown.json"
    public static let currentVersion = 1

    /// The keys each level may have. A test fails when the payload has any other key.
    public static let allowedKeys: [String: Set<String>] = [
        "root": ["version", "personas"],
        "persona": ["person", "updated", "traits", "card", "calls", "oneCall"],
        "trait": ["id", "dimension", "value", "condition", "statement", "soDoThis", "confirmed", "confidence", "supportCalls", "counterCalls",
                  "moments", "counter", "lastSeen"],
        "card": ["headline", "lines"],
        "line": ["kind", "text", "traits", "confidenceLine", "moment"],
        "pointer": ["callID", "at", "line"],
    ]

    public var version = SyncedPersonas.currentVersion
    public var personas: [PersonaSummary]

    public init(_ personas: [PersonaSummary]) {
        // Only people with something shown; the order is fixed, so the same read gives the same bytes.
        self.personas = personas.filter { !$0.traits.isEmpty }.sorted { $0.person < $1.person }
    }

    /// The phone's copy, or none.
    public static func load(from coach: URL) -> SyncedPersonas? {
        (try? Data(contentsOf: coach.appendingPathComponent(fileName))).flatMap { try? JSONDecoder.callRecord.decode(SyncedPersonas.self, from: $0) }
    }

    public func summary(of person: String) -> PersonaSummary? { personas.first { $0.person == person } }
}

extension SharedPayload {
    /// The shown traits, from the Mac to the phone.
    public static func personas(_ personas: SyncedPersonas) -> SharedPayload {
        SharedPayload(kind: .personas, key: "personas", data: (try? JSONEncoder.callRecord.encode(personas)) ?? Data())
    }
}

/// The reads of all people, from the files on this Mac and the coach's answers: for the pages, Chat, other AI
/// apps, and the copy for the phone.
public enum PersonaReads {
    /// Each person with a file who is a live person here and keeps a read, by the id of now.
    public static func all(paths: Paths, saved: CoachPeople, answers: [FindingAnswer]) -> [String: PersonaSummary] {
        let store = PersonaStore(paths: paths)
        let off = saved.notProfiled
        var out: [String: PersonaSummary] = [:]
        let ids = Set(store.people().map { saved.isEmpty ? $0 : saved.canonical($0) })
        for id in ids where !off.contains(id) {
            guard let name = saved.name(of: id), let persona = store.persona(of: id, saved: saved),
                  let summary = PersonaSummary.make(persona, answers: answers, name: name) else { continue }
            out[id] = summary
        }
        return out
    }

    /// The traits that the deck may ask about, with candidates just below the line: only on the Mac, which has the
    /// evidence.
    public static func sources(paths: Paths, saved: CoachPeople, answers: [FindingAnswer]) -> [PersonaFindings.Source] {
        let store = PersonaStore(paths: paths)
        let off = saved.notProfiled
        var out: [PersonaFindings.Source] = []
        for id in Set(store.people().map { saved.isEmpty ? $0 : saved.canonical($0) }) where !off.contains(id) {
            guard let name = saved.name(of: id), let persona = store.persona(of: id, saved: saved) else { continue }
            out += PersonaTraits.build(persona, answers: answers).map { PersonaFindings.Source($0, name: name) }.filter(\.isAsked)
        }
        return out.sorted { $0.trait < $1.trait }
    }

    /// The words of a moment, from the call's record on disk: for a card's quote, never stored.
    public static func words(_ p: PersonaPointer, paths: Paths) -> String? {
        (try? CallRecord.load(from: paths.callDirectory(p.callID))).flatMap { p.utterance(in: $0)?.text }
    }

    /// One person's read, or nil.
    public static func one(_ id: String, paths: Paths, saved: CoachPeople, answers: [FindingAnswer]) -> PersonaSummary? {
        let id = saved.canonical(id)
        guard !saved.notProfiled.contains(id), let name = saved.name(of: id), let persona = PersonaStore(paths: paths).persona(of: id, saved: saved) else { return nil }
        return PersonaSummary.make(persona, answers: answers, name: name)
    }
}
