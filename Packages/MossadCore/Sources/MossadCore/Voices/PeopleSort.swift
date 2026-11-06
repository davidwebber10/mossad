import Foundation

/// The orders the People list offers. The owner is always first.
public enum PeopleSort: String, CaseIterable, Sendable {
    case recent, mostMet, talkTime, newest, name

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
            case .name:
                break
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return profiles.sorted(by: before)
    }

    /// People whose voice the app cannot recognize yet.
    public static func needsVoiceSample(_ profiles: [VoiceProfile]) -> [VoiceProfile] {
        profiles.filter { $0.embeddings.isEmpty }
    }
}
