import CryptoKit
import Foundation

/// What the move to person ids found, for the owner to check. Names only; no voice data.
public struct MigrationReport: Codable, Equatable, Sendable {
    public struct Totals: Codable, Equatable, Sendable {
        public var people = 0
        public var newPeople = 0
        public var owners = 0
        public var verifiedEmails = 0
        public var samples = 0
        public var samplesWithProvenance = 0
        /// Pairs of samples of one person that are near copies. They stay in this phase.
        public var nearCopies = 0
        public var meetings = 0
        public var meetingsUnreadable = 0
        public var speakerNames = 0
        public var speakerNamesResolved = 0
        public var invitedEmails = 0
        public var invitedEmailsResolved = 0
        public var invitedNames = 0
        public var invitedNamesResolved = 0
        public var actionItems = 0
        public var actionItemsWithNoOwner = 0
        public var actionItemOwners = 0
        public var actionItemOwnersExact = 0
        public var actionItemOwnersByShortForm = 0
        public var commitmentNames = 0
        public var commitmentNamesResolved = 0
        public var coachNotes = 0
        public var coachNotesResolved = 0
        public var orgMatches = 0
        public var orgMatchesResolved = 0
        public var distinctPairs = 0
    }

    /// A written name that is a saved person now, and was not by the plain comparison of before.
    public struct Link: Codable, Equatable, Sendable {
        public var written: String
        public var person: String
        /// The rule in plain words.
        public var rule: String
        public var meetings: Int
    }

    public struct Unresolved: Codable, Equatable, Sendable {
        /// "speaker", "invited name", "invited email", "action item owner", "commitment", "org match", or "not duplicates".
        public var kind: String
        public var label: String
        /// The call ids it is in.
        public var meetings: [String]
        public var why: String
    }

    public struct Orphan: Codable, Equatable, Sendable {
        public var key: String
        public var why: String
    }

    public struct LooseSample: Codable, Equatable, Sendable {
        public var person: String
        public var count: Int
        public var why: String
    }

    public var totals = Totals()
    public var newLinks: [Link] = []
    public var notResolved: [Unresolved] = []
    public var orphans: [Orphan] = []
    public var samplesWithoutProvenance: [LooseSample] = []
    /// What stops the migration. With one error or more, nothing is applied.
    public var errors: [String] = []
    public var notes: [String] = []
}

/// The move from names to person ids. It writes two new files, `people.json` and `samples.json`, and changes no
/// old file: the voice library stays as it is and stays current. The plan is made first and is a file; applying
/// executes the plan, so a dry run and a real run are the same decisions. The same step runs at each launch and
/// brings the new files in step with the voice library again.
public enum PeopleMigration {
    public static let planName = "migration-plan.json"
    public static let reportName = "migration-report.md"

    /// A sample of the plan without its numbers. The numbers stay in the voice files.
    public struct PlannedSample: Codable, Equatable, Sendable {
        public var id: UUID
        public var personID: PersonID?
        /// `VoiceSample.key(of:)`: which fingerprint of the voice library it is.
        public var vector: String
        public var callID: String?
        public var speakerKey: String?
        public var track: String?
        public var recorded: Date?
        public var learned: Date
        public var seconds: Double?
        public var quality: Double?
        public var origin: VoiceSample.Origin

        init(_ s: VoiceSample) {
            id = s.id
            personID = s.personID
            vector = VoiceSample.key(of: s.vector)
            callID = s.callID
            speakerKey = s.speakerKey
            track = s.track
            recorded = s.recorded
            learned = s.learned
            seconds = s.seconds
            quality = s.quality
            origin = s.origin
        }

        func sample(_ numbers: [Float]) -> VoiceSample {
            var s = VoiceSample(id: id, personID: personID, vector: numbers,
                                source: VoiceSampleSource(callID: callID, speakerKey: speakerKey, recorded: recorded, seconds: seconds, quality: quality, origin: origin),
                                learned: learned)
            s.track = track
            return s
        }
    }

    public struct Plan: Codable, Equatable, Sendable {
        public var version = 1
        public var made: Date
        /// What the plan was made from. A plan is applied only to the same data.
        public var basis: String
        /// False when the new files already say all of this.
        public var changes: Bool
        public var people: [Person]
        public var samples: [PlannedSample]
        public var report: MigrationReport
    }

    public struct Input: Sendable {
        public var profiles: [VoiceProfile] = []
        public var records: [CallRecord] = []
        public var unreadableRecords = 0
        /// What `people.json` and `samples.json` hold now; empty before the first run.
        public var people: [Person] = []
        public var samples: [VoiceSample] = []
        /// "Your name" in Settings.
        public var ownerName = ""
        public var commitments: [Commitment] = []
        /// The names the coach keeps notes under.
        public var coachPeople: [String] = []
        /// The keys of `org-matches.json`: normalized saved names.
        public var orgMatches: [String] = []
        /// The pairs the owner called two people, as "Name|Name".
        public var notDuplicates: [String] = []
        public var errors: [String] = []
        public var basis = ""
        public var now = Date()

