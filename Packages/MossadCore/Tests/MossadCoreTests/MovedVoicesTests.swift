import XCTest
@testable import MossadCore

final class MovedVoicesTests: XCTestCase {
    private let id = "20261101-100000"
    private let t0 = Date(timeIntervalSince1970: 1_793_520_000)

    /// A unit vector on one axis: the fingerprint of a voice in the record.
    private func axis(_ i: Int) -> [Float] { (0..<8).map { $0 == i ? 1 : 0 } }

    /// A saved voice whose cosine to `axis(main)` is exactly `c`: the rest of its length is on `other`.
    private func near(_ main: Int, _ c: Float, other: Int) -> [Float] {
        (0..<8).map { $0 == main ? c : $0 == other ? (1 - c * c).squareRoot() : 0 }
    }

    private func library(_ fill: (VoiceLibrary) throws -> Void = { _ in }) rethrows -> (VoiceLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MovedVoicesTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let lib = VoiceLibrary(directory: dir)
        lib.identity = VoiceIdentity(people: PeopleStore(directory: dir), samples: VoiceSampleStore(directory: dir))
        try fill(lib)
        return (lib, dir)
    }

    private func record(names: [String: String] = [:], unknown: [String] = [], prints: [String: [Float]] = [:],
                        seconds: [String: Double] = [:], invitees: [Invitee]? = nil, fromInvite: [String]? = nil) -> CallRecord {
        var r = CallRecord(id: id, platform: .zoom, bundleID: "us.zoom.xos", start: t0, end: t0 + 1800, status: .written)
        let keys = Set(names.keys).union(unknown).union(prints.keys).sorted()
        r.utterances = keys.enumerated().map { i, key in
            let parts = key.split(separator: ":")
            return Utterance(track: parts[0] == "me" ? .me : .them, speakerLabel: String(parts[1]), start: Double(i * 10),
                             end: Double(i * 10 + 8), text: "the zebra crossing is closed")
        }
        r.speakerNames = names
        r.unknownSpeakers = unknown
        r.speakerEmbeddings = prints
        r.speakerSamples = Dictionary(uniqueKeysWithValues: prints.keys.map { ($0, SpeakerSampleDetail(seconds: seconds[$0] ?? 30, quality: 0.8)) })
        r.invitees = invitees
        r.fromInvite = fromInvite
        return r
    }

    private func score(_ l: MovedVoices.Learn?) -> Float? {
        if case .autoMatch(let s)? = l { return s }
        return nil
    }

    func testAVoiceTheTargetKnowsGetsTheTargetsName() throws {
        let (lib, _) = try library { try $0.add(axis(0), to: "Samuel Carter") }
        let n = MovedVoices.decide(record(names: ["them:A": "Sam Carter"], prints: ["them:A": axis(0)]), ownerKeys: [], library: lib,
                                   ownerName: "Avery Webb")
        XCTAssertEqual(n.names["them:A"], "Samuel Carter")
        XCTAssertEqual(try XCTUnwrap(score(n.learn["them:A"])), 1, accuracy: 0.0001)
        XCTAssertEqual(n.renamed, ["Sam Carter": "Samuel Carter"])
        XCTAssertTrue(n.changed)
    }

