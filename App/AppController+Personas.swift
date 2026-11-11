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
        for r in meetings where PersonaReads.callsWith([r], saved: saved)[id] != nil { ledger.calls[r.id] = nil }
        ledger.save(to: dir)
    }

    /// "Delete" on the People page: the person's read goes with them.
    func forgetPersona(named name: String) {
        if let id = personID(of: name) { forgetPersona(id) }
    }

    /// The persona step for the calls that are due: after the coach's run and at launch, never while a call is
    /// recorded. The first time, it also reads the stored calls (the first fill), newest first, with a hard cap
    /// of $1 across launches. A fill that would cost more, or whose price is not known, waits for the owner's yes in
    /// Settings > Coach.
    func runPersonas() async {
        guard !isInert, personasOn, !personasRunning, !isRecording else { return }
        let key = aiProvider.key.flatMap { keychain.get($0) }
        guard let made = PersonaExtractor.model(provider: aiProvider, chosen: aiModel, key: key, usage: usage, serverURL: localServerBase) else { return }
        if personaSince == 0 { personaSince = Date().timeIntervalSince1970 }
        personasRunning = true
        defer { personasRunning = false }
        let paths = paths, owner = ownerName, usage = usage
        let price = PersonaFill.price(service: made.service, model: made.name)
        let runner = PersonaRunner(paths: paths, llm: made.llm, owner: owner)
        // The fill waits for the people's ids: a call read before them gives no evidence.
        var filling = false
        if !personaFillDone, library.identity != nil {
            let e = await Task.detached(priority: .utility) { PersonaRunner.estimate(paths: paths, owner: owner, since: nil, price: price.cost) }.value
            if e.calls == 0 {
                personaFillDone = true
                personaFillNote = nil
            } else if personaFillApproved || (price.known && e.dollars <= PersonaFill.defaultCap) {
                filling = true
                personaFillNote = nil
                if personaFillStart == 0 {
                    personaFillStart = Date().timeIntervalSince1970
                    Log.info(String(format: "The first fill of the reads starts: %d calls, about $%.2f", e.calls, e.dollars))
                }
            } else {
                personaFillCap = min(PersonaFill.maxCap, max(PersonaFill.defaultCap, (e.dollars * 1.25 * 100).rounded(.up) / 100))
                personaFillNote = price.known
                    ? String(format: "Reading your %d older calls once would cost about $%.2f, more than the $1 that Mossad spends by itself.", e.calls, e.dollars)
                    : "Mossad does not know the price of \(made.name), so it does not read your \(e.calls) older calls by itself."
            }
        }
        let start = Date(timeIntervalSince1970: personaFillStart)
        let cap = personaFillApproved ? personaFillCap : PersonaFill.defaultCap
        let known = price.known
        let canSpend: @Sendable (Double) -> Bool = { cost in
            guard known else { return true }
            let spent = usage.all().filter { $0.purpose == .persona && $0.date >= start }.reduce(0) { $0 + Pricing.cost($1) }
            return spent + cost <= cap
        }
        var rounds = 0
        repeat {
            rounds += 1
            let report = await runner.run(since: filling || personaFillDone ? nil : Date(timeIntervalSince1970: personaSince), callLimit: Self.personaCallsPerRun,
                                          newestFirst: filling, isLive: { await MainActor.run { self.isRecording } },
                                          canSpend: filling ? canSpend : { _ in true }, price: price.cost)
            if report.calls + report.people > 0 {
                Log.info("Persona step: \(report.calls) calls, \(report.requests) requests, sentences for \(report.people) people")
                coachVersion += 1
            }
            guard filling else { break }
            if report.stopped != nil { break }
            if report.calls < Self.personaCallsPerRun {
                personaFillDone = true
                let spent = usage.all().filter { $0.purpose == .persona && $0.date >= start }.reduce(0) { $0 + Pricing.cost($1) }
                Log.info(String(format: "The first fill of the reads is done: $%.2f spent", spent))
                break
            }
        } while rounds < 30 && !isRecording
    }

    /// "Read the older calls" in Settings > Coach: the owner's yes to a fill above $1, with its own cap.
    func approvePersonaFill() {
        personaFillApproved = true
        personaFillNote = nil
        Task { await runPersonas() }
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