        public init() {}
    }

    // MARK: Reading

    /// Everything the plan is made from. It only reads: a file that does not decode stays where it is and becomes
    /// an error of the plan.
    public static func read(paths: Paths, ownerName: String, notDuplicates: [String], now: Date = Date()) -> Input {
        var input = Input()
        input.ownerName = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        input.notDuplicates = notDuplicates
        input.now = now
        var basis = SHA256()
        func data(_ url: URL) -> Data? {
            let data = try? Data(contentsOf: url)
            basis.update(data: Data(url.lastPathComponent.utf8))
            basis.update(data: data ?? Data())
            return data
        }
        let voices = paths.voices.appendingPathComponent("voices.json")
        if let d = data(voices) {
            do { input.profiles = try JSONDecoder().decode([VoiceProfile].self, from: d) } catch { input.errors.append("voices.json cannot be read: \(short(error))") }
        } else if FileManager.default.fileExists(atPath: voices.path) {
            input.errors.append("voices.json cannot be read")
        }
        if let d = data(paths.people.appendingPathComponent(PeopleStore.fileName)) {
            if let v = PeopleStore.version(of: d), v > PeopleStore.currentVersion {
                input.errors.append("people.json is from a newer Mossad (version \(v)); this build does not change it")
            } else if let people = PeopleStore.decode(d) {
                input.people = people
            } else {
                input.errors.append("people.json cannot be read")
            }
        }
        if let d = data(paths.voices.appendingPathComponent(VoiceSampleStore.fileName)) {
            if let samples = VoiceSampleStore.decode(d) { input.samples = samples } else { input.errors.append("samples.json cannot be read") }
        }
        if let scan = try? ProcessingQueue(paths: paths).scan() {
            input.records = scan.records.sorted { $0.start < $1.start }
            input.unreadableRecords = scan.unreadable.count
        }
        for r in input.records { basis.update(data: Data("\(r.id)|\(r.speakerNames.count)|\(r.attendees.count)|\(r.actionItems.count)\n".utf8)) }
        input.commitments = CommitmentBook.peek(in: paths.commitments)?.items ?? []
        // Only the names of the coach's notes are read, not the notes.
        if let d = try? Data(contentsOf: paths.coach.appendingPathComponent("profile.json")),
           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let notes = json["people"] as? [String: Any] {
            input.coachPeople = notes.keys.sorted()
        }
        input.orgMatches = OrgMatches.load(paths: paths).byName.keys.sorted()
        input.basis = basis.finalize().prefix(12).map { String(format: "%02x", $0) }.joined()
        return input
    }

    private static func short(_ error: Error) -> String { String(String(describing: error).prefix(160)) }

    // MARK: The plan

