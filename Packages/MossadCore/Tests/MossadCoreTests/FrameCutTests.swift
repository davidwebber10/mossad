import XCTest
@testable import MossadCore

final class FrameCutTests: XCTestCase {
    /// A call folder with frames at the given offsets, each picture holding its own offset as its bytes.
    func callWithFrames(_ offsets: [TimeInterval], gaps: [ScreenGap]? = nil) throws -> URL {
        let dir = tempDirectory()
        try FileManager.default.createDirectory(at: FrameIndex.folder(in: dir), withIntermediateDirectories: true)
        var index = FrameIndex(gaps: gaps)
        for (i, o) in offsets.enumerated() {
            let f = FrameIndex.Frame(offset: o, file: FrameIndex.fileName(offset: o), window: "w", presenter: "Robin",
                                     text: "slide \(i)", words: [ScreenWord(text: "slide", x: 0.1, y: 0.2, width: 0.3, height: 0.1)],
                                     time: Date(timeIntervalSince1970: 1_000 + o), session: i < 2 ? 0 : 1)
            try Data("picture \(o)".utf8).write(to: index.url(of: f, in: dir))
            index.insert(f)
        }
        try index.save(to: dir)
        return dir
    }

    func testTheFramesOfTwoRangesAddUpToTheSource() throws {
        let source = try callWithFrames([1, 10, 20, 30.5])
        let before = try Data(contentsOf: source.appendingPathComponent(FrameIndex.fileName))
        let a = tempDirectory(), b = tempDirectory()
        try FrameStore.cut(in: source, from: 0, to: 20, into: a)
        try FrameStore.cut(in: source, from: 20, to: nil, into: b)
        let first = try XCTUnwrap(FrameIndex.load(from: a)), second = try XCTUnwrap(FrameIndex.load(from: b))
        XCTAssertEqual(first.frames.map(\.offset), [1, 10])
        // A frame exactly on the cut is the later part's, as a bookmark is.
        XCTAssertEqual(second.frames.map(\.offset), [0, 10.5])
        XCTAssertEqual(first.frames.count + second.frames.count, FrameIndex.load(from: source)?.frames.count)
        XCTAssertEqual(second.frames.map(\.file), ["0.heic", "10500.heic"])
        XCTAssertEqual(try Data(contentsOf: second.url(of: second.frames[1], in: b)), Data("picture 30.5".utf8))
        // The source is not changed.
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(FrameIndex.fileName)), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: FrameIndex.folder(in: source).path).count, 4)
    }

    func testFramesKeepTheirTextAndMoveTheirOffsets() throws {
        let source = try callWithFrames([5, 25])
        let b = tempDirectory()
        try FrameStore.cut(in: source, from: 20, to: nil, into: b)
        let f = try XCTUnwrap(FrameIndex.load(from: b)?.frames.first)
        XCTAssertEqual(f.offset, 5)
        XCTAssertEqual(f.text, "slide 1")
        XCTAssertEqual(f.words?.first?.text, "slide")
        XCTAssertEqual(f.presenter, "Robin")
        XCTAssertEqual(f.window, "w")
        XCTAssertEqual(f.time, Date(timeIntervalSince1970: 1_025))
        XCTAssertEqual(f.session, 0)
    }

    func testGapsAreDividedToo() throws {
        let source = try callWithFrames([5], gaps: [ScreenGap(offset: 8, paused: true), ScreenGap(offset: 22, paused: false)])
        let a = tempDirectory(), b = tempDirectory()
        try FrameStore.cut(in: source, from: 0, to: 20, into: a)
        try FrameStore.cut(in: source, from: 20, to: nil, into: b)
        XCTAssertEqual(FrameIndex.load(from: a)?.gaps, [ScreenGap(offset: 8, paused: true)])
        XCTAssertEqual(FrameIndex.load(from: b)?.gaps, [ScreenGap(offset: 2, paused: false)])
        XCTAssertNil(FrameIndex.load(from: b)?.frames.first)
    }

    func testACallWithNoFramesGivesNoFrames() throws {
        let source = tempDirectory(), b = tempDirectory()
        try FrameStore.cut(in: source, from: 0, to: 10, into: b)
        XCTAssertFalse(FrameStore.hasFrames(in: b))
    }
}
