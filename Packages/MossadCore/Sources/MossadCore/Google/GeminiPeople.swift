import Foundation

/// The speakers of a meeting imported from Gemini notes have names but no voices, so nothing else makes them saved
/// people. A speaker becomes one, with an address, only on a sure match: the full name is the directory name of
/// exactly one invited address.
public enum GeminiPeople {
    public struct Match: Equatable, Sendable {
        /// The directory's spelling.
        public var name: String
        public var email: String
    }

    /// The company directory's name for each address, without the owner's contacts.
    public static func directoryNames(_ cache: GoogleDirectoryCache) -> [String: String] {
        GoogleDirectoryCache(profiles: cache.profiles.filter { $0.source == .directory }, read: cache.read).names
    }

    public static func matches(_ r: CallRecord, directory: [String: String]) -> [Match] {
        guard r.isNotesOnly else { return [] }
        let invited = (r.invitees ?? []).filter { $0.isSelf != true && $0.kind == nil }.compactMap(\.email).map(EmailIdentity.normalized)
        var found: [String: Match] = [:]
        for (speaker, name) in r.speakerNames.sorted(by: { $0.key < $1.key }) where !speaker.hasPrefix("me:") {
            let wanted = PersonNames.nameKey(name)
            // A full name: one word could be anyone.
            guard wanted.contains(" ") else { continue }
            let fits = Set(invited.filter { directory[$0].map(PersonNames.nameKey) == wanted })
            guard fits.count == 1, let email = fits.first, found[email] == nil, let spelled = directory[email] else { continue }
            found[email] = Match(name: spelled, email: email)
        }
        return found.values.sorted { $0.email < $1.email }
    }

    /// Saves each match of the meetings not yet `done` as a person with the address, the way the People page adds a
    /// person by address: one with no voice samples is made when there is none. A person of that name (in any case or
    /// spacing, as a voice or in the people store) who has another address is left alone, because the same name can be
    /// another person, and an address that someone else has stays theirs. A person the owner deleted is not made again,
    /// and a meeting is read once. Without the directory, or after an error, a meeting waits for the next run.
    @discardableResult
    public static func link(_ records: [CallRecord], library: VoiceLibrary, directory: [String: String],
                            done: Set<String>, people: [Person] = []) -> (added: Int, done: Set<String>) {
        guard !directory.isEmpty else { return (0, done) }
        var added = 0
        var done = done
        for r in records where r.isNotesOnly && !done.contains(r.id) {
            var failed = false
            for m in matches(r, directory: directory) {
                let key = PersonNames.nameKey(m.name)
                let profile = library.profiles.first { PersonNames.nameKey($0.name) == key }
                if profile?.emails.contains(where: { EmailIdentity.normalized($0) == m.email }) == true { continue }
                // A person the owner deleted or merged away is not made again.
                guard !people.contains(where: { !$0.isLive && PersonNames.nameKey($0.displayName) == key }) else { continue }
                let otherAddress = (profile?.emails ?? []).contains { EmailIdentity.normalized($0) != m.email }
                    || people.contains { p in
                        p.isLive && PersonNames.nameKey(p.displayName) == key
                            && !p.emails.isEmpty && !p.emails.contains { $0.address == m.email }
                    }
                guard !otherAddress else {
                    Log.info("Gemini people: \(m.name) has another address; \(m.email) was not added")
                    continue
                }
                do {
                    switch try library.addEmail(m.email, for: profile?.name ?? m.name, actor: "google") {
                    case .added: added += 1
                    case .belongsTo(let other): Log.info("Gemini people: \(m.email) belongs to \(other); \(m.name) was not added")
                    default: break
                    }
                } catch {
                    Log.error("Gemini people: \(m.email) was not saved: \(error)")
                    failed = true
                }
            }
            if !failed { done.insert(r.id) }
        }
        return (added, done)
    }
}