    public static func plan(_ input: Input, makeID: () -> PersonID = { PersonID() }, makeSampleID: () -> UUID = { UUID() }) -> Plan {
        let now = input.now
        var people = input.people
        var report = MigrationReport()
        report.errors = input.errors

        // Step 1: one person for each voice profile.
        var profilePerson: [PersonID] = []
        let profileNames = Set(input.profiles.map(\.name))
        var owners: [String: Set<PersonID>] = [:]
        for s in input.samples { if let id = s.personID { owners[VoiceSample.key(of: s.vector), default: []].insert(id) } }
        for profile in input.profiles {
            let id: PersonID
            if let known = PeopleStore.id(forVoiceName: profile.name, isOwner: profile.isOwner, in: people) {
                id = known
            } else if let renamed = renamedPerson(of: profile, owners: owners, people: people, profileNames: profileNames),
                      let i = people.firstIndex(where: { $0.id == renamed }) {
                // An older build renamed the profile: the same voice under a new name is the same person.
                report.notes.append("\"\(people[i].displayName)\" has the name \"\(profile.name)\" in the voice library now; the person was renamed.")
                people[i].rename(to: profile.name, source: .migration, at: now)
                id = renamed
            } else {
                let person = Person(id: makeID(), displayName: profile.name, isOwner: profile.isOwner, origin: .migration, at: now)
                people.append(person)
                report.totals.newPeople += 1
                id = person.id
            }
            // The email of the profile is the one the owner picked: verified.
            if let i = people.firstIndex(where: { $0.id == id }) { people[i].setVerifiedEmail(profile.email, at: now) }
            profilePerson.append(id)
        }
        // The owner is a person, also with no voice profile.
        if !input.ownerName.isEmpty {
            if let i = people.firstIndex(where: { $0.isOwner && $0.isLive }) {
                people[i].rename(to: input.ownerName, source: .owner, at: now)
            } else {
                people.append(Person(id: makeID(), displayName: input.ownerName, isOwner: true, origin: .owner, at: now))
                report.totals.newPeople += 1
            }
        }

        // Step 10: the pairs the owner called two people.
        func exact(_ name: String) -> PersonID? {
            let hits = people.filter { $0.isLive && $0.displayName == name }
            return hits.count == 1 ? hits[0].id : nil
        }
        for pair in input.notDuplicates {
            let names = pair.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard names.count == 2, let a = exact(names[0]), let b = exact(names[1]), a != b,
                  let i = people.firstIndex(where: { $0.id == a }), let j = people.firstIndex(where: { $0.id == b }) else {
                report.notResolved.append(.init(kind: "not duplicates", label: pair.replacingOccurrences(of: "|", with: " and "), meetings: [],
                                                why: "one of the two names is not a saved person now"))
                continue
            }
            if !people[i].distinctFrom.contains(b) { people[i].distinctFrom.append(b); people[i].updated = now }
            if !people[j].distinctFrom.contains(a) { people[j].distinctFrom.append(a); people[j].updated = now }
            report.totals.distinctPairs += 1
        }

        // Step 2: each fingerprint of the voice library is a sample of its person, with the call it came from.
        let ownerID = people.first { $0.isOwner && $0.isLive }?.id
        let owner = OwnerIdentity(name: input.ownerName, also: people.first { $0.isOwner && $0.isLive }?.forms.map(\.text) ?? [])
        var seenInCalls: [String: [(record: Int, key: String)]] = [:]
        for (i, r) in input.records.enumerated() {
            for (key, vector) in r.speakerEmbeddings { seenInCalls[VoiceSample.key(of: vector), default: []].append((i, key)) }
        }
        var existing: [String: VoiceSample] = [:]
        for s in input.samples { if let id = s.personID { existing[id.rawValue + "|" + VoiceSample.key(of: s.vector)] = existing[id.rawValue + "|" + VoiceSample.key(of: s.vector)] ?? s } }
        var samples: [PlannedSample] = []
        var planned: Set<String> = []
        for (profile, id) in zip(input.profiles, profilePerson) {
            var loose: [String: Int] = [:]
            for vector in profile.embeddings {
                let vectorKey = VoiceSample.key(of: vector), slot = id.rawValue + "|" + vectorKey
                guard planned.insert(slot).inserted else { continue }
                let calls = seenInCalls[vectorKey] ?? []
                let named = calls.filter { hit in
                    let name = input.records[hit.record].speakerNames[hit.key]
                    return name == profile.name || (profile.isOwner && name.map(owner.isOwner) == true)
                }.min { input.records[$0.record].start < input.records[$1.record].start }
                var sample = existing[slot] ?? VoiceSample(id: makeSampleID(), personID: id, vector: vector, source: VoiceSampleSource(origin: .migrated), learned: now)
                // A sample with no call gets one when a call record has the same fingerprint for the same person.
                if sample.callID == nil, sample.origin == .migrated, let hit = named {
                    let r = input.records[hit.record]
                    sample.take(VoiceSampleSource(callID: r.id, speakerKey: hit.key, recorded: r.start,
                                                  seconds: r.speakerSamples?[hit.key]?.seconds ?? SpeakerIdentifier.speechUsed(r.utterances.filter { $0.speakerKey == hit.key }),
                                                  quality: r.speakerSamples?[hit.key]?.quality, origin: .migrated))
                    sample.learned = r.start
                }
                if sample.callID == nil {
                    let why: String
                    if let other = calls.first {
                        let r = input.records[other.record]
                        why = r.speakerNames[other.key].map { "the call \(r.id) has this voice under the name \"\($0)\"" } ?? "the call \(r.id) has this voice with no name"
                    } else {
                        why = "no call record has this fingerprint"
                    }
                    loose[why, default: 0] += 1
                }
                samples.append(PlannedSample(sample))
            }
            for (why, count) in loose.sorted(by: { $0.key < $1.key }) { report.samplesWithoutProvenance.append(.init(person: profile.name, count: count, why: why)) }
            for (i, a) in profile.embeddings.enumerated() {
                for b in profile.embeddings[(i + 1)...] where VoiceLibrary.cosine(a, b) >= VoiceSamples.sameSample { report.totals.nearCopies += 1 }
            }
        }
        // A sample with no person, or of a person this plan does not know, is kept: never deleted here.
        let known = Set(people.map(\.id))
        samples += input.samples.filter { $0.personID.map { !known.contains($0) } ?? true }.map(PlannedSample.init)

        // Steps 3 to 9: who each written name is. The new files do not hold these links yet; the report shows them.
        // Forms that a calendar showed before are left out, so the report gives the same rule on each run.
        let resolver = PersonResolver(people: people.map { p in
            var p = p
            p.forms.removeAll { $0.kind == .seen }
            return p
        })
        let display = Dictionary(people.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let strong: Set<Resolution.Rule> = [.ownerLink, .verifiedEmail, .seenEmail, .externalID, .nameForm, .provedOrder, .sameName]
        var labels = Labels()
        var links: [String: (person: PersonID, rule: Resolution.Rule, meetings: Int)] = [:]
        var seenForms: [(PersonID, String)] = [], seenEmails: [(PersonID, String)] = []
        var contexts: [String: ResolutionContext] = [:]

        func why(_ r: Resolution) -> String {
            switch r {
            case .ambiguous(let ids, _): "\(ids.count) saved people fit: " + ids.compactMap { display[$0] }.joined(separator: ", ")
            case .suggestion(let id, let rule, _): "probably \(display[id] ?? "a saved person") (\(rule.words)); not sure enough for a link"
            default: "no saved person fits"
            }
        }

        /// The owner under each of their names, then the rules.
        func resolve(_ o: Observation, in context: ResolutionContext?) -> Resolution {
            if let ownerID, o.email == nil, let name = o.name, owner.isOwner(name) { return .resolved(ownerID, rule: .nameForm, confidence: .strong) }
            return resolver.resolve(o, in: context)
        }
        /// Whether the comparison of before this phase read the written name as that person: the same text in any
        /// case, or a short form. Such a link is not new.
        func oldRule(_ written: String, _ id: PersonID) -> Bool {
            guard let name = display[id] else { return false }
            return PeopleDuplicates.normalized(written) == PeopleDuplicates.normalized(name) || PersonDirectory.isForm(written, of: name)
        }

        for r in input.records {
            var roster: [PersonID] = [], others: [String] = []
            for (_, name) in r.speakerNames.sorted(by: { $0.key < $1.key }) {
                // The voice library wrote this label: the profile with exactly this name is the person.
                let answer = exact(name).map { Resolution.resolved($0, rule: .nameForm, confidence: .strong) } ?? resolve(Observation(text: name), in: nil)
                if let id = answer.person, answer.rule.map(strong.contains) == true {
                    if !roster.contains(id) { roster.append(id) }
                    labels.add("speaker", name, r.id, resolved: true)
                } else {
                    others.append(name)
                    labels.add("speaker", name, r.id, resolved: false, why: why(answer))
                }
            }
            // The invited people: the pairs when the record has them, else one text for each.
            let invited: [Observation] = r.invitees.map { $0.map { Observation(name: $0.name, email: $0.email, source: .calendar) } }
                ?? r.attendees.map { Observation(text: $0, source: .calendar) }
            // First each entry by itself: a whole name or an address needs nobody around it. The people found so
            // are in the meeting; the names that stay are the other names of the meeting.
            let alone = invited.map { o -> Resolution in
                let answer = resolve(o, in: nil)
                return answer.person != nil && answer.rule.map(strong.contains) == true ? answer : .unknown
            }
            for answer in alone { if let id = answer.person, !roster.contains(id) { roster.append(id) } }
            var loose = zip(invited, alone).compactMap { $1.person == nil ? $0.name : nil }
            var there = roster
            for (o, sure) in zip(invited, alone) {
                // Then a short form or an unproved order, among the people of the meeting.
                let answer = sure.person != nil ? sure : resolve(o, in: ResolutionContext(roster: roster, otherNames: others + loose.filter { $0 != o.name }))
                guard let written = o.name else {
                    labels.add("invited email", o.email ?? "", r.id, resolved: answer.person != nil, why: "no saved person has this address")
                    continue
                }
                labels.add("invited name", written, r.id, resolved: answer.person != nil, why: why(answer))
                guard let id = answer.person, let rule = answer.rule else { continue }
                if !there.contains(id) { there.append(id) }
                loose.removeAll { $0 == written }
                // By the name alone: a name that only the address explains is not a form of this person.
                let byName = resolve(Observation(name: written, source: .calendar), in: nil)
                let named = byName.person == id && byName.rule.map(strong.contains) == true
                if named {
                    if PersonNames.nameKey(written) != PersonNames.nameKey(display[id] ?? "") { seenForms.append((id, written)) }
                    if let email = o.email, resolver.resolve(Observation(email: email)) == .unknown { seenEmails.append((id, email)) }
                }
                if !oldRule(written, id) { links[written] = (id, named ? byName.rule ?? rule : rule, (links[written]?.meetings ?? 0) + 1) }
            }
            let context = ResolutionContext(roster: there, otherNames: others + loose)
            contexts[r.id] = context
            // Step 6: action item owners, inside this call's people only.
            report.totals.actionItems += r.actionItems.count
            for item in r.actionItems {
                guard let written = item.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !written.isEmpty else {
                    report.totals.actionItemsWithNoOwner += 1
                    continue
                }
                let answer = resolve(Observation(name: written), in: context)
                let kind = answer.rule.map(strong.contains) == true ? "exact" : "short"
                labels.add("action item owner", written, r.id, resolved: answer.person != nil, why: why(answer), detail: answer.person == nil ? nil : kind)
            }
        }
        // Step 7: who a commitment was promised to, inside the people of its call.
        for c in input.commitments where !c.deleted {
            guard let to = c.to?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else { continue }
            let context = c.callID.flatMap { contexts[$0] }
            let answer = resolve(Observation(name: to), in: context)
            // A commitment made by hand has no call around it: only a sure rule counts.
            let sure = answer.person != nil && (context != nil || answer.rule.map(strong.contains) == true)
            labels.add("commitment", to, c.callID ?? "added by hand", resolved: sure, why: why(answer))
        }
        // Step 8: the coach's notes on people.
        let spoken = Set(input.records.flatMap { $0.speakerNames.values })
        report.totals.coachNotes = input.coachPeople.count
        for key in input.coachPeople {
            let answer = resolve(Observation(name: key), in: nil)
            if answer.person != nil, answer.rule.map(strong.contains) == true {
                report.totals.coachNotesResolved += 1
                continue
            }
            var reason = key.hasPrefix("Speaker ") ? "a speaker label, not a name" : why(answer)
            let parsed = PersonNames.parse(key)
            if parsed.isName, parsed.family == nil { reason = "one word; " + reason }
            reason += spoken.contains(key) ? "; calls use this name" : "; no call uses this name"
            report.orphans.append(.init(key: key, why: reason))
        }
        // Step 9: the owner's matches to the org file, by the normalized saved name.
        report.totals.orgMatches = input.orgMatches.count
        for key in input.orgMatches {
            let hits = people.filter { $0.isLive && OrgChart.normalize($0.displayName) == key }
            if hits.count == 1 { report.totals.orgMatchesResolved += 1 } else {
                report.notResolved.append(.init(kind: "org match", label: key, meetings: [], why: hits.isEmpty ? "no saved person has this name" : "\(hits.count) saved people have this name"))
            }
        }

        // What the calendar showed next to a person is kept on the person: the form, and the address of a pair.
        for (id, written) in seenForms {
            guard let i = people.firstIndex(where: { $0.id == id }), !people[i].forms.contains(where: { $0.key == PersonNames.nameKey(written) }) else { continue }
            people[i].addForm(written, kind: .seen, source: .calendar, confirmed: false, at: now)
        }
        for (id, email) in seenEmails {
            guard let i = people.firstIndex(where: { $0.id == id }) else { continue }
            people[i].addEmail(email, state: .seen, source: .calendar, at: now)
        }

        // Totals.
        report.totals.people = people.filter(\.isLive).count
        report.totals.owners = people.filter { $0.isOwner && $0.isLive }.count
        report.totals.verifiedEmails = people.filter(\.isLive).reduce(0) { $0 + $1.emails.filter { $0.state == .verified }.count }
        report.totals.samples = samples.count
        report.totals.samplesWithProvenance = samples.filter { $0.callID != nil }.count
        report.totals.meetings = input.records.count
        report.totals.meetingsUnreadable = input.unreadableRecords
        (report.totals.speakerNames, report.totals.speakerNamesResolved) = labels.count("speaker")
        (report.totals.invitedEmails, report.totals.invitedEmailsResolved) = labels.count("invited email")
        (report.totals.invitedNames, report.totals.invitedNamesResolved) = labels.count("invited name")
        (report.totals.commitmentNames, report.totals.commitmentNamesResolved) = labels.count("commitment")
        report.totals.actionItemOwners = labels.count("action item owner").all
        report.totals.actionItemOwnersExact = labels.count("action item owner", detail: "exact")
        report.totals.actionItemOwnersByShortForm = labels.count("action item owner", detail: "short")
        report.notResolved += labels.unresolved()
        report.newLinks = links.map { .init(written: $0.key, person: display[$0.value.person] ?? "", rule: $0.value.rule.words, meetings: $0.value.meetings) }
            .sorted { ($0.person, $0.written) < ($1.person, $1.written) }
        if report.totals.owners > 1 { report.errors.append("\(report.totals.owners) people are marked as the owner") }
        if input.unreadableRecords > 0 { report.notes.append("\(input.unreadableRecords) meetings could not be read and are not in the numbers.") }
        if report.totals.nearCopies > 0 { report.notes.append("\(report.totals.nearCopies) pairs of samples of one person are near copies. They stay; a sample learned again from one call replaces the old one from now on.") }

        // The order of the samples in the file is not a change.
        func ordered(_ list: [PlannedSample]) -> [PlannedSample] { list.sorted { $0.id.uuidString < $1.id.uuidString } }
        let changes = people != input.people || ordered(samples) != ordered(input.samples.map(PlannedSample.init))
        return Plan(made: now, basis: input.basis, changes: changes, people: people, samples: samples, report: report)
    }

    /// The person whose samples are this profile's fingerprints, when that person's name is no profile now.
    private static func renamedPerson(of profile: VoiceProfile, owners: [String: Set<PersonID>], people: [Person], profileNames: Set<String>) -> PersonID? {
        var found: Set<PersonID> = []
        for vector in profile.embeddings {
            guard let ids = owners[VoiceSample.key(of: vector)] else { continue }
            found.formUnion(ids)
        }
        guard found.count == 1, let id = found.first, let person = people.first(where: { $0.id == id && $0.isLive }),
              !profileNames.contains(person.displayName), !person.isOwner else { return nil }
        return id
    }

    /// Distinct written labels of one kind, with the calls they are in.
    private struct Labels {
        private struct Entry {
            var resolved = false
            var unresolvedIn: [String] = []
            var why = ""
            var detail: String?
        }

        private var entries: [String: [String: Entry]] = [:]
        private var order: [String: [String]] = [:]

        mutating func add(_ kind: String, _ label: String, _ meeting: String, resolved: Bool, why: String = "", detail: String? = nil) {
            if entries[kind]?[label] == nil { order[kind, default: []].append(label) }
            var e = entries[kind]?[label] ?? Entry()
            if resolved {
                e.resolved = true
                // An exact name in one call is the stronger fact about the label.
                if e.detail != "exact" { e.detail = detail ?? e.detail }
            } else {
                if !e.unresolvedIn.contains(meeting) { e.unresolvedIn.append(meeting) }
                e.why = why
            }
            entries[kind, default: [:]][label] = e
        }

        /// How many distinct labels there are, and how many resolve in one call or more.
        func count(_ kind: String) -> (all: Int, resolved: Int) {
            let all = entries[kind] ?? [:]
            return (all.count, all.values.filter(\.resolved).count)
        }

        func count(_ kind: String, detail: String) -> Int { (entries[kind] ?? [:]).values.filter { $0.resolved && $0.detail == detail }.count }

        func unresolved() -> [MigrationReport.Unresolved] {
            order.keys.sorted().flatMap { kind in
                (order[kind] ?? []).compactMap { label -> MigrationReport.Unresolved? in
                    guard let e = entries[kind]?[label], !e.unresolvedIn.isEmpty else { return nil }
                    return .init(kind: kind, label: label, meetings: e.unresolvedIn, why: e.resolved ? e.why + "; it resolves in other meetings" : e.why)
                }
            }
        }
    }

    // MARK: Apply and revert

    /// Writes the people and the samples of the plan. The numbers of each sample come from the voice library as it
    /// is now; a sample whose fingerprint left the library is not written.
    public static func apply(_ plan: Plan, people: PeopleStore, samples: VoiceSampleStore, profiles: [VoiceProfile]) throws {
        guard plan.report.errors.isEmpty else { throw MigrationError(plan.report.errors.joined(separator: "; ")) }
        var numbers: [String: [Float]] = [:]
        for vector in profiles.flatMap(\.embeddings) { numbers[VoiceSample.key(of: vector)] = vector }
        for s in samples.samples { numbers[VoiceSample.key(of: s.vector)] = numbers[VoiceSample.key(of: s.vector)] ?? s.vector }
        // The people first: a sample must never point to a person that is not there.
        let created = Set(plan.people.map(\.id)).subtracting(people.people.map(\.id))
        try people.replaceAll(plan.people, log: created.sorted().map { PeopleLogEntry(at: plan.made, kind: "migrate", actor: "migration", subject: $0) })
        try samples.replaceAll(plan.samples.compactMap { s in numbers[s.vector].map(s.sample) })
    }

    /// Takes the new files away. The voice library and each old file are as they were, because this phase changed
    /// none of them.
    @discardableResult
    public static func revert(paths: Paths) throws -> [String] {
        var removed: [String] = []
        let files = [paths.people.appendingPathComponent(PeopleStore.fileName), paths.people.appendingPathComponent(PeopleStore.logName),
                     paths.people.appendingPathComponent(planName), paths.people.appendingPathComponent(reportName),
                     paths.voices.appendingPathComponent(VoiceSampleStore.fileName)]
        for file in files + files.map({ $0.appendingPathExtension("recovered") }) where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
            removed.append(file.lastPathComponent)
        }
        return removed
    }

