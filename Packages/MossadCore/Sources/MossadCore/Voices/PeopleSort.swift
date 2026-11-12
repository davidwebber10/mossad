import Foundation

/// The orders the People list offers. The owner is always first.
public enum PeopleSort: String, CaseIterable, Sendable {
    // "name" stays the raw value of the first-name order, so a sort saved before stays the same.
    case recent, mostMet, talkTime, newest, firstName = "name", lastName

    public func order(_ profiles: [VoiceProfile], stats: [String: PersonStats]) -> [VoiceProfile] {
        func before(_ a: VoiceProfile, _ b: VoiceProfile) -> Bool {
            if a.isOwner != b.isOwner { return a.isOwner }
            let sa = stats[a.name], sb = stats[b.name]
            switch self {
            case .recent:
                let la = sa?.lastHeard ?? .distantPast, lb = sb?.lastHeard ?? .distantPast
                if la != lb { return la > lb }
            case .mostMet:
                let ca = sa?.meetings.count ?? 0, cb = sb?.meetings.count ?? 0
                if ca != cb { return ca > cb }
            case .talkTime:
                let ta = sa?.totalTalk ?? 0, tb = sb?.totalTalk ?? 0
                if ta != tb { return ta > tb }
            case .newest:
                let fa = sa?.firstHeard ?? .distantPast, fb = sb?.firstHeard ?? .distantPast
                if fa != fb { return fa > fb }
            case .firstName:
                break
            case .lastName:
                let c = Self.lastName(a.name).localizedStandardCompare(Self.lastName(b.name))
                if c != .orderedSame { return c == .orderedAscending }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return profiles.sorted(by: before)
    }

    /// The last word of a name; a single name is its own last name.
    public static func lastName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? name
    }

    /// People whose voice the app cannot recognize yet.
    public static func needsVoiceSample(_ profiles: [VoiceProfile]) -> [VoiceProfile] {
        profiles.filter { $0.embeddings.isEmpty }
    }
}
