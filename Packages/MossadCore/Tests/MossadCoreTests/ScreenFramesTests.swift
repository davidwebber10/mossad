import XCTest
@testable import MossadCore

final class ScreenFramesTests: XCTestCase {
    /// A thumb of one gray value, with `marked` cells set to white: a different picture for each count.
    func thumb(_ gray: UInt8, marked: Int = 0) -> FrameThumb {
        var p = [UInt8](repeating: gray, count: FrameThumb.width * FrameThumb.height)
        for i in 0..<marked { p[i] = 255 }
        return FrameThumb(pixels: p)!
    }

    // MARK: Thumb

    func testThumbDifference() {
        XCTAssertEqual(thumb(0).difference(from: thumb(0)), 0)
        XCTAssertEqual(thumb(0).difference(from: thumb(255)), 1)
        XCTAssertEqual(thumb(100).difference(from: thumb(151)), 0.2, accuracy: 0.001)
    }

    func testThumbFromPixelsInMemory() {
        // 64 x 36 BGRA with row padding: the left half black, the right half white.
        let width = 64, height = 36, bytesPerRow = 64 * 4 + 16
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height { for x in 32..<width { for c in 0..<4 { bytes[y * bytesPerRow + x * 4 + c] = 255 } } }
        let t = bytes.withUnsafeBytes { FrameThumb(bgra: $0.baseAddress!, width: width, height: height, bytesPerRow: bytesPerRow) }
        XCTAssertEqual(t?.pixels[0], 0)
        XCTAssertEqual(t?.pixels[FrameThumb.width - 1], 255)
        XCTAssertEqual(t?.pixels[FrameThumb.width * FrameThumb.height - 1], 255)
        XCTAssertNil(bytes.withUnsafeBytes { FrameThumb(bgra: $0.baseAddress!, width: 8, height: 8, bytesPerRow: 32) })
    }

    // MARK: Selector

    func testKeepsTheFirstPictureOnceItStays() {
        var s = FrameSelector()
        XCTAssertEqual(s.frame(thumb(10), at: 0), .init(keepHeldAt: nil, hold: true))
        // The next frame is the same picture: the held one is kept, at its own time.
        XCTAssertEqual(s.frame(thumb(10), at: 3), .init(keepHeldAt: 0, hold: false))
        // The same picture again is nothing new.
        XCTAssertEqual(s.frame(thumb(10), at: 6), .init())
    }

    func testAQuietWindowCountsAsStable() {
        var s = FrameSelector()
        _ = s.frame(thumb(10), at: 0)
        XCTAssertNil(s.quiet(at: 3).keepHeldAt)
        XCTAssertEqual(s.quiet(at: 6).keepHeldAt, 0)
    }

    func testAPictureInMotionIsNotKept() {
        var s = FrameSelector()
        _ = s.frame(thumb(10), at: 0)
        _ = s.frame(thumb(10), at: 3)
        // A transition: each frame differs from the one before. Each becomes the candidate; none is kept.
        XCTAssertEqual(s.frame(thumb(60), at: 20), .init(keepHeldAt: nil, hold: true))
        XCTAssertEqual(s.frame(thumb(120), at: 23), .init(keepHeldAt: nil, hold: true))
        XCTAssertEqual(s.frame(thumb(200), at: 26), .init(keepHeldAt: nil, hold: true))
        XCTAssertEqual(s.frame(thumb(200), at: 29), .init(keepHeldAt: 26, hold: false))
    }

    func testASmallChangeIsTheSamePicture() {
        var s = FrameSelector()
        _ = s.frame(thumb(10), at: 0)
        _ = s.frame(thumb(10), at: 3)
        // 5 of 576 cells changed: under the limit.
        XCTAssertEqual(s.frame(thumb(10, marked: 5), at: 30), .init())
        XCTAssertEqual(s.frame(thumb(10, marked: 40), at: 33).hold, true)
    }

    func testFramesAreAtLeastTenSecondsApartAndAnEarlyOneWaits() {
        var s = FrameSelector()
        _ = s.frame(thumb(10), at: 0)
        _ = s.frame(thumb(10), at: 3)
        // A new slide 4 s after the kept one, which then stays for minutes: it must not be lost.
        XCTAssertEqual(s.frame(thumb(200), at: 4).hold, true)
        XCTAssertNil(s.frame(thumb(200), at: 7).keepHeldAt)
        XCTAssertNil(s.quiet(at: 9).keepHeldAt)
        XCTAssertEqual(s.quiet(at: 12).keepHeldAt, 10)
        XCTAssertFalse(s.holdsCandidate)
    }

    func testAtMostTheHourlyLimit() {
        var rules = FrameRules()
        rules.maxPerHour = 3
        var s = FrameSelector(rules: rules)
        var kept: [TimeInterval] = []
        for i in 0..<10 {
            let t = TimeInterval(i * 20)
            _ = s.frame(thumb(UInt8(i * 20)), at: t)
            if let k = s.frame(thumb(UInt8(i * 20)), at: t + 3).keepHeldAt { kept.append(k) }
        }
        XCTAssertEqual(kept, [0, 20, 40])
        // An hour after the first one, there is room again.
        _ = s.frame(thumb(250), at: 3601)
        XCTAssertEqual(s.frame(thumb(250), at: 3604).keepHeldAt, 3601)
    }

