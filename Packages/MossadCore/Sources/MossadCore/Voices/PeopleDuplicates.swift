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
        if let ea = a.email?.lowercased(), ea == b.email?.lowercased() { return .sameEmail }
        let na = normalized(a.name), nb = normalized(b.name)
        if na == nb { return .sameName }
        if similar(na, nb) { return .similarName }
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
    /// The saved person a new name stands for: the same email (any case), or the same name in other case or
    /// spacing. Nil for someone new.
    public func existingName(name: String, email: String?) -> String? {
        let people = profiles
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !email.isEmpty,
           let p = people.first(where: { $0.email?.lowercased() == email }) { return p.name }
        let key = PeopleDuplicates.normalized(name)
        guard !key.isEmpty else { return nil }
        return people.first { PeopleDuplicates.normalized($0.name) == key }?.name
    }
}
