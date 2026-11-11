import Foundation

/// The owner as a person: each name they have or had. The name in Settings alone is not enough, because the
/// records and the owner's voice profile keep the name of the time they were made.
public struct OwnerIdentity: Sendable, Equatable, ExpressibleByStringLiteral {
    /// The name in Settings now.
    public let name: String
    private let keys: Set<String>

    public init(name: String, also names: [String] = []) {
        self.name = name
        keys = Set(([name] + names).map(PersonNames.key).filter { !$0.isEmpty })
    }

    public init(stringLiteral value: String) { self.init(name: value) }

    public func isOwner(_ name: String) -> Bool { keys.contains(PersonNames.key(name)) }

    /// The speaker keys of a call that are the owner.
    public func speakerKeys(in r: CallRecord) -> Set<String> { Set(r.speakerNames.filter { isOwner($0.value) }.keys) }

    /// The owner's name as the transcript of this call shows it.
    public func name(in r: CallRecord) -> String {
        r.speakerNames.sorted { $0.key < $1.key }.first { isOwner($0.value) }?.value ?? name
    }

    /// The identity from what is on disk: the owner's names in the people store and the name of the owner's voice
    /// profile. It only reads; a file that does not decode stays where it is and adds nothing.
    public static func read(name: String, paths: Paths) -> OwnerIdentity {
        var names = PeopleStore.peek(in: paths.people)?.first { $0.isOwner && $0.isLive }?.forms.map(\.text) ?? []
        if let data = try? Data(contentsOf: paths.voices.appendingPathComponent("voices.json")),
           let voice = (try? JSONDecoder().decode([VoiceProfile].self, from: data))?.first(where: \.isOwner) { names.append(voice.name) }
        return OwnerIdentity(name: name, also: names)
    }
}