    public struct MigrationError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// Saves the plan and the report into a folder: the People folder, or another one for a look that must leave
    /// the data folder as it is.
    public static func write(_ plan: Plan, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(plan).write(to: folder.appendingPathComponent(planName), options: .atomic)
        try markdown(plan).write(to: folder.appendingPathComponent(reportName), atomically: true, encoding: .utf8)
    }

    // MARK: At launch

    /// Brings `people.json` and `samples.json` in step with the voice library, and gives the stores that follow it
    /// from then on. Nil when a file stops it: then the voice library works alone, as before. Only the main Mac
    /// app calls this, off the main thread.
    public static func runAtLaunch(paths: Paths, library: VoiceLibrary, ownerName: String, notDuplicates: [String], now: Date = Date()) -> VoiceIdentity? {
        guard library.loadError == nil else {
            Log.error("People: the voice library could not be read, so the people store waits")
            return nil
        }
        let people = PeopleStore(directory: paths.people), samples = VoiceSampleStore(directory: paths.voices)
        // A file that was damaged is set aside by its store, and the plan below makes it again from the voice library.
        if people.isReadOnly || (people.loadError as? UnreadableFile).map({ $0.kept == nil }) ?? (people.loadError != nil) {
            Log.error("People: people.json cannot be changed by this build, so the people store waits")
            return nil
        }
        if let error = samples.loadError, (error as? UnreadableFile)?.kept == nil {
            Log.error("People: samples.json cannot be read, so the people store waits")
            return nil
        }
        var input = read(paths: paths, ownerName: ownerName, notDuplicates: notDuplicates, now: now)
        // The stores and the library in memory are the truth of this run.
        input.profiles = library.profiles
        input.people = people.people
        input.samples = samples.samples
        input.errors.removeAll { $0.hasPrefix("people.json") || $0.hasPrefix("samples.json") }
        let plan = plan(input)
        guard plan.report.errors.isEmpty else {
            Log.error("People: the migration waits: \(plan.report.errors.joined(separator: "; "))")
            return nil
        }
        if plan.changes {
            do {
                try apply(plan, people: people, samples: samples, profiles: input.profiles)
                try? write(plan, to: paths.people)
                let t = plan.report.totals
                Log.info("People: \(t.people) people (\(t.newPeople) new), \(t.samples) voice samples (\(t.samplesWithProvenance) with their call); the report is \(reportName) in the People folder")
            } catch {
                Log.error("People: the migration could not be saved: \(error)")
                return nil
            }
        }
        return VoiceIdentity(people: people, samples: samples)
    }

