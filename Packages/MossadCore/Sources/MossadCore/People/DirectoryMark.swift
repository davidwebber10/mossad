import Foundation

/// "From your directory": a quiet mark on a person whom the Gemini people step made (`GeminiPeople.link`), while
/// nothing else shaped the person. The store has no flag for "the owner edited this person", so the rule reads what it
/// records: a name form the owner gave, an address the step did not give, and "Not their address".
public enum DirectoryMark {
    public static let text = "From your directory"

    /// `given` is the record of addresses the step gave (`GeminiPeopleBook.given`); nil when it cannot be read, and
    /// then the addresses are not read. A merged person is read by the survivor's own record.
    public static func shows(_ p: Person, hasVoice: Bool, given: Set<String>?) -> Bool {
        guard p.isLive, !p.isOwner, p.origin == .googleDirectory, !hasVoice else { return false }
        // A rename or another name the owner gave.
        guard !p.forms.contains(where: { $0.source == .owner }) else { return false }
        guard !p.emails.contains(where: { $0.state == .rejected }) else { return false }
        guard let given else { return true }
        let verified = p.emails.filter { $0.state == .verified }.map(\.address)
        return !verified.isEmpty && verified.allSatisfy(given.contains)
    }

    /// The names of the voices whose person shows the mark. A voice with a fingerprint, or a person with a sample,
    /// has a voice.
    public static func names(profiles: [VoiceProfile], people: [Person], samples: [VoiceSample], given: Set<String>?) -> Set<String> {
        let byID = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let heard = Set(samples.compactMap(\.personID))
        var out: Set<String> = []
        for profile in profiles where !profile.isOwner {
            // Only a live person has the voice's name: an absorbed record is never read, its survivor is.
            guard let p = PeopleStore.id(forVoiceName: profile.name, isOwner: false, in: people).flatMap({ byID[$0] }) else { continue }
            if shows(p, hasVoice: !profile.embeddings.isEmpty || heard.contains(p.id), given: given) { out.insert(profile.name) }
        }
        return out
    }
}
