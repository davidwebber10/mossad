import XCTest
@testable import MossadCore

final class ProcessingStepTests: XCTestCase {
    func testStepFollowsStatus() {
        XCTAssertEqual(ProcessingStep(status: .recorded), .transcribing)
        XCTAssertEqual(ProcessingStep(status: .transcribed), .identifying)
        XCTAssertEqual(ProcessingStep(status: .identified), .summarizing)
        XCTAssertEqual(ProcessingStep(status: .summarized), .writing)
        XCTAssertNil(ProcessingStep(status: .recording))
        XCTAssertNil(ProcessingStep(status: .written))
        XCTAssertNil(ProcessingStep(status: .failed))
    }

    func testNumbersTitlesAndTotal() {
        XCTAssertEqual(ProcessingStep.allCases.map(\.rawValue), [1, 2, 3, 4])
        XCTAssertEqual(ProcessingStep.allCases.map(\.title), ["Transcribing", "Identifying speakers", "Writing summary", "Writing note"])
        XCTAssertEqual(ProcessingStep.total, 4)
    }
}
