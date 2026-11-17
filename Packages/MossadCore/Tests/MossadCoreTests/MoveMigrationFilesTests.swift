import XCTest
@testable import MossadCore

/// The two files of the people migration (`migration-plan.json`, `migration-report.md`) hold call ids, speaker keys,
/// and names. After a removal they hold nothing of the moved call or of a person the removal deleted, a revert still
/// works, and an apply of the plan brings nothing back.
final class MoveMigrationFilesTests: XCTestCase {
    private let id = "20261101-100000"
    private let other = "20261102-090000"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveMigrationFilesTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func sample(_ person: PersonID?, call: String, key: String, seed: Float) -> PeopleMigration.PlannedSample {
        PeopleMigration.PlannedSample(VoiceSample(personID: person, vector: [seed, 0.5, 0.25],
                                                  source: VoiceSampleSource(callID: call, speakerKey: key, recorded: t0, seconds: 30, quality: 0.9,
                                                                            origin: .ownerNamed),
                                                  learned: t0))
    }

    /// A plan as the migration writes it: Sam Carter only in the moved call, Jordan Lee in another one too.
    private func plan(basis: String = "made-up") -> (PeopleMigration.Plan, gone: Person, stays: Person) {
        var gone = Person(displayName: "Sam Carter", origin: .voiceNaming, at: t0)
        gone.emails = [EmailIdentity(address: "sam.carter@example.com", state: .verified, source: .voiceNaming, at: t0)]
        let stays = Person(displayName: "Jordan Lee", origin: .voiceNaming, at: t0)
        var report = MigrationReport()
        report.newLinks = [MigrationReport.Link(written: "Sam", person: "Sam Carter", rule: "first name", meetings: 1),
                           MigrationReport.Link(written: "Jordan", person: "Jordan Lee", rule: "first name", meetings: 2)]
        report.notResolved = [MigrationReport.Unresolved(kind: "speaker", label: "Riley", meetings: [id], why: "no saved person"),
                              MigrationReport.Unresolved(kind: "commitment", label: "Taylor", meetings: [id, other], why: "two fit"),
                              MigrationReport.Unresolved(kind: "invited email", label: "sam.carter@example.com", meetings: [other], why: "no voice")]
        report.orphans = [MigrationReport.Orphan(key: "Sam Carter", why: "no saved person")]
        report.samplesWithoutProvenance = [MigrationReport.LooseSample(person: "Sam Carter", count: 1, why: "no call")]
        var refs = MigrationReport.References()
        refs.labels = ["Sam → Sam Carter (\(id))", "Jordan → Jordan Lee (\(other))"]
        refs.refused = [id, other]
        report.references = refs
        report.notes = ["Meeting \(id) has two voices named alike", "Every other meeting reads"]
        let p = PeopleMigration.Plan(made: t0, basis: basis, changes: true, people: [gone, stays],
                                     samples: [sample(gone.id, call: id, key: "B", seed: 0.1), sample(stays.id, call: id, key: "C", seed: 0.2),
                                               sample(stays.id, call: other, key: "A", seed: 0.3)],
                                     report: report)
        return (p, gone, stays)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testAfterARemovalTheFilesHoldNoIDOfTheCallAndNoNameOfARemovedPerson() throws {
        let a = temp()
        let (p, gone, stays) = plan()
        try PeopleMigration.write(p, to: a.people)
        try PeopleMigration.forget(callID: id, people: [gone.id.rawValue], paths: a)
        let planText = try text(a.people.appendingPathComponent(PeopleMigration.planName))
        let report = try text(a.people.appendingPathComponent(PeopleMigration.reportName))
        for t in [planText, report] {
            XCTAssertFalse(t.contains(id), "no id of the moved call")
            XCTAssertFalse(t.contains("Sam Carter"), "no name of a removed person")
            XCTAssertFalse(t.contains("sam.carter@example.com"), "no address of a removed person")
            XCTAssertFalse(t.contains(gone.id.rawValue), "no id of a removed person")
            XCTAssertFalse(t.contains("Riley"), "a label only of the moved call")
        }
        XCTAssertTrue(planText.contains(other) && planText.contains("Jordan Lee") && planText.contains("Taylor"), "the rest stays")
        let read = try JSONDecoder.callRecord.decode(PeopleMigration.Plan.self, from: Data(contentsOf: a.people.appendingPathComponent(PeopleMigration.planName)))
        XCTAssertEqual(read.people.map(\.id), [stays.id])
        XCTAssertEqual(read.samples.map(\.callID), [other])
        XCTAssertEqual(read.report.notResolved.first { $0.label == "Taylor" }?.meetings, [other])
        XCTAssertEqual(read.report.references?.refused, [other])
        XCTAssertEqual(report, PeopleMigration.markdown(read), "the report is the plan's own")
        // Again: nothing to change.
        let before = try Data(contentsOf: a.people.appendingPathComponent(PeopleMigration.planName))
        try PeopleMigration.forget(callID: id, people: [gone.id.rawValue], paths: a)
        XCTAssertEqual(try Data(contentsOf: a.people.appendingPathComponent(PeopleMigration.planName)), before)
    }

    func testARevertAfterTheRemovalNeitherFailsNorRestoresThem() throws {
        let a = temp()
        try FileManager.default.createDirectory(at: a.root, withIntermediateDirectories: true)
        // The plan has the basis of the data as it is, so an apply takes the plan itself.
        let basis = PeopleMigration.read(paths: a, ownerName: "Avery Webb", notDuplicates: [], now: t0).basis
        let (p, gone, _) = plan(basis: basis)
        try PeopleMigration.write(p, to: a.people)
        try PeopleMigration.forget(callID: id, people: [gone.id.rawValue], paths: a)
        let revert = PeopleMigration.command(["Mossad", "--people-migration", "revert"], paths: a, ownerName: "Avery Webb", notDuplicates: [], now: t0)
        XCTAssertEqual(revert.status, 0, revert.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.people.appendingPathComponent(PeopleMigration.planName).path))
        // A plan kept aside by the owner and applied again brings back neither the call nor the person.
        try PeopleMigration.write(p, to: a.people)
        try PeopleMigration.forget(callID: id, people: [gone.id.rawValue], paths: a)
        let apply = PeopleMigration.command(["Mossad", "--people-migration", "apply"], paths: a, ownerName: "Avery Webb", notDuplicates: [], now: t0)
        XCTAssertEqual(apply.status, 0, apply.text)
        XCTAssertTrue(apply.text.contains("The plan of the dry run was applied."), apply.text)
        let people = try text(a.people.appendingPathComponent(PeopleStore.fileName))
        XCTAssertFalse(people.contains("Sam Carter"))
        XCTAssertFalse(people.contains(gone.id.rawValue))
        let samples = (try? text(a.voices.appendingPathComponent(VoiceSampleStore.fileName))) ?? ""
        XCTAssertFalse(samples.contains(id))
    }

