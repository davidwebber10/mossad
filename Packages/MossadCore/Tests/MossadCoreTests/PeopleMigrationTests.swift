import XCTest
@testable import MossadCore

/// The move to person ids on a made-up data folder: names written last name first, two people with one name,
/// notes of the coach with no person, and voice samples that no call explains.
final class PeopleMigrationTests: XCTestCase {
    var paths: Paths!
    var out: URL!
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let notDuplicates = ["Dana Lee|Sam Carter", "Gone Person|Sam Carter"]

    // One fingerprint for each voice.
    private let owner1: [Float] = [1, 0, 0, 0], sam1: [Float] = [0, 1, 0, 0], sam2: [Float] = [0, 0.9, 0.1, 0], sam3: [Float] = [0, 0.8, 0, 0.2]
    private let dana1: [Float] = [0, 0, 1, 0], riley1: [Float] = [0, 0, 0, 1]

    override func setUpWithError() throws {
        paths = Paths(root: tempDirectory())
        out = tempDirectory()
        try paths.ensureDirectories()
        let library = VoiceLibrary(directory: paths.voices)
        try library.add(owner1, to: "Avery Webb", isOwner: true)
        for v in [sam1, sam2, sam3] { try library.add(v, to: "Sam Carter") }
        try library.setEmail("sam.carter@example.com", for: "Sam Carter")
        try library.add(dana1, to: "Dana Lee")
        try library.setEmail("mreed@example.com", for: "Michael Reed")
        try library.add(riley1, to: "Riley Chen")
        try library.setEmail("riley@example.org", for: "riley chen")

        var a = CallRecord(id: "20261105-100000", platform: .meet, bundleID: "b", start: t0, end: t0.addingTimeInterval(1800), status: .written)
        a.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        a.speakerEmbeddings = ["me:A": owner1, "them:A": sam1]
        a.attendees = ["Carter, Sam", "Lee, Dana", "dana@nowhere.example.com", "sam.carter@example.com", "Chen, Riley", "Quinn Mallory Okafor Baptiste Devereux"]
        a.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 8, text: "Hello."), Utterance(track: .them, speakerLabel: "A", start: 10, end: 22, text: "Hello.")]
        a.actionItems = [ActionItem(owner: "Sam", task: "send the plan"), ActionItem(owner: "Sam Carter", task: "book the room"),
                         ActionItem(owner: nil, task: "check the budget"), ActionItem(owner: "Jordan", task: "call the vendor")]
        var b = CallRecord(id: "20261106-100000", platform: .meet, bundleID: "b", start: t0.addingTimeInterval(86_400), end: t0.addingTimeInterval(88_200), status: .written)
        b.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter", "them:B": "Pat Moreno"]
        b.speakerEmbeddings = ["them:A": sam2, "them:B": dana1]
        b.speakerSamples = ["them:A": SpeakerSampleDetail(seconds: 33, quality: 0.7)]
        b.attendees = ["Carter, Sam", "mreed@example.com"]
        b.invitees = [Invitee(name: "Carter, Sam", email: "s.carter@example.org"), Invitee(name: nil, email: "mreed@example.com")]
        for r in [a, b] {
            try FileManager.default.createDirectory(at: paths.callDirectory(r.id), withIntermediateDirectories: true)
            try r.save(to: paths.callDirectory(r.id))
        }

        var book = CommitmentBook()
        book.add(found: [Commitment(text: "Send the plan", to: "Sam Carter", callID: a.id, callTitle: "T", madeAt: t0, due: nil),
                         Commitment(text: "Share the notes", to: "Sam", callID: a.id, callTitle: "T", madeAt: t0, due: nil)], callID: a.id, at: t0)
        book.items.append(Commitment(text: "Call back", to: "Mike Reed", callID: nil, callTitle: nil, madeAt: t0, due: nil))
        try book.save(to: paths.commitments)
        try Data(#"{"people":{"Sam Carter":{},"Speaker B":{},"Sam":{},"Michael Reid":{}},"focus":"x"}"#.utf8).write(to: paths.coach.appendingPathComponent("profile.json"))
        var org = OrgMatches()
        org.set("Sam Carter", to: "carter, sam")
        org.setOutside("Nobody Here")
        try org.save(paths: paths)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: paths.root)
        try? FileManager.default.removeItem(at: out)
    }

    private func plan() -> PeopleMigration.Plan {
        PeopleMigration.plan(PeopleMigration.read(paths: paths, ownerName: "Avery Webb", notDuplicates: notDuplicates, now: now))
    }

    private func run(_ mode: String, out: URL? = nil, at date: Date? = nil) -> (text: String, status: Int32) {
        PeopleMigration.command(["Mossad", "--people-migration", mode] + (out.map { ["--out", $0.path] } ?? []), paths: paths, ownerName: "Avery Webb",
                                notDuplicates: notDuplicates, now: date ?? now)
    }

    /// Each file under the data folder with its bytes. The lock file of a running command is not data.
    private func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let all = FileManager.default.enumerator(at: paths.root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = all?.nextObject() as? URL {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true, url.lastPathComponent != ".lock" else { continue }
            let root = paths.root.resolvingSymlinksInPath().path
            files[url.resolvingSymlinksInPath().path.replacingOccurrences(of: root, with: "")] = try Data(contentsOf: url)
        }
        return files
    }

    private func person(_ name: String, in plan: PeopleMigration.Plan) -> Person? { plan.people.first { $0.displayName == name } }

    // MARK: The plan

    func testOnePersonForEachProfileWithTheEmailVerifiedAndOneOwner() throws {
        let plan = plan()
        XCTAssertEqual(plan.report.errors, [])
        XCTAssertEqual(Set(plan.people.map(\.displayName)), ["Avery Webb", "Sam Carter", "Dana Lee", "Michael Reed", "Riley Chen", "riley chen"])
        XCTAssertEqual(plan.report.totals.people, 6)
        XCTAssertEqual(plan.report.totals.newPeople, 6)
        XCTAssertEqual(plan.report.totals.owners, 1)
        XCTAssertEqual(plan.report.totals.verifiedEmails, 3)
        XCTAssertEqual(person("Avery Webb", in: plan)?.isOwner, true)
        let sam = try XCTUnwrap(person("Sam Carter", in: plan))
        XCTAssertEqual(sam.emails.first, EmailIdentity(address: "sam.carter@example.com", state: .verified, source: .owner, at: now))
        XCTAssertEqual(sam.name, PersonName(given: "sam", family: "carter"))
        XCTAssertEqual(sam.origin, .migration)
        XCTAssertEqual(Set(plan.people.map(\.id)).count, 6)
        XCTAssertTrue(plan.changes)
    }

    func testANameWrittenLastNameFirstIsALinkAndBecomesAFormOfThePerson() throws {
        let plan = plan()
        XCTAssertEqual(plan.report.newLinks, [
            .init(written: "Lee, Dana", person: "Dana Lee", rule: "last name first", meetings: 1),
            .init(written: "Carter, Sam", person: "Sam Carter", rule: "last name first", meetings: 2),
        ])
        let sam = try XCTUnwrap(person("Sam Carter", in: plan))
        XCTAssertEqual(sam.forms.map { "\($0.text):\($0.kind.rawValue):\($0.source.rawValue)" }, ["Sam Carter:display:migration", "Carter, Sam:seen:calendar"])
        XCTAssertFalse(sam.forms[1].confirmed)
        XCTAssertEqual(sam.emails.map { "\($0.address):\($0.state.rawValue)" }, ["sam.carter@example.com:verified", "s.carter@example.org:seen"],
                       "the pair of the invite gave the second address next to the name")
        XCTAssertEqual(plan.report.totals.invitedNames, 4)
        XCTAssertEqual(plan.report.totals.invitedNamesResolved, 2)
        XCTAssertEqual(plan.report.totals.invitedEmails, 3)
        XCTAssertEqual(plan.report.totals.invitedEmailsResolved, 2)
    }

    func testTwoPeopleWithOneNameGetNoLinkAndARowInTheReport() {
        let plan = plan()
        let row = plan.report.notResolved.first { $0.label == "Chen, Riley" }
        XCTAssertEqual(row?.kind, "invited name")
        XCTAssertEqual(row?.meetings, ["20261105-100000"])
        XCTAssertEqual(row?.why, "2 saved people fit: " + plan.people.filter { $0.name.family == "chen" }.sorted { $0.id < $1.id }.map(\.displayName).joined(separator: ", "))
        XCTAssertFalse(plan.people.contains { $0.forms.contains { $0.text == "Chen, Riley" } }, "an ambiguous name is never guessed")
        XCTAssertEqual(plan.report.notResolved.first { $0.label.hasPrefix("Quinn") }?.why, "no saved person fits")
    }

    func testSpeakersActionItemsAndCommitmentsResolveInsideTheirCall() {
        let plan = plan(), t = plan.report.totals
        XCTAssertEqual([t.speakerNames, t.speakerNamesResolved], [3, 2])
        XCTAssertEqual(plan.report.notResolved.first { $0.kind == "speaker" }?.label, "Pat Moreno")
        XCTAssertEqual([t.actionItems, t.actionItemsWithNoOwner, t.actionItemOwners, t.actionItemOwnersExact, t.actionItemOwnersByShortForm], [4, 1, 3, 1, 1])
        XCTAssertEqual(plan.report.notResolved.first { $0.kind == "action item owner" }?.label, "Jordan")
        XCTAssertEqual([t.commitmentNames, t.commitmentNamesResolved], [3, 2])
        let loose = plan.report.notResolved.first { $0.kind == "commitment" }
        XCTAssertEqual(loose?.label, "Mike Reed")
        XCTAssertEqual(loose?.meetings, ["added by hand"])
        XCTAssertEqual(loose?.why, "probably Michael Reed (a short first name); not sure enough for a link")
    }

    func testCoachNotesWithNoPersonAreOrphansWithAReason() {
        let plan = plan()
        XCTAssertEqual([plan.report.totals.coachNotes, plan.report.totals.coachNotesResolved], [4, 1])
        XCTAssertEqual(plan.report.orphans, [
            .init(key: "Michael Reid", why: "probably Michael Reed (a name that is almost the same); not sure enough for a link; no call uses this name"),
            .init(key: "Sam", why: "one word; no saved person fits; no call uses this name"),
            .init(key: "Speaker B", why: "a speaker label, not a name; no call uses this name"),
        ])
    }

    func testOrgMatchesAndThePairsTheOwnerCalledTwoPeople() throws {
        let plan = plan()
        XCTAssertEqual([plan.report.totals.orgMatches, plan.report.totals.orgMatchesResolved], [2, 1])
        XCTAssertEqual(plan.report.notResolved.first { $0.kind == "org match" }?.label, "nobody here")
        let sam = try XCTUnwrap(person("Sam Carter", in: plan)), dana = try XCTUnwrap(person("Dana Lee", in: plan))
        XCTAssertEqual(sam.distinctFrom, [dana.id])
        XCTAssertEqual(dana.distinctFrom, [sam.id])
        XCTAssertEqual(plan.report.totals.distinctPairs, 1)
        XCTAssertEqual(plan.report.notResolved.first { $0.kind == "not duplicates" }?.label, "Gone Person and Sam Carter")
    }

    func testASampleGetsItsCallFromTheRecordThatHasTheSameFingerprintForTheSamePerson() throws {
        let plan = plan()
        XCTAssertEqual([plan.report.totals.samples, plan.report.totals.samplesWithProvenance], [6, 3])
        let sam = try XCTUnwrap(person("Sam Carter", in: plan))
        let mine = plan.samples.filter { $0.personID == sam.id }
        XCTAssertEqual(mine.map(\.callID), ["20261105-100000", "20261106-100000", nil])
        XCTAssertEqual(mine.map(\.speakerKey), ["them:A", "them:A", nil])
        XCTAssertEqual(mine.map(\.track), ["them", "them", nil])
        XCTAssertEqual(mine.map(\.recorded), [t0, t0.addingTimeInterval(86_400), nil])
        XCTAssertEqual(mine.map(\.seconds), [12, 33, nil], "from the lines of the call, or as the call kept it")
        XCTAssertEqual(mine.map(\.quality), [nil, 0.7, nil])
        XCTAssertEqual(mine.map(\.origin), [.migrated, .migrated, .migrated])
        XCTAssertEqual(mine[0].vector, VoiceSample.key(of: sam1))
        XCTAssertEqual(plan.report.samplesWithoutProvenance, [
            .init(person: "Sam Carter", count: 1, why: "no call record has this fingerprint"),
            .init(person: "Dana Lee", count: 1, why: "the call 20261106-100000 has this voice under the name \"Pat Moreno\""),
            .init(person: "Riley Chen", count: 1, why: "no call record has this fingerprint"),
        ])
    }

    func testThePlanHoldsNoFingerprint() throws {
        let text = String(decoding: try JSONEncoder.callRecord.encode(plan()), as: UTF8.self)
        XCTAssertFalse(text.contains(VoiceSample.base64(sam1)))
        XCTAssertFalse(text.contains("embeddings"))
        XCTAssertFalse(PeopleMigration.markdown(plan()).contains(VoiceSample.key(of: sam1)))
    }

    func testTheReportHasItsFiveParts() {
        let text = PeopleMigration.markdown(plan())
        for part in ["## Totals", "## New links", "## Not resolved", "## Orphans", "## Samples with no provenance"] { XCTAssertTrue(text.contains(part), part) }
        XCTAssertTrue(text.contains("- Carter, Sam → Sam Carter, last name first, 2 meetings"))
        XCTAssertTrue(text.contains("- Invited names: 2 of 4 resolve (2 new links)"))
        XCTAssertTrue(text.contains("- Voice samples: 6, 3 with their call, 3 without"))
        XCTAssertFalse(text.contains("## Errors"))
    }

    func testAFileThatCannotBeReadIsAnErrorAndNothingIsApplied() throws {
        try Data("nope".utf8).write(to: paths.voices.appendingPathComponent("voices.json"))
        let before = try snapshot()
        let result = run("apply")
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.text.contains("ERRORS: voices.json cannot be read"), result.text)
        XCTAssertEqual(try snapshot(), before, "the damaged file is not moved, and no new file is made")
    }

    // MARK: Dry run, apply, revert

    func testADryRunChangesNothingInTheDataFolder() throws {
        let before = try snapshot()
        let result = run("dry-run", out: out)
        XCTAssertEqual(result.status, 0, result.text)
        XCTAssertEqual(try snapshot(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(".lock").path), "a dry run takes no lock")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: out.path)), [PeopleMigration.planName, PeopleMigration.reportName])
        XCTAssertTrue(result.text.contains("People: 6 (6 new), 1 owner, 3 verified emails"), result.text)
        XCTAssertTrue(result.text.contains("Nothing was changed."))
    }

    func testADryRunWithNoOtherFolderWritesOnlyThePlanAndTheReport() throws {
        let before = try snapshot()
        XCTAssertEqual(run("dry-run").status, 0)
        let added = Set(try snapshot().keys).subtracting(before.keys)
        XCTAssertEqual(added, ["/People/" + PeopleMigration.planName, "/People/" + PeopleMigration.reportName])
    }

    func testApplyDoesWhatTheDryRunSaid() throws {
        XCTAssertEqual(run("dry-run", out: out).status, 0)
        let planned = try JSONDecoder.callRecord.decode(PeopleMigration.Plan.self, from: Data(contentsOf: out.appendingPathComponent(PeopleMigration.planName)))
        let before = try snapshot()
        // Later, with another clock: the plan of the dry run is the decision.
        let result = run("apply", out: out, at: now.addingTimeInterval(500))
        XCTAssertEqual(result.status, 0, result.text)
        XCTAssertTrue(result.text.contains("The plan of the dry run was applied."), result.text)
        let people = PeopleStore(directory: paths.people), samples = VoiceSampleStore(directory: paths.voices)
        XCTAssertEqual(people.people, planned.people, "the same people with the same ids")
        XCTAssertEqual(samples.samples.map(PeopleMigration.PlannedSample.init), planned.samples)
        XCTAssertEqual(samples.samples.first { $0.callID == "20261106-100000" }?.vector, sam2, "the numbers come from the voice library")
        // No old file changed.
        let after = try snapshot()
        for (file, data) in before { XCTAssertEqual(after[file], data, file) }
        XCTAssertEqual(Set(after.keys).subtracting(before.keys), ["/People/people.json", "/People/people-log.jsonl", "/People/migration-plan.json",
                                                                   "/People/migration-report.md", "/Voices/samples.json"])
    }

    func testApplyWithNoPlanOfTheSameDataMakesANewPlan() throws {
        XCTAssertEqual(run("dry-run", out: out).status, 0)
        // The voice library changed after the dry run.
        try VoiceLibrary(directory: paths.voices).add([0.5, 0.5, 0, 0], to: "Jo Park")
        let result = run("apply", out: out)
        XCTAssertEqual(result.status, 0, result.text)
        XCTAssertTrue(result.text.contains("a new plan was made and applied"), result.text)
        XCTAssertEqual(PeopleStore(directory: paths.people).people.filter(\.isLive).count, 7)
    }

    func testApplyTwoTimesChangesNothing() throws {
        XCTAssertEqual(run("apply").status, 0)
        let first = try snapshot()
        let again = plan()
        XCTAssertFalse(again.changes, "the new files already say all of it")
        XCTAssertEqual(again.report.newLinks.map(\.rule), ["last name first", "last name first"], "and the report gives the same rule on each run")
        XCTAssertEqual(run("apply", at: now.addingTimeInterval(9_000)).status, 0)
        let second = try snapshot()
        for file in ["/People/people.json", "/Voices/samples.json", "/Voices/voices.json", "/People/people-log.jsonl"] { XCTAssertEqual(second[file], first[file], file) }
    }

    func testRevertRestoresTheOldState() throws {
        let before = try snapshot()
        XCTAssertEqual(run("apply").status, 0)
        XCTAssertNotEqual(try snapshot(), before)
        let result = run("revert")
        XCTAssertEqual(result.status, 0, result.text)
        XCTAssertEqual(try snapshot(), before)
        XCTAssertEqual(run("revert").text, "There was nothing to remove.")
    }

    func testApplyAndRevertWaitWhileTheAppIsOpen() throws {
        guard case .held(let lock) = InstanceLock.acquire(root: paths.root) else { return XCTFail("no lock") }
        let before = try snapshot()
        for mode in ["apply", "revert"] {
            let result = run(mode)
            XCTAssertEqual(result.status, 1)
            XCTAssertTrue(result.text.contains("Quit Mossad first"), result.text)
        }
        XCTAssertEqual(try snapshot(), before)
        withExtendedLifetime(lock) {}
    }

    func testAnUnknownCommandSaysHowToCallIt() {
        XCTAssertEqual(run("explode").status, 2)
        XCTAssertTrue(run("explode").text.hasPrefix("Usage:"))
    }

    // MARK: At launch

    func testTheFirstLaunchAppliesAndTheVoiceLibraryThenKeepsTheStoresInStep() throws {
        let before = try snapshot()
        let library = VoiceLibrary(directory: paths.voices)
        let identity = try XCTUnwrap(PeopleMigration.runAtLaunch(paths: paths, library: library, ownerName: "Avery Webb", notDuplicates: notDuplicates, now: now))
        XCTAssertEqual(identity.people.people.filter(\.isLive).count, 6)
        XCTAssertEqual(identity.samples.samples.count, 6)
        for (file, data) in before { XCTAssertEqual(try snapshot()[file], data, file) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.people.appendingPathComponent(PeopleMigration.reportName).path))
        library.identity = identity
        try library.add([0.3, 0.3, 0.3, 0.3], to: "Dana Lee", source: VoiceSampleSource(callID: "20261107-100000", speakerKey: "them:C", origin: .ownerNamed))
        let dana = try XCTUnwrap(identity.people.id(forVoiceName: "Dana Lee"))
        XCTAssertEqual(identity.samples.samples(of: dana).map(\.callID), [nil, "20261107-100000"])
    }

    func testALaterLaunchWithNothingNewWritesNothing() throws {
        _ = PeopleMigration.runAtLaunch(paths: paths, library: VoiceLibrary(directory: paths.voices), ownerName: "Avery Webb", notDuplicates: notDuplicates, now: now)
        let first = try snapshot()
        let identity = PeopleMigration.runAtLaunch(paths: paths, library: VoiceLibrary(directory: paths.voices), ownerName: "Avery Webb", notDuplicates: notDuplicates,
                                                   now: now.addingTimeInterval(86_400))
        XCTAssertNotNil(identity)
        XCTAssertEqual(try snapshot(), first)
    }

    func testWhatAnOlderBuildDidToTheVoiceLibraryIsTakenInAtTheNextLaunch() throws {
        let first = try XCTUnwrap(PeopleMigration.runAtLaunch(paths: paths, library: VoiceLibrary(directory: paths.voices), ownerName: "Avery Webb", notDuplicates: [], now: now))
        let dana = try XCTUnwrap(first.people.id(forVoiceName: "Dana Lee")), sam = try XCTUnwrap(first.people.id(forVoiceName: "Sam Carter"))
        // An older build has no people store: it renames a profile, teaches another one, and deletes a third.
        let old = VoiceLibrary(directory: paths.voices)
        try old.rename("Dana Lee", to: "Dana Park")
        try old.add([0.6, 0, 0.6, 0], to: "Sam Carter")
        try old.delete("Riley Chen")
        let library = VoiceLibrary(directory: paths.voices)
        let second = try XCTUnwrap(PeopleMigration.runAtLaunch(paths: paths, library: library, ownerName: "Avery Webb", notDuplicates: [], now: now.addingTimeInterval(86_400)))
        XCTAssertEqual(second.people.id(forVoiceName: "Dana Park"), dana, "the same voice under a new name is the same person")
        XCTAssertEqual(second.people.person(dana)?.forms.map(\.text), ["Dana Lee", "Lee, Dana", "Dana Park"])
        XCTAssertEqual(second.samples.samples(of: sam).count, 4)
        XCTAssertEqual(second.samples.samples(of: sam).last?.origin, .migrated)
        XCTAssertEqual(second.samples.samples.count, 6, "the deleted profile's sample left; the person stays until this build deletes them")
        XCTAssertEqual(second.samples.samples.map(\.vector).sorted { $0.description < $1.description },
                       library.profiles.flatMap(\.embeddings).sorted { $0.description < $1.description }, "the samples are the fingerprints of the voice library")
    }

    func testANewerPeopleFileStopsTheLaunchStepAndTheVoiceLibraryWorksAlone() throws {
        let newer = #"{"version":99,"people":[]}"#
        try Data(newer.utf8).write(to: paths.people.appendingPathComponent(PeopleStore.fileName))
        let library = VoiceLibrary(directory: paths.voices)
        XCTAssertNil(PeopleMigration.runAtLaunch(paths: paths, library: library, ownerName: "Avery Webb", notDuplicates: [], now: now))
        XCTAssertEqual(try String(contentsOf: paths.people.appendingPathComponent(PeopleStore.fileName), encoding: .utf8), newer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.voices.appendingPathComponent(VoiceSampleStore.fileName).path))
        XCTAssertNoThrow(try library.add([0.2, 0.2, 0, 0], to: "Sam Carter"))
    }

    func testADamagedPeopleFileIsSetAsideAndMadeAgainFromTheVoiceLibrary() throws {
        try Data("nope".utf8).write(to: paths.people.appendingPathComponent(PeopleStore.fileName))
        let identity = try XCTUnwrap(PeopleMigration.runAtLaunch(paths: paths, library: VoiceLibrary(directory: paths.voices), ownerName: "Avery Webb", notDuplicates: [], now: now))
        XCTAssertEqual(identity.people.people.filter(\.isLive).count, 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.people.path).filter { $0.contains(".unreadable-") }.count, 1)
    }

    func testTheOwnerIsAPersonAlsoWithNoVoiceProfile() throws {
        try VoiceLibrary(directory: paths.voices).deleteAll()
        let plan = plan()
        XCTAssertEqual(plan.people.map(\.displayName), ["Avery Webb"])
        XCTAssertEqual(plan.people.first?.isOwner, true)
        XCTAssertEqual(plan.people.first?.origin, .owner)
        XCTAssertEqual([plan.report.totals.speakerNames, plan.report.totals.speakerNamesResolved], [3, 1], "the owner's lines are the owner's")
    }

    func testTheOwnersNameInSettingsIsTheDisplayNameAndTheProfilesNameStaysAForm() throws {
        let plan = PeopleMigration.plan(PeopleMigration.read(paths: paths, ownerName: "Avery Webb-Stone", notDuplicates: [], now: now))
        let owner = try XCTUnwrap(plan.people.first(where: \.isOwner))
        XCTAssertEqual(owner.displayName, "Avery Webb-Stone")
        XCTAssertEqual(owner.forms.map { "\($0.text):\($0.kind.rawValue)" }, ["Avery Webb:former", "Avery Webb-Stone:display"])
        XCTAssertEqual(plan.samples.filter { $0.personID == owner.id }.map(\.callID), ["20261105-100000"], "the owner's sample is found under the old name")
        XCTAssertEqual([plan.report.totals.speakerNames, plan.report.totals.speakerNamesResolved], [3, 2])
    }
}