    // MARK: The command

    /// `Mossad --people-migration dry-run | apply | revert [--out <folder>]`. A dry run changes nothing in the data
    /// folder when `--out` names another folder for the plan and the report. Returns the text to print and the
    /// exit code.
    public static func command(_ arguments: [String], paths: Paths, ownerName: String, notDuplicates: [String], now: Date = Date()) -> (text: String, status: Int32) {
        let usage = "Usage: Mossad --people-migration dry-run | apply | revert [--out <folder>]"
        guard let at = arguments.firstIndex(of: "--people-migration"), arguments.count > at + 1 else { return (usage, 2) }
        let mode = arguments[at + 1]
        let out = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        switch mode {
        case "dry-run":
            let plan = plan(read(paths: paths, ownerName: ownerName, notDuplicates: notDuplicates, now: now))
            let folder = out ?? paths.people
            do { try write(plan, to: folder) } catch { return ("The plan could not be saved in \(folder.path): \(error)", 1) }
            return (summary(plan) + "\nNothing was changed. The plan and the report are in \(folder.path).", plan.report.errors.isEmpty ? 0 : 1)
        case "apply", "revert":
            // One writer: the app holds these files in memory while it runs.
            switch InstanceLock.acquire(root: paths.root) {
            case .taken: return ("Mossad is open. Quit Mossad first: it holds these files.", 1)
            case .failed(let code): return ("Could not lock \(paths.root.path): \(String(cString: strerror(code)))", 1)
            case .held(let lock):
                defer { withExtendedLifetime(lock) {} }
                if mode == "revert" {
                    do {
                        let removed = try revert(paths: paths)
                        return (removed.isEmpty ? "There was nothing to remove." : "Removed: " + removed.joined(separator: ", ") + ". The voice library and each other file are as they were.", 0)
                    } catch { return ("Revert failed: \(error)", 1) }
                }
                let input = read(paths: paths, ownerName: ownerName, notDuplicates: notDuplicates, now: now)
                // The plan of the dry run, when it was made from the same data. Its ids are the ids.
                var plan = (try? Data(contentsOf: (out ?? paths.people).appendingPathComponent(planName)))
                    .flatMap { try? JSONDecoder.callRecord.decode(Plan.self, from: $0) }
                var note = "The plan of the dry run was applied."
                if plan?.basis != input.basis {
                    plan = self.plan(input)
                    note = "No plan of the same data was there, so a new plan was made and applied."
                }
                guard let plan else { return ("No plan.", 1) }
                guard plan.report.errors.isEmpty else { return (summary(plan) + "\nNothing was changed.", 1) }
                do {
                    try apply(plan, people: PeopleStore(directory: paths.people), samples: VoiceSampleStore(directory: paths.voices), profiles: input.profiles)
                    try write(plan, to: paths.people)
                } catch { return ("Apply failed: \(error)", 1) }
                return (summary(plan) + "\n" + note, 0)
            }
        default:
            return (usage, 2)
        }
    }

