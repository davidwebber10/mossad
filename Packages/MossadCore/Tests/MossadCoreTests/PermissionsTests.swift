import CoreGraphics
import XCTest
@testable import MossadCore

final class PermissionsTests: XCTestCase {
    func testAutomationStatusCodes() {
        XCTAssertEqual(Permissions.automationState(osStatus: 0), .granted)
        XCTAssertEqual(Permissions.automationState(osStatus: -1743), .denied)
        XCTAssertEqual(Permissions.automationState(osStatus: -1744), .notAsked)
        XCTAssertEqual(Permissions.automationState(osStatus: -600), .needsApp)
    }

    func testTCCPreflightResults() {
        XCTAssertEqual(Permissions.tccState(preflight: 0), .granted)
        XCTAssertEqual(Permissions.tccState(preflight: 1), .denied)
        XCTAssertEqual(Permissions.tccState(preflight: 2), .notAsked)
        XCTAssertEqual(Permissions.tccState(preflight: nil), .notAsked)
    }

    func testAClosedBrowserKeepsItsLastKnownState() {
        XCTAssertEqual(Permissions.resolve(.needsApp, lastKnown: .granted), .granted)
        XCTAssertEqual(Permissions.resolve(.needsApp, lastKnown: nil), .needsApp)
        XCTAssertEqual(Permissions.resolve(.denied, lastKnown: .granted), .denied)
    }

    func testOnlyGrantedIsGood() {
        XCTAssertTrue(PermissionState.granted.isGood)
        for s in [PermissionState.denied, .notAsked, .needsApp] { XCTAssertFalse(s.isGood) }
    }

    func testDragPaneSupportsDragIn() {
        XCTAssertTrue(PermissionKind.accessibility.acceptsDraggedApp)
        XCTAssertTrue(PermissionKind.systemAudio.acceptsDraggedApp)
        XCTAssertFalse(PermissionKind.microphone.acceptsDraggedApp)
        XCTAssertFalse(PermissionKind.automation("com.google.Chrome").acceptsDraggedApp)
    }

    func testSettingsURLs() {
        XCTAssertEqual(PermissionKind.accessibility.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(PermissionKind.notifications.settingsURL.absoluteString,
                       "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.dwebber.mossad")
    }

    // CGWindow bounds use a top-left origin; AppKit frames use a bottom-left origin.
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testHelperSitsCenteredBelowTheSettingsWindow() {
        let window = CGRect(x: 400, y: 100, width: 600, height: 500) // bottom edge at y=600 from the top
        let f = Permissions.helperFrame(settingsWindow: window, primaryScreenHeight: 900, visible: screen, size: CGSize(width: 300, height: 90))
        XCTAssertEqual(f.midX, window.midX, accuracy: 0.5)
        XCTAssertEqual(f.maxY, 900 - 600 - 8, accuracy: 0.5)
    }

    func testHelperStaysOnScreenWhenTheWindowIsLow() {
        let window = CGRect(x: 1200, y: 300, width: 600, height: 600) // bottom edge at the screen bottom, off the right side
        let f = Permissions.helperFrame(settingsWindow: window, primaryScreenHeight: 900, visible: screen, size: CGSize(width: 300, height: 90))
        XCTAssertTrue(screen.contains(f), "\(f)")
    }
}
