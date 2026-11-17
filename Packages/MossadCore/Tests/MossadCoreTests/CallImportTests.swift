import XCTest
@testable import MossadCore

final class CallImportTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var now: Date { t0 + 10_000 }

    private func file(_ length: TimeInterval? = 600, bytes: Int64 = 2_400_000, type: String? = "com.apple.m4a-audio") -> CallImport.File {
        CallImport.File(name: "Call.m4a", typeIdentifier: type, bytes: bytes, length: length, metadataDate: nil, fileDate: nil)
    }

    private func draft(_ f: CallImport.File, title: String = "", start: Date? = nil, person: CallImport.Choice? = nil) -> CallImport.Draft {
        CallImport.Draft(file: f, title: title, start: start ?? t0, person: person)
    }

    private func plan(_ d: CallImport.Draft, hash: String? = "h1", outbox: [CallImport.Known] = [], meetings: [CallImport.Known] = [],
                      memory: ImportMemory = .init()) -> Result<CallImport.Plan, CallImport.Refusal> {
        CallImport.plan(d, hash: hash, outbox: outbox, meetings: meetings, memory: memory, now: now)
    }

    private func start(metadata: Date?, file: Date?, metadataIs: CallImport.DateMeaning = .start,
                       fileIs: CallImport.DateMeaning = .start) -> CallImport.Start {
        CallImport.start(metadata: metadata, file: file, length: 600, now: now, metadataIs: metadataIs, fileIs: fileIs)
    }

    func testTheTitleIsTheFileNameUnlessItSaysNothing() {
        for (name, title) in [("Call with Sam Carter.m4a", "Call with Sam Carter"), ("Recording.m4a", ""), ("audio.M4A", ""),
                              ("New Recording.m4a", ""), ("New Recording 12.m4a", ""), ("20261116 101500.m4a", ""),
                              ("+1 (555) 010-0199.m4a", ""), ("Budget v2.m4a", "Budget v2"), ("Sam.Carter.call.wav", "Sam.Carter.call"),
                              ("  Renewal terms .m4a", "Renewal terms"), ("", "")] {
            XCTAssertEqual(CallImport.title(fileName: name), title, name)
        }
        XCTAssertEqual(CallImport.placeholder, "Phone call")
    }

    // now = t0 + 10_000, length 600 in each start test
    func testTheStartIsTheMetadataDateThenTheFileDate() {
        XCTAssertEqual(start(metadata: t0 + 0.7, file: t0 + 50, metadataIs: .start), .init(date: t0, sure: true))
        XCTAssertEqual(start(metadata: t0 + 600, file: nil, metadataIs: .end), .init(date: t0, sure: true))
        XCTAssertEqual(start(metadata: nil, file: t0, fileIs: .start), .init(date: t0, sure: true))
        XCTAssertEqual(start(metadata: nil, file: t0 + 900, fileIs: .share), .init(date: t0 + 300, sure: false))
        XCTAssertEqual(start(metadata: nil, file: nil), .init(date: now - 600, sure: false))
    }

    func testTheDefaultMeaningsAreTheMetadataAsTheStartAndTheFileAsTheShare() {
        XCTAssertEqual(CallImport.start(metadata: t0, file: now - 30, length: 600, now: now), .init(date: t0, sure: true))
        XCTAssertEqual(CallImport.start(metadata: nil, file: now - 30, length: 600, now: now), .init(date: now - 630, sure: false))
    }

    func testAFileDateThatCannotBeTheStartIsReadAsTheShareTime() {
        XCTAssertEqual(start(metadata: nil, file: now - 5, fileIs: .start), .init(date: now - 605, sure: false))
    }

    func testAMetadataDateOfTheLastTwoMinutesIsReadAsTheShareTime() {
        let short = CallImport.start(metadata: now - 20, file: nil, length: 30, now: now)
        XCTAssertNotEqual(short.date, now - 20)
        XCTAssertEqual(short, .init(date: now - 50, sure: false))
        // A date whose end is before now, still of the last two minutes: a copy made at the share.
        XCTAssertEqual(CallImport.start(metadata: now - 100, file: nil, length: 30, now: now), .init(date: now - 130, sure: false))
        XCTAssertEqual(CallImport.start(metadata: now - 121, file: nil, length: 30, now: now), .init(date: now - 121, sure: true))
    }

    func testAnUnreadableOrShortFileIsRefusedWithItsWords() {
        XCTAssertEqual(plan(draft(file(nil))), .failure(.unreadable))
        XCTAssertEqual(plan(draft(file(59.4))), .failure(.tooShort))
        XCTAssertNotNil(try? plan(draft(file(60))).get())
        XCTAssertEqual(CallImport.Refusal.unreadable.message, "Mossad cannot read this audio file.")
        XCTAssertEqual(CallImport.Refusal.duplicate.message, "This recording is already in Mossad.")
        XCTAssertEqual(CallImport.Refusal.tooShort.message, "This recording is shorter than a minute. Mossad does not keep a recording that short.")
    }

    func testThePlanIsARecordingOfWholeSeconds() throws {
        let sam = CallImport.Choice(name: "Sam Carter", personID: "p1")
        XCTAssertEqual(try plan(draft(file(600.4), title: "  Renewal terms ", start: t0 + 0.6, person: sam)).get(),
                       .init(id: CallID.make(t0), start: t0, end: t0 + 600, title: "Renewal terms", person: sam, convert: false))
        XCTAssertNil(try plan(draft(file(), title: "  ")).get().title)
    }

    func testARecordingWithTheSameStartAndLengthIsADuplicate() {
        let same = CallImport.Known(id: CallID.make(t0), start: t0, end: t0 + 600)
        XCTAssertEqual(plan(draft(file(), start: t0 + 0.4), outbox: [same]), .failure(.duplicate))
        XCTAssertEqual(plan(draft(file()), meetings: [.init(id: "x", start: t0, end: t0 + 600)]), .failure(.duplicate))
    }

    func testTheSameFileSharedAgainIsRefusedWhateverItsDates() {
        var memory = ImportMemory()
        memory.remember(hash: "h1", id: "20270101-090000")
        let first = CallImport.Known(id: "20270101-090000", start: t0 - 5_000, end: t0 - 4_400)
        XCTAssertEqual(plan(draft(file()), outbox: [first], memory: memory), .failure(.duplicate))
        XCTAssertEqual(plan(draft(file()), meetings: [.init(id: "20270101-090000-iphone", start: t0 - 5_000, end: t0 - 4_400)], memory: memory),
                       .failure(.duplicate))
        XCTAssertNotNil(try? plan(draft(file()), memory: memory).get(), "its recording is gone: the owner can add it again")
        XCTAssertNotNil(try? plan(draft(file()), hash: nil, outbox: [first], memory: memory).get(), "no hash, no content rule")
    }

    func testAnotherRecordingAtATakenSecondStartsOneSecondLater() throws {
        let other = CallImport.Known(id: CallID.make(t0), start: t0, end: t0 + 90)
        let p = try plan(draft(file()), outbox: [other], meetings: [.init(id: CallID.make(t0 + 1) + "-iphone", start: t0 + 1, end: t0 + 31)]).get()
        XCTAssertEqual(p.start, t0 + 2)
        XCTAssertEqual(p.id, CallID.make(t0 + 2))
        XCTAssertEqual(p.end, t0 + 602)
    }

    func testAStartWhoseEndIsAfterNowMovesBack() throws {
        XCTAssertEqual(try plan(draft(file(), start: now - 10)).get().start, now - 600)
    }

    func testAMovedStartNeverEndsAfterNow() throws {
        let taken = CallImport.Known(id: CallID.make(now - 600), start: now - 600, end: now - 500)
        let p = try plan(draft(file(), start: now - 600), outbox: [taken]).get()
        XCTAssertLessThanOrEqual(p.end, now)
        XCTAssertNotEqual(p.id, taken.id)
    }

    func testOnlyAFileThatIsNotMPEG4OrIsMuchLargerIsConverted() {
        XCTAssertFalse(CallImport.converts(typeIdentifier: "com.apple.m4a-audio", bytes: 2_400_000, length: 600))
        XCTAssertFalse(CallImport.converts(typeIdentifier: "public.mpeg-4-audio", bytes: 9_600_000, length: 600))
        XCTAssertTrue(CallImport.converts(typeIdentifier: "com.apple.m4a-audio", bytes: 12_000_000, length: 600))
        XCTAssertTrue(CallImport.converts(typeIdentifier: "com.microsoft.waveform-audio", bytes: 100_000, length: 600))
        XCTAssertTrue(CallImport.converts(typeIdentifier: nil, bytes: nil, length: 600))
    }

    private var people: [Person] {
        var sam = Person(id: PersonID(rawValue: "p1"), displayName: "Sam Carter", origin: .owner, at: t0)
        sam.emails = [EmailIdentity(address: "sam@example.com", state: .verified, source: .owner, at: t0)]
        let sara = Person(id: PersonID(rawValue: "p2"), displayName: "Sara Lund", origin: .owner, at: t0)
        let owner = Person(id: PersonID(rawValue: "p0"), displayName: "Avery Webb", isOwner: true, origin: .owner, at: t0)
        var merged = Person(id: PersonID(rawValue: "p3"), displayName: "Samuel Carter", origin: .owner, at: t0)
        merged.mergedInto = PersonID(rawValue: "p1")
        return [sara, merged, owner, sam]
    }

    func testThePersonChoices() {
        XCTAssertEqual(CallImport.choices(query: "sa", people: people, heard: ["Jo Fenwick"], owner: "Avery Webb"),
                       [.init(name: "Sam Carter", personID: "p1"), .init(name: "Sara Lund", personID: "p2")])
        XCTAssertEqual(CallImport.choices(query: "", people: people, heard: [], owner: "Avery Webb").map(\.name), ["Sam Carter", "Sara Lund"])
        XCTAssertEqual(CallImport.choices(query: "carter s", people: people, heard: [], owner: "Avery Webb").map(\.name), ["Sam Carter"])
        XCTAssertEqual(CallImport.choices(query: "example", people: people, heard: [], owner: "Avery Webb").map(\.name), ["Sam Carter"])
        // No saved people on the phone: the named speakers, without the owner and without an id.
        XCTAssertEqual(CallImport.choices(query: "", people: [], heard: ["Sam Carter", "Avery Webb", "Jo Fenwick"], owner: "Avery Webb"),
                       [.init(name: "Jo Fenwick", personID: nil), .init(name: "Sam Carter", personID: nil)])
        let known = [CallImport.Choice(name: "Sam Carter", personID: "p1")]
        XCTAssertEqual(CallImport.typed("  sam carter ", among: known), known[0])
        XCTAssertEqual(CallImport.typed(" Mom ", among: known), .init(name: "Mom", personID: nil))
        XCTAssertNil(CallImport.typed("   ", among: known))
    }

    func testTheShortcutsResultWords() {
        XCTAssertEqual(CallImport.resultWords(sent: true), "Added to Mossad.")
        XCTAssertEqual(CallImport.resultWords(sent: false), "Added. Mossad sends it when you next open the app.")
    }

    func testTheImportMemory() throws {
        var memory = ImportMemory()
        memory.remember(hash: "h1", id: "a")
        memory.remember(hash: "h2", id: "b")
        XCTAssertEqual(memory.id(of: "h1"), "a")
        XCTAssertNil(memory.id(of: "h3"))
        memory.keep(only: ["b"])
        XCTAssertNil(memory.id(of: "h1"))
        XCTAssertEqual(memory.id(of: "h2"), "b")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = dir.appendingPathComponent(ImportMemory.fileName)
        try memory.save(to: saved)
        XCTAssertEqual(ImportMemory.load(from: saved), memory)
        XCTAssertEqual(ImportMemory.load(from: dir.appendingPathComponent("gone.json")), ImportMemory())
        try Data("{".utf8).write(to: saved)
        XCTAssertEqual(ImportMemory.load(from: saved), ImportMemory())

        let one = dir.appendingPathComponent("one.m4a"), two = dir.appendingPathComponent("two.m4a")
        let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
        try bytes.write(to: one)
        try bytes.write(to: two)
        XCTAssertEqual(try ImportMemory.hash(of: one), try ImportMemory.hash(of: two))
        XCTAssertEqual(try ImportMemory.hash(of: one).count, 64)
        try Data("other".utf8).write(to: two)
        XCTAssertNotEqual(try ImportMemory.hash(of: one), try ImportMemory.hash(of: two))
    }

    func testTwoSavedPeopleWithOneNameGiveTheNameWithNoID() {
        let two = [CallImport.Choice(name: "Sam Carter", personID: "p1"), CallImport.Choice(name: "Sam Carter", personID: "p4")]
        XCTAssertEqual(CallImport.typed("Sam Carter", among: two), .init(name: "Sam Carter", personID: nil))
        XCTAssertEqual(CallImport.typed("sam carter", among: two + [.init(name: "Sara Lund", personID: "p2")]), .init(name: "sam carter", personID: nil))
    }

    func testAMeetingThatCameBackAsAnIPhoneIDKeepsItsHash() {
        var memory = ImportMemory()
        memory.remember(hash: "h1", id: "20270101-090000")
        memory.keep(only: ["20270101-090000-iphone"])
        XCTAssertEqual(memory.id(of: "h1"), "20270101-090000")
        let back = CallImport.Known(id: "20270101-090000-iphone", start: t0 - 5_000, end: t0 - 4_400)
        XCTAssertEqual(plan(draft(file()), meetings: [back], memory: memory), .failure(.duplicate))
    }

    func testADateInTheFutureOrBefore2001IsNoDate() {
        // A metadata date an hour ahead: the file date (the share) gives the start, not the impossible one.
        XCTAssertEqual(CallImport.start(metadata: now + 3_600, file: now - 30, length: 600, now: now), .init(date: now - 630, sure: false))
        // An MPEG-4 header with no date reads as 1904.
        let empty = Date(timeIntervalSince1970: -2_082_844_800)
        XCTAssertEqual(CallImport.start(metadata: empty, file: nil, length: 600, now: now), .init(date: now - 600, sure: false))
        XCTAssertEqual(CallImport.start(metadata: nil, file: empty, length: 600, now: now, fileIs: .start), .init(date: now - 600, sure: false))
        XCTAssertEqual(CallImport.start(metadata: nil, file: now + 60, length: 600, now: now, fileIs: .start), .init(date: now - 600, sure: false))
    }

    func testAMetadataDateExactlyTwoMinutesOldIsTheShareTime() {
        XCTAssertEqual(CallImport.start(metadata: now - 120, file: nil, length: 30, now: now), .init(date: now - 150, sure: false))
    }

    func testARecordingTheIPhoneCouldNotSaveIsRefusedInPlainWords() {
        XCTAssertEqual(CallImport.Refusal.notSaved.message, "Mossad could not save this recording on the iPhone. Try again.")
    }
}