/// An older build reads the voice library as it always did, after this build wrote to it.
final class LegacyShapeTests: XCTestCase {
    /// The voice profile as builds before the people store declare it. Do not change it with the real type.
    private struct OldVoiceProfile: Codable, Equatable {
        var name: String
        var isOwner: Bool
        var embeddings: [[Float]]
        var email: String? = nil
    }

    func testTheVoiceFileKeepsTheShapeOfBefore() throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Paths(root: root)
        try paths.ensureDirectories()
        let library = VoiceLibrary(directory: paths.voices)
        library.identity = VoiceIdentity(people: PeopleStore(directory: paths.people), samples: VoiceSampleStore(directory: paths.voices))
        try library.add([1, 0, 0, 0], to: "Avery Webb", isOwner: true, source: VoiceSampleSource(callID: "c1", speakerKey: "me:A", origin: .ownerEnrollment))
        try library.add([0, 1, 0, 0], to: "Sam Carter", source: VoiceSampleSource(callID: "c1", speakerKey: "them:A", origin: .ownerNamed))
        try library.setEmail("sam@example.com", for: "Sam Carter")
        try library.rename("Sam Carter", to: "Sam Carter-Reed")
        let data = try Data(contentsOf: paths.voices.appendingPathComponent("voices.json"))
        XCTAssertEqual(try JSONDecoder().decode([OldVoiceProfile].self, from: data), [
            OldVoiceProfile(name: "Avery Webb", isOwner: true, embeddings: [[1, 0, 0, 0]]),
            OldVoiceProfile(name: "Sam Carter-Reed", isOwner: false, embeddings: [[0, 1, 0, 0]], email: "sam@example.com"),
        ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(Set(json.flatMap(\.keys)), ["name", "isOwner", "embeddings", "email"], "no new key is in the old file")
    }

    func testARecordWithTheNewFieldsReadsInABuildThatDoesNotKnowThem() throws {
        /// The fields of a call record that an older build reads from this part of the file.
        struct OldRecord: Decodable {
            var id: String
            var attendees: [String]
            var speakerNames: [String: String]
            var speakerEmbeddings: [String: [Float]]
        }
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 1_780_000_000), end: Date(timeIntervalSince1970: 1_780_000_900), status: .written)
        r.attendees = ["Carter, Sam"]
        r.invitees = [Invitee(name: "Carter, Sam", email: "sam@example.com", isSelf: nil)]
        r.speakerNames = ["them:A": "Sam Carter"]
        r.speakerEmbeddings = ["them:A": [0, 1, 0, 0]]
        r.speakerSamples = ["them:A": SpeakerSampleDetail(seconds: 20, quality: 0.8)]
        let old = try JSONDecoder().decode(OldRecord.self, from: JSONEncoder.callRecord.encode(r))
        XCTAssertEqual(old.attendees, ["Carter, Sam"])
        XCTAssertEqual(old.speakerNames, ["them:A": "Sam Carter"])
        XCTAssertEqual(old.speakerEmbeddings, ["them:A": [0, 1, 0, 0]])
    }
}