    func testWithNoMoveTheFilesAreAsTheMigrationWritesThem() throws {
        let a = temp()
        let (p, _, _) = plan()
        try PeopleMigration.write(p, to: a.people)
        let planBefore = try Data(contentsOf: a.people.appendingPathComponent(PeopleMigration.planName))
        let reportBefore = try Data(contentsOf: a.people.appendingPathComponent(PeopleMigration.reportName))
        // A call that is not in the files, and nobody removed: nothing is written.
        try PeopleMigration.forget(callID: "20260101-080000", people: [], paths: a)
        XCTAssertEqual(try Data(contentsOf: a.people.appendingPathComponent(PeopleMigration.planName)), planBefore)
        XCTAssertEqual(try Data(contentsOf: a.people.appendingPathComponent(PeopleMigration.reportName)), reportBefore)
        XCTAssertEqual(PeopleMigration.forgetting(p, callID: "20260101-080000", people: []), p)
        // No files: none is made.
        let b = temp()
        try PeopleMigration.forget(callID: id, people: [], paths: b)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.people.path))
    }

    func testTheRemovalsPeopleStepRewritesTheFiles() async throws {
        let a = temp()
        _ = try writtenCall(in: a)
        let (p, _, _) = plan()
        try PeopleMigration.write(p, to: a.people)
        let lib = VoiceLibrary(directory: a.voices)
        lib.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: a.voices))
        var out = MoveOut(callID: id, to: "1a2b3c4d", started: t0)
        out.people = []
        let actions = MoveRemoval.Actions(forgetPersona: { _ in }, coach: { _ in }, stopShares: { _ in }, backup: { _ in true },
                                          removeFolder: { _, _ in true })
        let done = try await MoveRemoval.run(.people, out: out, paths: a, library: lib, ownerName: "Avery Webb", actions: actions, now: t0)
        XCTAssertTrue(done)
        XCTAssertFalse(try text(a.people.appendingPathComponent(PeopleMigration.planName)).contains(id))
        XCTAssertFalse(try text(a.people.appendingPathComponent(PeopleMigration.reportName)).contains(id))
    }
}
