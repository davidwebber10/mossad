import Foundation

/// Saved people who are probably one person: the same email, the same name written another way, a name one or
/// two letters off, or the same voice. Shown on the People page to merge.
public enum PeopleDuplicates {
    public enum Reason: String, Sendable { case sameEmail, sameName, similarName, sameVoice }

    public struct Pair: Equatable, Sendable, Identifiable {
        public let first: String
        public let second: String
        public let reason: Reason
        /// The same for both orders, so a dismissed pair stays dismissed.
        public var id: String { [first, second].sorted().joined(separator: "|") }
    }

    /// The two people of a pair as saved people: each the one live person with that name. Nil when a name is not
    /// exactly one person.
    public static func people(of pair: Pair, among people: [Person]) -> (PersonID, PersonID)? {
        func one(_ name: String) -> PersonID? {
            let hits = people.filter { $0.isLive && $0.displayName == name }
            return hits.count == 1 ? hits[0].id : nil
        }
        guard let a = one(pair.first), let b = one(pair.second), a != b else { return nil }
        return (a, b)
    }

    /// Whether the owner called the two people of a pair other people, by their ids: it stays through a rename.
    public static func isDistinct(_ pair: Pair, among people: [Person]) -> Bool {
        guard let (a, b) = Self.people(of: pair, among: people) else { return false }
        return people.contains { ($0.id == a && $0.distinctFrom.contains(b)) || ($0.id == b && $0.distinctFrom.contains(a)) }
    }

    /// Two voice fingerprints this close are one voice.
    static let sameVoice: Float = 0.9

    public static func find(_ profiles: [VoiceProfile]) -> [Pair] {
        var pairs: [Pair] = []
        for (i, a) in profiles.enumerated() {
            for b in profiles[(i + 1)...] {
                if let reason = reason(a, b) { pairs.append(Pair(first: a.name, second: b.name, reason: reason)) }
            }
        }
        return pairs
    }

    static func reason(_ a: VoiceProfile, _ b: VoiceProfile) -> Reason? {
        if !Set(a.emails.map { $0.lowercased() }).isDisjoint(with: b.emails.map { $0.lowercased() }) { return .sameEmail }
        let na = normalized(a.name), nb = normalized(b.name)
        if na == nb { return .sameName }
        // One name written two ways: last name first, a middle name, or a short first name.
        let fit = PersonNames.fit(PersonNames.parse(a.name), PersonNames.parse(b.name))
        if [NameFit.same, .sameWithMiddle, .swapped, .nickname].contains(fit) { return .sameName }
        // Two middle names that disagree are two people, whatever else is alike.
        if fit != .conflict, similar(na, nb) { return .similarName }
        if let ca = VoiceLibrary.centroid(a.embeddings), let cb = VoiceLibrary.centroid(b.embeddings),
           VoiceLibrary.cosine(ca, cb) >= sameVoice { return .sameVoice }
        return nil
    }

    /// Lowercased, with single spaces.
    public static func normalized(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// One first name and a last name a letter or two off ("Sampson", "Samson"); two Scotts are not alike.
    static func similar(_ a: String, _ b: String) -> Bool {
        let wa = a.split(separator: " "), wb = b.split(separator: " ")
        guard wa.count >= 2, wb.count >= 2, wa.first == wb.first else { return a.count > 5 && distance(a, b) <= 1 }
        let la = String(wa.last!), lb = String(wb.last!)
        return min(la.count, lb.count) >= 4 && distance(la, lb) <= (min(la.count, lb.count) >= 6 ? 2 : 1)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
}

extension VoiceLibrary {
    /// The saved person a new name stands for, when a voice is named: the same email (any case), or the whole
    /// name in any case, spacing, or order. Nil for someone new, and for a guess (`PersonDirectory.existing`).
    public func existingName(name: String, email: String?) -> String? {
        PersonDirectory.existing(name: name, email: email, among: profiles.map { PersonDirectory.Person(name: $0.name, emails: $0.emails) })
    }
}