    func testTheLastPictureBeforeAStopIsKept() {
        var s = FrameSelector()
        _ = s.frame(thumb(10), at: 0)
        XCTAssertEqual(s.finish(at: 1).keepHeldAt, 0)
        XCTAssertEqual(s.finish(at: 2), .init())
        // But not one that came too soon after the last kept frame.
        _ = s.frame(thumb(200), at: 4)
        XCTAssertNil(s.finish(at: 5).keepHeldAt)
        XCTAssertFalse(s.holdsCandidate)
    }

    func testAPictureThatCouldNotBeWrittenIsTriedAgain() {
        var s = FrameSelector()
        _ = s.frame(thumb(10), at: 0)
        XCTAssertEqual(s.frame(thumb(10), at: 3).keepHeldAt, 0)
        s.keepFailed()
        // The same picture counts as new again.
        XCTAssertEqual(s.frame(thumb(10), at: 6).hold, true)
        XCTAssertEqual(s.frame(thumb(10), at: 9).keepHeldAt, 6)
    }

    func testACandidateThatNoFrameConfirmedGoesWhenTheWindowIsLost() {
        var s = FrameSelector()
        _ = s.frame(thumb(10), at: 0)
        XCTAssertTrue(s.dropUnconfirmed())
        XCTAssertNil(s.quiet(at: 10).keepHeldAt)
        // One that a later frame confirmed, and that only waits for the 10 s, stays.
        _ = s.frame(thumb(10), at: 20)
        _ = s.frame(thumb(10), at: 23)
        _ = s.frame(thumb(200), at: 24)
        _ = s.frame(thumb(200), at: 27)
        XCTAssertFalse(s.dropUnconfirmed())
        XCTAssertEqual(s.quiet(at: 31).keepHeldAt, 30)
    }

    // MARK: Liveness

    func testAMinimizedWindowIsMarkedOnceAndTheReturnOnce() {
        var l = ScreenLiveness(at: 0)
        XCTAssertNil(l.frame(at: 3))
        XCTAssertNil(l.check(at: 9, windowOnScreen: false))
        XCTAssertEqual(l.check(at: 15, windowOnScreen: false), .paused(at: 3))
        XCTAssertNil(l.check(at: 18, windowOnScreen: nil))
        XCTAssertEqual(l.frame(at: 40), .resumed(at: 40))
        XCTAssertNil(l.frame(at: 43))
    }

    func testAWindowThatShowsTheSamePictureIsNotPaused() {
        var l = ScreenLiveness(at: 0)
        for t in stride(from: 3.0, to: 300, by: 3) { XCTAssertNil(l.check(at: t, windowOnScreen: true)) }
        XCTAssertEqual(l.check(at: 312, windowOnScreen: nil), .paused(at: 297))
        XCTAssertEqual(l.check(at: 330, windowOnScreen: true), .resumed(at: 330))
    }

    func testTheOwnersPauseIsNotAGap() {
        var l = ScreenLiveness(at: 0)
        _ = l.frame(at: 5)
        l.restart(at: 100)
        XCTAssertNil(l.check(at: 105, windowOnScreen: false))
        XCTAssertEqual(l.check(at: 112, windowOnScreen: false), .paused(at: 100))
    }

    // MARK: frames.json