    func testAVoiceItDoesNotKnowKeepsItsNameAndIsLearnedAsTheOwnersNaming() throws {
        let (lib, dir) = try library { try $0.add(axis(6), to: "Avery Webb", isOwner: true) }
        var r = record(names: ["me:A": "Avery Webb", "them:A": "Sam Carter"], prints: ["me:A": axis(6), "them:A": axis(0)])
        let n = MovedVoices.decide(r, ownerKeys: ["me:A"], library: lib, ownerName: "Avery Webb")
        XCTAssertEqual(n.names["them:A"], "Sam Carter")
        XCTAssertEqual(n.learn["them:A"], .ownerNamed)
        XCTAssertNil(n.renamed["Sam Carter"])
        try MovedVoices.apply(n, to: &r, callID: id + "-moved", library: lib)
        XCTAssertEqual(lib.profiles.first { $0.name == "Sam Carter" }?.embeddings, [axis(0)])
        let samples = VoiceSampleStore(directory: dir).samples.filter { $0.speakerKey == "them:A" }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.callID, id + "-moved")
        XCTAssertEqual(samples.first?.origin, .ownerNamed)
        let sam = PeopleStore(directory: dir).people.first { $0.displayName == "Sam Carter" }
        XCTAssertEqual(sam?.isLive, true)
        XCTAssertEqual(sam?.origin, .voiceNaming)
        XCTAssertTrue(lib.provisional.isEmpty)
    }

    func testAWholeSavedNameJoinsThatPersonAndAGuessJoinsNobody() throws {
        let (lib, _) = try library { try $0.add(near(0, 0.2, other: 1), to: "Sam Carter") }
        let whole = MovedVoices.decide(record(names: ["them:A": "Carter, Sam"], prints: ["them:A": axis(0)]), ownerKeys: [], library: lib,
                                       ownerName: "Avery Webb")
        XCTAssertEqual(whole.names["them:A"], "Sam Carter")
        XCTAssertEqual(whole.learn["them:A"], .ownerNamed)
        let guess = MovedVoices.decide(record(names: ["them:A": "Sam"], prints: ["them:A": axis(0)]), ownerKeys: [], library: lib,
                                       ownerName: "Avery Webb")
        XCTAssertEqual(guess.names["them:A"], "Sam")
        XCTAssertEqual(guess.learn["them:A"], .ownerNamed)
    }

    func testANameFromTheInviteStaysProvisional() throws {
        let (lib, _) = try library()
        var r = record(names: ["them:A": "Sam Carter"], prints: ["them:A": axis(0)], seconds: ["them:A": 25], fromInvite: ["them:A"])
        let n = MovedVoices.decide(r, ownerKeys: [], library: lib, ownerName: "Avery Webb")
        XCTAssertEqual(n.learn["them:A"], .inviteInference)
        try MovedVoices.apply(n, to: &r, callID: id + "-moved", library: lib)
        XCTAssertEqual(lib.provisional["Sam Carter"], id + "-moved")
        XCTAssertEqual(r.fromInvite, ["them:A"])

        let short = MovedVoices.decide(record(names: ["them:A": "Sam Carter"], prints: ["them:A": axis(0)], seconds: ["them:A": 12],
                                              fromInvite: ["them:A"]), ownerKeys: [], library: try library().0, ownerName: "Avery Webb")
        XCTAssertEqual(short.learn["them:A"], MovedVoices.Learn.none)
        XCTAssertEqual(short.names["them:A"], "Sam Carter")
    }

    func testTheOwner() throws {
        let (empty, _) = try library()
        var r = record(names: ["me:A": "Avery Webb"], prints: ["me:A": axis(6)])
        let n = MovedVoices.decide(r, ownerKeys: ["me:A"], library: empty, ownerName: "Avery Webb")
        XCTAssertEqual(n.names["me:A"], "Avery Webb")
        XCTAssertEqual(n.learn["me:A"], MovedVoices.Learn.none)
        try MovedVoices.apply(n, to: &r, callID: id, library: empty)
        XCTAssertNil(empty.owner, "the owner's voice is never made from a moved meeting")

        let (is09, _) = try library { try $0.add(near(6, 0.9, other: 7), to: "Avery Webb", isOwner: true) }
        let yes = MovedVoices.decide(record(names: ["me:A": "Avery Webb"], prints: ["me:A": axis(6)]), ownerKeys: ["me:A"], library: is09,
                                     ownerName: "Avery Webb")
        XCTAssertEqual(try XCTUnwrap(score(yes.learn["me:A"])), 0.9, accuracy: 0.0001)
        let (is01, _) = try library { try $0.add(near(6, 0.1, other: 7), to: "Avery Webb", isOwner: true) }
        let no = MovedVoices.decide(record(names: ["me:A": "Avery Webb"], prints: ["me:A": axis(6)]), ownerKeys: ["me:A"], library: is01,
                                    ownerName: "Avery Webb")
        XCTAssertEqual(no.names["me:A"], "Avery Webb")
        XCTAssertEqual(no.learn["me:A"], MovedVoices.Learn.none)

        let other = MovedVoices.decide(record(names: ["me:A": "A. Webb", "them:C": "Avery Webb"], prints: ["me:A": axis(6), "them:C": axis(3)]),
                                       ownerKeys: ["me:A"], library: empty, ownerName: "Avery Webb")
        XCTAssertEqual(other.renamed["A. Webb"], "Avery Webb")
        XCTAssertNil(other.names["them:C"], "the owner's name on a voice that is not the owner's is no name")
        XCTAssertTrue(other.unknown.contains("them:C"))
    }

    func testTwoVoicesWithOneName() throws {
        let (lib, _) = try library()
        let both = MovedVoices.decide(record(names: ["them:A": "Sam Carter", "them:C": "Sam Carter"], prints: ["them:A": axis(0), "them:C": axis(3)],
                                             seconds: ["them:A": 30, "them:C": 12]), ownerKeys: [], library: lib, ownerName: "Avery Webb")
        XCTAssertEqual(both.names["them:A"], "Sam Carter")
        XCTAssertEqual(both.names["them:C"], "Sam Carter")
        XCTAssertEqual(both.learn["them:A"], .ownerNamed)
        XCTAssertEqual(both.learn["them:C"], MovedVoices.Learn.none)

        let (knows, _) = try library { try $0.add(near(0, 0.9, other: 1), to: "Sam Carter") }
        let one = MovedVoices.decide(record(names: ["them:C": "Sam Carter"], prints: ["them:A": axis(0), "them:C": axis(3)]), ownerKeys: [],
                                     library: knows, ownerName: "Avery Webb")
        XCTAssertEqual(one.names["them:A"], "Sam Carter")
        XCTAssertEqual(one.names["them:C"], "Sam Carter")
        XCTAssertEqual(one.learn["them:C"], MovedVoices.Learn.none, "the library gave that name to another voice of the meeting")
    }

    func testANameThatIsAnAddress() throws {
        let (lib, _) = try library {
            try $0.add(near(0, 0.2, other: 1), to: "Sam Carter")
            _ = try $0.setEmail("sam@example.com", for: "Sam Carter")
        }
        let known = MovedVoices.decide(record(names: ["them:A": "sam@example.com"], prints: ["them:A": axis(0)]), ownerKeys: [], library: lib,
                                       ownerName: "Avery Webb")
        XCTAssertEqual(known.names["them:A"], "Sam Carter")

        let (empty, dir) = try library()
        var r = record(names: ["them:A": "lee@example.com"], prints: ["them:A": axis(0)])
        let n = MovedVoices.decide(r, ownerKeys: [], library: empty, ownerName: "Avery Webb")
        XCTAssertNil(n.names["them:A"])
        try MovedVoices.apply(n, to: &r, callID: id, library: empty)
        XCTAssertTrue(empty.profiles.isEmpty, "no voice")
        XCTAssertFalse(PeopleStore(directory: dir).people.contains { $0.displayName.contains("@") }, "no person named by an address")
        XCTAssertNil(r.speakerNames["them:A"])
    }

    func testAVoiceWithNoNameStaysALetter() throws {
        let (lib, _) = try library { try $0.add(near(0, 0.2, other: 1), to: "Sam Carter") }
        let r = record(unknown: ["them:B"], prints: ["them:B": axis(0), "them:D": axis(4)])
        let n = MovedVoices.decide(r, ownerKeys: [], library: lib, ownerName: "Avery Webb")
        XCTAssertNil(n.names["them:B"])
        XCTAssertEqual(n.unknown, ["them:B"])
        XCTAssertNil(n.names["them:D"], "a skipped voice stays skipped")
        XCTAssertFalse(n.unknown.contains("them:D"))
        XCTAssertTrue(n.renamed.isEmpty)
    }

    func testTheThresholdsOfIdentify() throws {
        let lee = [Invitee(name: "Lee Park", email: "lee@example.com")]
        func uninvited(_ s: Float, next: Float) throws -> MovedVoices.Naming {
            let (lib, _) = try library {
                try $0.add(near(0, s, other: 1), to: "Sam Carter")
                try $0.add(near(0, next, other: 2), to: "Robin Vale")
            }
            return MovedVoices.decide(record(prints: ["them:A": axis(0)], invitees: lee), ownerKeys: [], library: lib, ownerName: "Avery Webb")
        }
        XCTAssertNil(try uninvited(0.79, next: 0.1).names["them:A"])
        XCTAssertNil(try uninvited(0.85, next: 0.80).names["them:A"])
        let lead = try uninvited(0.85, next: 0.70)
        XCTAssertEqual(lead.names["them:A"], "Sam Carter")
        XCTAssertEqual(lead.learn["them:A"], MovedVoices.Learn.none)

        let sam = [Invitee(name: "Sam Carter", email: "sam@example.com")]
        func invited(_ s: Float) throws -> MovedVoices.Naming {
            let (lib, _) = try library {
                try $0.add(near(0, s, other: 1), to: "Sam Carter")
                _ = try $0.setEmail("sam@example.com", for: "Sam Carter")
            }
            return MovedVoices.decide(record(prints: ["them:A": axis(0)], invitees: sam), ownerKeys: [], library: lib, ownerName: "Avery Webb")
        }
        let low = try invited(0.66)
        XCTAssertEqual(low.names["them:A"], "Sam Carter")
        XCTAssertEqual(low.learn["them:A"], MovedVoices.Learn.none)
        XCTAssertEqual(try XCTUnwrap(score(try invited(0.81).learn["them:A"])), 0.81, accuracy: 0.0001)
        XCTAssertNil(try invited(0.64).names["them:A"])

        let (prov, _) = try library {
            try $0.add(axis(0), to: "Mira Stone", source: VoiceSampleSource(callID: "20261020-090000", speakerKey: "them:A", recorded: t0,
                                                                            seconds: 30, quality: 0.8, origin: .inviteInference))
        }
        XCTAssertEqual(prov.provisional["Mira Stone"], "20261020-090000")
        XCTAssertNil(MovedVoices.decide(record(prints: ["them:A": axis(0)], invitees: lee), ownerKeys: [], library: prov,
                                        ownerName: "Avery Webb").names["them:A"], "a provisional voice names nobody outside its invite")
    }

    func testNoLineOfTheTranscriptChanges() throws {
        let (lib, _) = try library { try $0.add(axis(0), to: "Samuel Carter") }
        var r = record(names: ["them:A": "Sam Carter"], unknown: ["them:B"], prints: ["them:A": axis(0), "them:B": axis(4)])
        r.meUtterances = [r.utterances[0]]
        r.themUtterances = Array(r.utterances.dropFirst())
        r.markers = [TranscriptMarker(offset: 12, text: "★", isBookmark: true, note: "Sam Carter")]
        let before = r
        try MovedVoices.apply(MovedVoices.decide(r, ownerKeys: [], library: lib, ownerName: "Avery Webb"), to: &r, callID: id, library: lib)
        XCTAssertEqual(r.utterances, before.utterances)
        XCTAssertEqual(r.meUtterances, before.meUtterances)
        XCTAssertEqual(r.themUtterances, before.themUtterances)
        XCTAssertEqual(r.markers, before.markers)
    }

    func testAChangedNameChangesTheWordsOfTheSummary() throws {
        let (lib, _) = try library {
            try $0.add(axis(0), to: "Samuel Carter")
            try $0.add(axis(4), to: "Mira Stone")
        }
        var r = record(names: ["them:A": "Sam Carter"], unknown: ["them:B"], prints: ["them:A": axis(0), "them:B": axis(4)])
        // The first voice with no name shows as "Speaker A".
        XCTAssertEqual(MarkdownWriter.displayNames(r)["them:B"], "Speaker A")
        r.summary = "Sam Carter and Speaker A agreed."
        r.actionItems = [ActionItem(owner: "Speaker A", task: "Ask Sam Carter")]
        let n = MovedVoices.decide(r, ownerKeys: [], library: lib, ownerName: "Avery Webb")
        XCTAssertTrue(n.changed)
        try MovedVoices.apply(n, to: &r, callID: id, library: lib)
        XCTAssertEqual(r.summary, "Samuel Carter and Mira Stone agreed.")
        XCTAssertEqual(r.actionItems.first?.owner, "Mira Stone")
        XCTAssertEqual(r.actionItems.first?.task, "Ask Samuel Carter")
        XCTAssertEqual(r.speakerNames["them:B"], "Mira Stone")
        XCTAssertFalse(r.unknownSpeakers.contains("them:B"))

        let (empty, _) = try library()
        var same = record(names: ["them:A": "Sam Carter"], prints: ["them:A": axis(0)])
        same.summary = "Sam Carter agreed."
        let none = MovedVoices.decide(same, ownerKeys: [], library: empty, ownerName: "Avery Webb")
        XCTAssertFalse(none.changed)
        try MovedVoices.apply(none, to: &same, callID: id, library: empty)
        XCTAssertEqual(same.summary, "Sam Carter agreed.")
    }

    func testWithFingerprintsOffNothingIsComparedOrLearned() throws {
        let (lib, _) = try library {
            try $0.add(axis(0), to: "Samuel Carter")
            try $0.add(axis(6), to: "Avery Webb", isOwner: true)
        }
        let n = MovedVoices.decide(record(names: ["me:A": "Avery Webb", "them:A": "Sam Carter"], unknown: ["them:B"],
                                          prints: ["me:A": axis(6), "them:A": axis(0), "them:B": axis(4)]),
                                   ownerKeys: ["me:A"], library: lib, ownerName: "Avery Webb", fingerprints: false)
        XCTAssertEqual(n.names, ["me:A": "Avery Webb", "them:A": "Sam Carter"])
        XCTAssertTrue(n.learn.values.allSatisfy { $0 == .none })
        XCTAssertEqual(n.unknown, ["them:B"])
    }
}
