import Foundation
import MossadCore

/// What views read while they draw. Each value comes from a cache that is read again only after a change, so a
/// view's body never reads the disk or the Keychain on each redraw. Actions read the files themselves.
extension AppController {
    /// Call after each Keychain write, and when Settings opens, so a key added elsewhere shows too.
    func keysChanged() {
        keyCache.forget()
        objectWillChange.send()
    }

    /// The coach's profile as of the last coach change (`coachVersion`).
    var shownCoachProfile: CoachProfile { coachProfileCache.value(0, version: coachVersion) { coachProfile } }

    /// The coach's review of a call as of the last coach change.
    func shownCoachReview(_ callID: String) -> CoachReview? {
        coachReviewCache.value(callID, version: coachVersion) { coachReview(callID) }
    }

    /// Whether a summary can be made: a model is chosen and its key is there. Builds no client.
    var hasLanguageModel: Bool {
        (!aiProvider.requiresKey || aiProvider.key.map(hasKey) == true) && !(aiModel.isEmpty && aiProvider.defaultModel.isEmpty)
    }

    /// Whether a server is connected, without reading its secret.
    var hasServer: Bool {
        ServerSample.isOn || (hasKey(.serverSecret) && ServerConnection.address(from: serverAddress) != nil)
    }

    /// Whether the bucket is set up, without reading its secret.
    var hasBucket: Bool { backupSettings.hasBucket && hasKey(.cloudSecret) }
}
