import XCTest
@testable import MossadCore

final class SyncStatusTests: XCTestCase {
    let drop = FriendlyError(URLError(.cannotConnectToHost), context: .syncing, service: "iCloud")
    let full = FriendlyError(kind: .iCloudFull, context: .syncing)
    let upload = FriendlyError(kind: .tooLarge, context: .uploadingAudio, service: "your server")

    func testAQuietDropShowsOnlyWhenItRepeats() {
        var s = SyncStatus()
        s.failed(drop)
        XCTAssertNil(s.shown)
        s.failed(drop)
        XCTAssertEqual(s.shown, drop)
        s.succeeded()
        XCTAssertNil(s.shown)
    }

    func testAQuietDropDoesNotClearAShownError() {
        var s = SyncStatus()
        s.failed(full)
        XCTAssertEqual(s.shown, full)
        s.succeeded()
        s.failed(full)
        s.failed(drop)
        XCTAssertEqual(s.shown, full, "One quiet drop leaves the real problem on screen")
    }

    func testCancelledIsNotAFailure() {
        var s = SyncStatus()
        s.failed(drop)
        s.failed(FriendlyError(CancellationError(), context: .syncing))
        XCTAssertNil(s.shown)
        s.failed(drop)
        XCTAssertEqual(s.shown, drop)
    }

    func testAnUploadFailureStaysOnItsRecordingThroughASuccessfulSync() {
        var s = SyncStatus()
        s.uploadFailed("rec1", upload)
        s.succeeded()
        XCTAssertEqual(s.uploads["rec1"], upload)
        XCTAssertNil(s.shown)
        s.uploaded("rec1")
        XCTAssertNil(s.uploads["rec1"])
    }

    func testEveryUploadFailureShowsOnTheRowEvenAQuietOne() {
        var s = SyncStatus()
        let offline = FriendlyError(URLError(.notConnectedToInternet), context: .uploadingAudio)
        s.uploadFailed("rec1", offline)
        XCTAssertEqual(s.uploads["rec1"], offline, "A recording that waits always says why")
        s.uploadFailed("rec1", FriendlyError(CancellationError(), context: .uploadingAudio))
        XCTAssertEqual(s.uploads["rec1"], offline, "A stopped request keeps the last reason")
    }

    func testForgetsUploadsThatLeftTheOutbox() {
        var s = SyncStatus()
        s.uploadFailed("rec1", upload)
        s.uploadFailed("rec2", upload)
        s.keepUploads(for: ["rec2"])
        XCTAssertEqual(Array(s.uploads.keys), ["rec2"])
    }
}

extension SyncStatusTests {
    func testTwoDropsInARowReplaceAnOlderProblem() {
        var s = SyncStatus()
        s.failed(full)
        s.failed(drop)
        s.failed(drop)
        XCTAssertEqual(s.shown, drop)
    }
}
