import Foundation

/// A habit the coach has seen across calls.
public struct CoachPattern: Codable, Equatable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case strength, growth }
    public enum Trend: String, Codable, Sendable { case improving, steady, slipping }

    public var name: String
    public var kind: Kind
    public var note: String
    /// How many reviewed calls showed it.
    public var seen: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var trend: Trend

    public init(name: String, kind: Kind, note: String, seen: Int, firstSeen: Date, lastSeen: Date, trend: Trend) {
        self.name = name
        self.kind = kind
        self.note = note
        self.seen = seen
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.trend = trend
    }
}

/// How the owner and one person work together, from the owner's side.
public struct CoachPerson: Codable, Equatable, Sendable, Hashable {
    public var note: String
    public var calls: Int
    public var lastSeen: Date

    public init(note: String, calls: Int, lastSeen: Date) {
        self.note = note
        self.calls = calls
        self.lastSeen = lastSeen
    }
}

public struct CoachHistoryEntry: Codable, Equatable, Sendable, Hashable {
    public var callID: String
    public var title: String
    public var date: Date
    public var headline: String
    public var focusProgress: String?
    public var delivery: DeliveryStats?
}

public struct CoachPatternUpdate: Codable, Equatable, Sendable {
    public var name: String
    public var kind: CoachPattern.Kind
    public var note: String
    public var trend: CoachPattern.Trend

    public init(name: String, kind: CoachPattern.Kind, note: String, trend: CoachPattern.Trend) {
        self.name = name
        self.kind = kind
        self.note = note
        self.trend = trend
    }
}

public struct CoachPersonUpdate: Codable, Equatable, Sendable {
    public var name: String
    public var note: String

    public init(name: String, note: String) {
        self.name = name
        self.note = note
    }
}

/// What the coach learned from one call, to fold into the profile.
public struct CoachProfileUpdate: Codable, Equatable, Sendable {
    public var summary: String
    public var focus: String
    public var patterns: [CoachPatternUpdate]
    public var people: [CoachPersonUpdate]

    public init(summary: String, focus: String, patterns: [CoachPatternUpdate], people: [CoachPersonUpdate]) {
        self.summary = summary
        self.focus = focus
        self.patterns = patterns
        self.people = people
    }
}

/// The coach's memory across calls, kept in `~/Mossad/Coach/profile.json`. Each review reads it and updates it,
/// so advice builds on what came before instead of starting over each call.
public struct CoachProfile: Codable, Equatable, Sendable {
    public static let fileName = "profile.json"
    public static let historyLimit = 40

    /// Who the owner is as a communicator, in a few sentences.
    public var summary = ""
    /// The one thing the owner works on now.
    public var focus = ""
    public var patterns: [CoachPattern] = []
    public var people: [String: CoachPerson] = [:]
    public var history: [CoachHistoryEntry] = []

    public init() {}

    public mutating func apply(_ update: CoachProfileUpdate, review: CoachReview, callID: String, title: String, at: Date) {
        if let s = update.summary.nonBlank { summary = s }
        if let f = update.focus.nonBlank { focus = f }
        for p in update.patterns {
            if let i = patterns.firstIndex(where: { $0.name.caseInsensitiveCompare(p.name) == .orderedSame }) {
                patterns[i].kind = p.kind
                patterns[i].note = p.note
                patterns[i].trend = p.trend
                patterns[i].seen += 1
                patterns[i].lastSeen = at
            } else {
                patterns.append(CoachPattern(name: p.name, kind: p.kind, note: p.note, seen: 1, firstSeen: at, lastSeen: at, trend: p.trend))
            }
        }
        for p in update.people {
            guard let note = p.note.nonBlank else { continue }
            people[p.name] = CoachPerson(note: note, calls: (people[p.name]?.calls ?? 0) + 1, lastSeen: at)
        }
        history.append(CoachHistoryEntry(callID: callID, title: title, date: at, headline: review.headline,
                                         focusProgress: review.focusProgress, delivery: review.delivery))
        history = Array(history.suffix(Self.historyLimit))
    }

    public static func load(from dir: URL) throws -> CoachProfile {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return CoachProfile() }
        return try JSONDecoder.coach.decode(CoachProfile.self, from: Data(contentsOf: url))
    }

    public func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

extension String {
    var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
