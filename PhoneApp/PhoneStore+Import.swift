import Foundation
import MossadCore

/// A call recording shared to the profile that shows: the uploader does the import; the store waits for its first
/// read, so the duplicates are checked against the meetings in memory.
extension PhoneStore {
    /// The people the owner can pick for a call: the saved people, else the named speakers of the meetings.
    func importChoices(_ query: String) -> [CallImport.Choice] {
        uploader.importChoices(query, heard: Array(personStats.keys), owner: owner)
    }

    /// A refusal the screen can show before the owner taps anything; nil when the file can be added.
    func importRefusal(_ draft: CallImport.Draft, from url: URL) async -> CallImport.Refusal? {
        await launch?.value
        return await uploader.importRefusal(draft, from: url)
    }

    /// Adds the file. The caller deletes the handed file after a success.
    func importCall(_ draft: CallImport.Draft, from url: URL) async -> Result<String, CallImport.Refusal> {
        await launch?.value
        return await uploader.importCall(draft, from: url)
    }

    /// Waits for the upload of one recording, at most `seconds`.
    func sent(_ id: String, within seconds: TimeInterval) async -> Bool {
        await uploader.sent(id, within: seconds)
    }
}
