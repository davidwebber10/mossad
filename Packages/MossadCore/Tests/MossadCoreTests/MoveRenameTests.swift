import XCTest
@testable import MossadCore

/// Review I3: a rename (or a merge) of a person while a move waits leaves no sample of the call and no person whom only
/// the call made in the first profile: the removal forgets by the samples' own call id.
final class MoveRenameTests: XCTestCase {
    private let id = "20261101-100000"
    private let work = "1a2b3c4d"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func temp() -> Paths {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MoveRenameTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return Paths(root: url)
    }

    private func library(_ a: Paths) -> VoiceLibrary {
        let l = VoiceLibrary(directory: a.voices)
        l.identity = VoiceIdentity(people: PeopleStore(directory: a.people), samples: VoiceSampleStore(directory: a.voices))
        return l
    }

    private func actions(_ a: Paths) -> MoveRemoval.Actions {
        MoveRemoval.Actions(forgetPersona: { _ in }, coach: { change in
            var p = (try? CoachProfile.load(from: a.coach)) ?? CoachProfile()
            change(&p)
            try p.save(to: a.coach)
        }, stopShares: { _ in }, backup: { _ in true }, removeFolder: { id, _ in MoveRemoval.removeFolder(id, paths: a) })
    }

    private func run(_ rename: (VoiceLibrary) throws -> Void) async throws -> (VoiceLibrary, Paths) {
        let a = temp()
        let r = try writtenCall(in: a)
        let lib = library(a)
        // The owner names the voice: the person is made by this call alone.
        try lib.add(r.speakerEmbeddings["them:A"]!, to: "Sam Carter",
                    source: VoiceSampleSource(callID: id, speakerKey: "them:A", recorded: r.start, seconds: 30, quality: 0.8, origin: .ownerNamed))
        // The move starts and waits for the target; meanwhile the person gets a new name here. The marked record keeps
        // the old label.
        var out = MoveOut(callID: id, to: work, started: t0)
        try out.save(a)
        try rename(lib)
        out.state = .removing
        try await MoveRemoval.advance(&out, paths: a, library: lib, ownerName: "Avery Webb", actions: actions(a), now: t0)
        XCTAssertNil(out.nextStep)
        return (library(a), a)
    }

    private func assertNothingOfTheCallIsLeft(_ lib: VoiceLibrary, _ a: Paths, file: StaticString = #filePath, line: UInt = #line) {
        let samples = VoiceSampleStore(directory: a.voices).samples
        XCTAssertFalse(samples.contains { $0.callID == id }, "a sample of the call stayed", file: file, line: line)
        let people = PeopleStore(directory: a.people).people.filter(\.isLive)
        XCTAssertFalse(people.contains { $0.displayName.hasPrefix("Sam") }, "\(people.map(\.displayName))", file: file, line: line)
        XCTAssertFalse(lib.profiles.contains { $0.name.hasPrefix("Sam") && !$0.embeddings.isEmpty }, "\(lib.profiles.map(\.name))", file: file, line: line)
    }

    func testARenameDuringTheWait() async throws {
        let (lib, a) = try await run { try $0.rename("Sam Carter", to: "Sam Rivers") }
        assertNothingOfTheCallIsLeft(lib, a)
    }

    func testWithNoRenameAsBefore() async throws {
        let (lib, a) = try await run { _ in }
        assertNothingOfTheCallIsLeft(lib, a)
    }

    /// A person who also has a sample of another call stays, with that sample; only the call's own sample goes.
    func testAPersonWithAnotherCallStays() async throws {
        let (lib, a) = try await run { lib in
            try lib.add([0.9, 0.1, 0, 0, 0, 0, 0, 0], to: "Sam Carter",
                        source: VoiceSampleSource(callID: "20261020-100000", speakerKey: "them:A", recorded: self.t0, seconds: 30, quality: 0.8, origin: .ownerNamed))
            try lib.rename("Sam Carter", to: "Sam Rivers")
        }
        let samples = VoiceSampleStore(directory: a.voices).samples
        XCTAssertFalse(samples.contains { $0.callID == id })
        XCTAssertTrue(samples.contains { $0.callID == "20261020-100000" })
        XCTAssertEqual(lib.profiles.first { $0.name == "Sam Rivers" }?.embeddings, [[0.9, 0.1, 0, 0, 0, 0, 0, 0]])
        XCTAssertTrue(PeopleStore(directory: a.people).people.contains { $0.isLive && $0.displayName == "Sam Rivers" })
    }
}
