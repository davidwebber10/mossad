import XCTest
@testable import MossadCore

final class DeleteWordsTests: XCTestCase {
    /// The words say what Delete removes now (`CallForget`), that the people stay, and that it cannot be undone.
    func testTheConfirmationSaysWhatGoes() {
        XCTAssertEqual(DeleteWords.confirmation,
                       "Mossad deletes the recording and its notes, its tasks, its chats, your points for this meeting, and the voice samples "
                       + "it learned from this call. The people stay. You cannot undo this.")
        XCTAssertFalse(DeleteWords.confirmation.contains("Voices it learned from this call stay"))
    }
}
