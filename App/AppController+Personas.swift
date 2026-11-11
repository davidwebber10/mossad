import AppKit
import Foundation
import MossadCore

/// The coach's reads of how each person thinks: the step after the coach's run, the reads the pages show, the
/// per-person switch, and the cover while the owner shares the screen or records a call with that person.
extension AppController {
    /// Calls the in-app step reads in one run; the first fill (`Mossad --persona-fill`) reads the older ones.
    static let personaCallsPerRun = 10

    var personasOn: Bool { coachEnabled && personaEnabled }

    /// The people for the reads: the store's when it runs, else a look at `people.json` that only reads (a preview,
    /// or the time before the store is ready). The reads are by id, so they need the ids either way.
    var personaPeople: CoachPeople {
        let shown = shownCoachPeople
        return shown.isEmpty ? coachPeopleCache.value(1, version: coachVersion) { CoachPeople.read(paths: paths) } : shown
    }

    /// The person id of a name, on a sure match.
    func personID(of name: String) -> String? {
        let saved = personaPeople
        return saved.id(of: name).map(saved.canonical)
    }

    /// The read of a person, when the person has one and the owner keeps reads.
    func persona(of name: String) -> PersonaSummary? {
        guard personasOn else { return nil }
        return personID(of: name).flatMap { personaReads[$0] }
    }

    /// The per-person switch. True for a name that is no saved person: there is nothing to keep.
    func keepsRead(_ name: String) -> Bool {
        guard let id = personID(of: name) else { return true }
        return !personaPeople.notProfiled.contains(id)
    }

    /// Off stops new evidence and deletes what the coach kept about the person. The meetings stay.
    func setKeepsRead(_ name: String, _ on: Bool) {
        guard let store = library.identity?.people, let id = personID(of: name) else { return }
        do {
            try store.setDoNotProfile(!on, for: PersonID(rawValue: id))
            if !on { forgetPersona(id) } else { rereadCalls(of: id) }
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
        for one in personaPeople.ids(of: id) + [id] { store.delete(one) }
    }

    /// The read is on again: the person's calls are due again, so the old calls count.
    private func rereadCalls(of id: String) {
        let saved = personaPeople, dir = PersonaStore(paths: paths).directory
        var ledger = PersonaLedger.load(from: dir)
        // Due, and older: they draw on the budget of older calls, never as new calls.
        ledger.markDue(Set(meetings.filter { PersonaReads.callsWith([$0], saved: saved)[id] != nil }.map(\.id)))
        ledger.save(to: dir)
    }

    /// "Delete" on the People page: the person's read goes with them.
    func forgetPersona(named name: String) {
        if let id = personID(of: name) { forgetPersona(id) }
    }

    /// The persona step: new calls with the usual step, older calls within the budget of `PersonaBudget` (the first
    /// fill, calls read again after a change), then the sentences. After the coach's run and at launch, never while a
    /// call is recorded, and only after the records have their people's ids.
    func runPersonas() async {
        guard !isInert, personasOn, !personasRunning, !isRecording else { return }
        let key = aiProvider.key.flatMap { keychain.get($0) }
        guard let made = PersonaExtractor.model(provider: aiProvider, chosen: aiModel, key: key, usage: usage, serverURL: localServerBase) else { return }
        if personaSince == 0 { personaSince = Date().timeIntervalSince1970 }
        personasRunning = true
        defer { personasRunning = false }
        let usage = usage
        let out = await PersonaBacklog.run(runner: PersonaRunner(paths: paths, llm: made.llm, owner: ownerName), paths: paths, owner: ownerName, model: made.name,
                                           service: made.service, since: Date(timeIntervalSince1970: personaSince), referencesReady: peopleReferencesReady,
                                           callsPerRound: Self.personaCallsPerRun,
                                           spent: { from in usage.all().filter { $0.purpose == .persona && $0.date >= from }.reduce(0) { $0 + Pricing.cost($1) } },
                                           isLive: { await MainActor.run { self.isRecording } })
        personaFillNote = out.note
        personaFillYesGives = out.yesGives
        let calls = out.newCalls.calls + out.olderCalls.calls
        if calls + out.newCalls.people > 0 {
            // Counts only, never words.
            Log.info("Persona step: \(out.newCalls.calls) new calls, \(out.olderCalls.calls) older calls, \(out.newCalls.requests + out.olderCalls.requests) requests, sentences for \(out.newCalls.people) people")
            coachVersion += 1
        }
    }

    /// The owner's yes in Settings > Coach for the older calls that wait: for this model, with its own cap.
    func approvePersonaFill() {
        let key = aiProvider.key.flatMap { keychain.get($0) }
        guard let made = PersonaExtractor.model(provider: aiProvider, chosen: aiModel, key: key, usage: nil, serverURL: localServerBase) else { return }
        let paths = paths, owner = ownerName, since = Date(timeIntervalSince1970: personaSince)
        personaFillNote = nil
        Task {
            await Task.detached(priority: .utility) {
                PersonaBacklog.approve(paths: paths, owner: owner, model: made.name, service: made.service, since: since)
            }.value
            await runPersonas()
        }
    }

    // MARK: The cover

    /// The people of the call being recorded, by id: who speaks and who was invited.
    var livePeople: Set<String> {
        guard let r = meetings.first(where: isLive) else { return [] }
        let saved = personaPeople
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
            MainActor.assumeIsolated {
            // Only while there are reads to cover.
            guard let self, self.personasOn else { return }
            DispatchQueue.global(qos: .utility).async {
                // With no Screen Recording permission the titles of other apps cannot be read: not known.
                let own = ProcessInfo.processInfo.processIdentifier
                let sharing: Bool? = CGPreflightScreenCaptureAccess()
                    ? OwnerShare.isSharing((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) != own }
                        .map { (owner: $0[kCGWindowOwnerName as String] as? String ?? "", title: $0[kCGWindowName as String] as? String) })
                    : nil
                Task { @MainActor in
                    // A card opened before a share or a call is covered again when one starts.
                    if sharing == true, self.ownerSharing != true { self.shownCovered = [] }
                    if self.isRecording, !self.coverWasRecording { self.shownCovered = [] }
                    self.coverWasRecording = self.isRecording
                    if self.ownerSharing != sharing { self.ownerSharing = sharing }
                    if sharing != true, !self.isRecording, !self.shownCovered.isEmpty { self.shownCovered = [] }
                }
            }
            }
        }
    }
}
