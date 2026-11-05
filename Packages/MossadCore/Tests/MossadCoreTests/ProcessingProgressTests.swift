import XCTest
@testable import MossadCore

final class ProcessingProgressTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    func testUploadPercentMovesTheOverallBar() {
        var p = ProcessingProgress(step: .transcribing, started: t0)
        p.tracks = [.me: .uploading(0), .them: .skipped]
        let before = p.fraction
        p.tracks[.me] = .uploading(0.5)
        XCTAssertGreaterThan(p.fraction, before)
        p.tracks[.me] = .done
        XCTAssertEqual(p.fraction, ProcessingProgress.stepEnds[0], accuracy: 0.0001, "a finished transcription ends the first step")
    }

    func testTheListShowsTheUploadThatIsFurthestBehind() {
        var p = ProcessingProgress(step: .transcribing, started: t0)
        p.tracks = [.me: .uploading(0.8), .them: .uploading(0.3)]
        XCTAssertEqual(p.slowestUpload, .them)
        p.tracks[.them] = .transcribing
        XCTAssertEqual(p.slowestUpload, .me)
        p.tracks[.me] = .done
        XCTAssertNil(p.slowestUpload)
    }

    func testLaterStepsAreFurtherAlong() {
        let steps = ProcessingStep.allCases.map { ProcessingProgress(step: $0, started: t0).fraction }
        XCTAssertEqual(steps, steps.sorted())
        XCTAssertLessThan(steps.last!, 1)
    }

    func testTheUploadLineSaysHowFarAndWhich() {
        var p = ProcessingProgress(step: .transcribing, started: t0)
        p.tracks = [.me: .uploading(0.42)]
        XCTAssertEqual(p.trackLine(.me, service: "AssemblyAI", room: false), "Uploading your mic · 42%")
        XCTAssertEqual(p.trackLine(.me, service: "AssemblyAI", room: true), "Uploading the room audio · 42%")
        p.tracks[.me] = .transcribing
        XCTAssertEqual(p.trackLine(.me, service: "AssemblyAI", room: false), "AssemblyAI is transcribing your mic")
    }
}

/// A value shared with a @Sendable callback in a test.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&value) } }
}
