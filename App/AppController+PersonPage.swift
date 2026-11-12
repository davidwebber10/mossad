import Foundation
import MossadCore

/// What a person's page reads of the people store and the voice samples. A preview has no running store: it reads
/// the files and writes nothing.
extension AppController {
    /// Changes when a saved person's name or any address changes, or the company domains do: the pages' caches key on it.
    var peopleStamp: Int {
        var h = Hasher()
        for p in library.profiles { h.combine(p.name); h.combine(p.emails) }
        h.combine(CompanyDomains.current)
        h.combine(library.identity?.people.people.map(\.updated))
        return h.finalize()
    }

    /// The saved person of a name on the People page.
    func savedPerson(of profile: VoiceProfile) -> Person? {
        if let store = library.identity?.people {
            return store.id(forVoiceName: profile.name, isOwner: profile.isOwner).flatMap { store.person($0) }
        }
        guard isInert else { return nil }
        let people = PeopleStore.peek(in: paths.people) ?? []
        return PeopleStore.id(forVoiceName: profile.name, isOwner: profile.isOwner, in: people).flatMap { id in people.first { $0.id == id } }
    }

    /// The person's voice samples with where each came from; nil when the samples' file is not there.
    func voiceSamples(of profile: VoiceProfile) -> [VoiceSample]? {
        guard let person = savedPerson(of: profile) else { return nil }
        let store = library.identity?.samples ?? (isInert ? VoiceSampleStore(directory: paths.voices) : nil)
        return store?.samples(of: person.id)
    }
}