    // MARK: The report

    public static func summary(_ plan: Plan) -> String {
        let t = plan.report.totals
        var lines = [
            "People: \(t.people) (\(t.newPeople) new), \(t.owners) owner, \(t.verifiedEmails) verified emails",
            "Voice samples: \(t.samples), \(t.samplesWithProvenance) with their call, \(t.samples - t.samplesWithProvenance) without",
            "Speaker names: \(t.speakerNamesResolved) of \(t.speakerNames) resolve",
            "Invited emails: \(t.invitedEmailsResolved) of \(t.invitedEmails) resolve",
            "Invited names: \(t.invitedNamesResolved) of \(t.invitedNames) resolve (\(plan.report.newLinks.count) new links)",
            "Action item owners: \(t.actionItemOwnersExact) exact and \(t.actionItemOwnersByShortForm) by a short form, of \(t.actionItemOwners); \(t.actionItemsWithNoOwner) of \(t.actionItems) items have no owner",
            "Commitment names: \(t.commitmentNamesResolved) of \(t.commitmentNames) resolve",
            "Coach notes: \(t.coachNotesResolved) of \(t.coachNotes) resolve; \(plan.report.orphans.count) orphans",
            "Org matches: \(t.orgMatchesResolved) of \(t.orgMatches) resolve",
        ]
        if !plan.report.errors.isEmpty { lines.insert("ERRORS: " + plan.report.errors.joined(separator: "; "), at: 0) }
        return lines.joined(separator: "\n")
    }

