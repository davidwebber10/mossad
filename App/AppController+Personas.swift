import AppKit
import Foundation
import MossadCore

/// The coach's reads of how each person thinks: the step after the coach's run, the reads the pages show, the
/// per-person switch, and the cover while the owner shares the screen or records a call with that person.
extension AppController {
    /// Calls the in-app step reads in one run; the first fill (`Mossad --persona-fill`) reads the older ones.
    static let personaCallsPerRun = 10

    var personasOn: Bool { coachEnabled && personaEnabled }

    /// The person id of a name, on a sure match.
    func personID(of name: String) -> String? { shownCoachPeople.id(of: name).map(shownCoachPeople.canonical) }

    /// The read of a person, when the person has one and the owner keeps reads.
    func persona(of name: String) -> PersonaSummary? {
        guard personasOn else { return nil }
        return personID(of: name).flatMap { personaReads[$0] }
    }

    /// The per-person switch. True for a name that is no saved person: there is nothing to keep.
    func keepsRead(_ name: String) -> Bool {
        guard let id = personID(of: name) else { return true }
        return !shownCoachPeople.notProfiled.contains(id)
    }

    /// Off stops new evidence and deletes what the coach kept about the person. The meetings stay.
    func setKeepsRead(_ name: String, _ on: Bool) {
        guard let store = library.identity?.people, let id = personID(of: name) else { return }
        do {
            try store.setDoNotProfile(!on, for: PersonID(rawValue: id))
            if !on { forgetPersona(id) }
            Log.info(on ? "The coach keeps a read on a person again" : "The coach keeps no read on a person; its files are deleted")
        } catch {
            Log.error("The switch for a person's read was not saved: \(error)")
        }
        coachPeopleCache.set(0, version: coachVersion + 1, value: CoachPeople(people: store.people))
        coachVersion += 1
        syncNow()
    }

    /// Deletes what the coach knows about how a person thinks: each file of the person and of the records they took in.
    func forgetPersona(_ id: String) {
        let store = PersonaStore(paths: paths)
        for one in shownCoachPeople.ids(of: id) + [id] { store.delete(one) }
    }

    /// "Delete" on the People page: the person's read goes with them.
    func forgetPersona(named name: String) {
        if let id = personID(of: name) { forgetPersona(id) }
    }

    /// The persona step for the calls that are due: after the coach's run, never while a call is recorded.
    func runPersonas() async {
        guard !isInert, personasOn, !personasRunning, !isRecording else { return }
        let key = aiProvider.key.flatMap { keychain.get($0) }
        guard let made = PersonaExtractor.model(provider: aiProvider, chosen: aiModel, key: key, usage: usage, serverURL: localServerBase) else { return }
        if personaSince == 0 { personaSince = Date().timeIntervalSince1970 }
        personasRunning = true
        defer { personasRunning = false }
        let runner = PersonaRunner(paths: paths, llm: made.llm, owner: ownerName)
        let report = await runner.run(since: Date(timeIntervalSince1970: personaSince), callLimit: Self.personaCallsPerRun,
                                      isLive: { await MainActor.run { self.isRecording } })
        if report.calls + report.people > 0 {
            Log.info("Persona step: \(report.calls) calls, \(report.requests) requests, sentences for \(report.people) people")
            coachVersion += 1
        }
    }

    // MARK: The cover

    /// The people of the call being recorded, by id: who speaks and who was invited.
    var livePeople: Set<String> {
        guard let r = meetings.first(where: isLive) else { return [] }
        let saved = shownCoachPeople
        var names = Array(r.speakerNames.values) + r.attendees
        names += (r.invitees ?? []).compactMap(\.name)
        var ids = Set(names.compactMap { saved.id(of: $0).map(saved.canonical) })
        ids.formUnion((r.speakerPeople ?? [:]).values.map(saved.canonical))
        ids.formUnion((r.invitees ?? []).compactMap(\.personID).map(saved.canonical))
        return ids
    }

    /// Whether a person's read is covered now: while the owner shares the screen, or records a call with them. The
    /// owner's click opens it until the share or the call ends.
    func personaCovered(_ id: String?) -> Bool {
        guard PersonaCover.isCovered(person: id, recording: isRecording, callPeople: livePeople, sharing: ownerSharing) else { return false }
        return !shownCovered.contains(id ?? "")
    }

    /// Opens a covered read with one click.
    func uncover(_ id: String?) { shownCovered.insert(id ?? "") }

    /// Reads the call apps' share bars every few seconds, off the main thread. A click that opened a card holds only
    /// for the share or the call it was made in.
    func startShareWatch() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).map {
                    (owner: $0[kCGWindowOwnerName as String] as? String ?? "", title: $0[kCGWindowName as String] as? String)
                }
                let sharing = OwnerShare.isSharing(windows)
                Task { @MainActor in
                    guard let self else { return }
                    if self.ownerSharing != sharing { self.ownerSharing = sharing }
                    if sharing != true, !self.isRecording, !self.shownCovered.isEmpty { self.shownCovered = [] }
                }
            }
        }
    }
}