    func testIndexRoundTripAndOrder() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(FrameIndex.load(from: dir))
        var index = FrameIndex()
        index.insert(.init(offset: 30.5, file: FrameIndex.fileName(offset: 30.5), window: "w1"))
        let time = Date(timeIntervalSince1970: 1_800_000_012)
        index.insert(.init(offset: 12.0004, file: FrameIndex.fileName(offset: 12.0004), presenter: "Sam Carter",
                           text: "Plan", words: [ScreenWord(text: "Plan", x: 0.1, y: 0.2, width: 0.3, height: 0.05)], time: time, session: 2))
        index.gaps = [ScreenGap(offset: 20, paused: true)]
        XCTAssertEqual(index.frames.map(\.file), ["12000.heic", "30500.heic"])
        try index.save(to: dir)
        XCTAssertEqual(FrameIndex.load(from: dir), index)
        // Only frames whose text was read are in the record's list.
        XCTAssertEqual(index.screens, [SharedScreen(offset: 12.0004, file: "12000.heic", text: "Plan", presenter: "Sam Carter", time: time, session: 2)])
    }

    func testAnIndexFromAnOlderBuildStillLoads() throws {
        let json = #"{"frames":[{"offset":4,"file":"4000.heic"}]}"#
        let index = try JSONDecoder().decode(FrameIndex.self, from: Data(json.utf8))
        XCTAssertEqual(index.frames, [.init(offset: 4, file: "4000.heic")])
    }

    func frames(in dir: URL, _ offsets: [TimeInterval], text: String? = nil) throws {
        try FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true)
        var index = FrameIndex(gaps: [ScreenGap(offset: 1, paused: true)])
        for o in offsets {
            let f = FrameIndex.Frame(offset: o, file: FrameIndex.fileName(offset: o), text: text, session: 0)
            index.insert(f)
            try Data("picture \(o)".utf8).write(to: index.url(of: f, in: dir))
        }
        try index.save(to: dir)
    }

    func files(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FrameIndex.folder(in: dir).path)) ?? []).sorted()
    }

    func testTrimDropsFramesAfterTheNewEnd() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try frames(in: dir, [10, 50, 90])
        FrameStore.trim(in: dir, to: 50)
        XCTAssertEqual(FrameIndex.load(from: dir)?.frames.map(\.offset), [10, 50])
        XCTAssertEqual(files(dir), ["10000.heic", "50000.heic"])
    }

    func testJoinMovesOffsetsAndFiles() throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two"), three = root.appendingPathComponent("three")
        try frames(in: one, [10, 50])
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)   // A part with no frames.
        try frames(in: three, [5])
        try FrameStore.join([one, two, three], offsets: [0, 100, 250])
        // Until the merge is final, the first part is as it was.
        XCTAssertEqual(FrameIndex.load(from: one)?.frames.map(\.offset), [10, 50])
        FrameStore.finishJoin(in: one)
        let joined = FrameIndex.load(from: one)
        XCTAssertEqual(joined?.frames.map(\.offset), [10, 50, 255])
        // The sessions of two parts stay apart, and the pauses move with their part.
        XCTAssertEqual(joined?.frames.map(\.session), [0, 0, 1])
        XCTAssertEqual(joined?.gaps?.map(\.offset), [1, 251])
        XCTAssertEqual(files(one), ["10000.heic", "255000.heic", "50000.heic"])
        XCTAssertEqual(try String(contentsOf: FrameIndex.folder(in: one).appendingPathComponent("255000.heic"), encoding: .utf8), "picture 5.0")
    }

    func testAnUndoneJoinLeavesTheFirstPartAsItWas() throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one"), two = root.appendingPathComponent("two")
        try frames(in: one, [10])
        try frames(in: two, [5])
        try FrameStore.join([one, two], offsets: [0, 100])
        FrameStore.undoJoin(in: one)
        XCTAssertEqual(FrameIndex.load(from: one)?.frames.map(\.offset), [10])
        XCTAssertEqual(files(one), ["10000.heic"])
        XCTAssertEqual(files(two), ["5000.heic"])
    }

    func testPicturesTheIndexDoesNotListAreRemoved() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try frames(in: dir, [10])
        try Data([1]).write(to: FrameIndex.folder(in: dir).appendingPathComponent("99000.heic"))
        FrameStore.removeUnlisted(in: dir)
        XCTAssertEqual(files(dir), ["10000.heic"])
    }

    // MARK: Text

    func testAGridOfFacesHasTooLittleText() {
        let faces = ["Sam Carter", "Dana Lee", "Alex Rivera", "Priya Shah", "Mute", "Stop Video", "Participants", "Chat", "Share Screen", "Leave"]
        XCTAssertFalse(ScreenText.hasEnough(faces.joined(separator: "\n")))
        XCTAssertFalse(ScreenText.hasEnough(""))
        XCTAssertFalse(ScreenText.hasEnough("You are viewing Sam Carter's screen"))
    }

    func testASlideOrADocumentHasEnoughText() {
        XCTAssertTrue(ScreenText.hasEnough("Q3 plan\nRevenue grew 12 percent over the second quarter\nChurn fell to 3 percent"))
        // Many short cells, as in a spreadsheet.
        XCTAssertTrue(ScreenText.hasEnough((1...45).map { "Cell\($0)" }.joined(separator: "\n")))
    }

    func testExcerptIsOneLineOfAtMost300Characters() {
        XCTAssertEqual(ScreenText.excerpt("Q3 plan\n  Revenue \"up\"\t12%"), "Q3 plan Revenue 'up' 12%")
        XCTAssertEqual(ScreenText.excerpt(String(repeating: "word ", count: 100)).count, 300)
    }

    func testWordBoxesThatMatchAQuery() {
        let words = [ScreenWord(text: "Revenue grew", x: 0, y: 0, width: 0.2, height: 0.1), ScreenWord(text: "Churn", x: 0, y: 0.2, width: 0.1, height: 0.1)]
        XCTAssertEqual(ScreenText.matches(words, query: "revenue churn").count, 2)
        XCTAssertEqual(ScreenText.matches(words, query: "Chur").map(\.text), ["Churn"])
        XCTAssertEqual(ScreenText.matches(words, query: " ").count, 0)
        XCTAssertEqual(ScreenText.matches(words, query: "budget").count, 0)
        // The grid's filter uses the same words: every one of them, in any order.
        XCTAssertTrue(ScreenText.contains("Revenue grew\nChurn fell", query: "churn revenue"))
        XCTAssertFalse(ScreenText.contains("Revenue grew", query: "churn revenue"))
        XCTAssertFalse(ScreenText.contains("Revenue grew", query: " "))
    }
}