    public static func markdown(_ plan: Plan) -> String {
        let r = plan.report
        var out = ["# People migration", "", "Made \(plan.made.formatted(.iso8601)). This phase writes `people.json` and `samples.json` and changes no old file.", ""]
        if !r.errors.isEmpty {
            out += ["## Errors", "", "Nothing is applied while these stay."] + r.errors.map { "- \($0)" } + [""]
        }
        out += ["## Totals", ""] + summary(plan).split(separator: "\n").filter { !$0.hasPrefix("ERRORS") }.map { "- \($0)" } + [""]
        if !r.notes.isEmpty { out += r.notes.map { "- \($0)" } + [""] }
        out += ["## New links", "", "Written names that are a saved person now."]
        out += r.newLinks.isEmpty ? ["- None."] : r.newLinks.map { "- \($0.written) → \($0.person), \($0.rule), \($0.meetings) meeting\($0.meetings == 1 ? "" : "s")" }
        out += ["", "## Not resolved", "", "These stay labels, as they are today. Nothing here needs an answer."]
        out += r.notResolved.isEmpty ? ["- None."] : r.notResolved.map { u in
            "- \(u.kind): \(u.label): \(u.why)" + (u.meetings.isEmpty ? "" : " (\(u.meetings.prefix(6).joined(separator: ", "))\(u.meetings.count > 6 ? ", and \(u.meetings.count - 6) more" : ""))")
        }
        out += ["", "## Orphans", "", "Notes of the coach under a name that is no saved person."]
        out += r.orphans.isEmpty ? ["- None."] : r.orphans.map { "- \($0.key): \($0.why)" }
        out += ["", "## Samples with no provenance", "", "Voice samples that no call record explains. They stay, with no call."]
        out += r.samplesWithoutProvenance.isEmpty ? ["- None."] : r.samplesWithoutProvenance.map { "- \($0.person): \($0.count), \($0.why)" }
        return out.joined(separator: "\n") + "\n"
    }
}
