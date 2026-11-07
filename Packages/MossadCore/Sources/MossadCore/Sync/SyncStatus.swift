import Foundation

/// What the iPhone shows about syncing: the sync problem for the card, and, apart from it, why each room
/// recording still waits to send. A good sync clears only the sync problem; an upload's reason stays on its
/// recording until that upload works.
public struct SyncStatus: Equatable, Sendable {
    public private(set) var shown: FriendlyError?
    public private(set) var uploads: [String: FriendlyError] = [:]
    /// Quiet drops in a row since the last good sync or the last problem that showed at once.
    private var drops = 0

    public init() {}

    public mutating func succeeded() {
        shown = nil
        drops = 0
    }

    /// A drop that is not worth a word yet leaves what is on screen as it is.
    public mutating func failed(_ error: FriendlyError) {
        switch error.visibility {
        case .never: return
        case .always: drops = 0
        case .whenRepeated: drops += 1
        }
        if error.shouldShow(failures: drops) { shown = error }
    }

    /// Shown at once and every time: a recording that waits must say why.
    public mutating func uploadFailed(_ id: String, _ error: FriendlyError) {
        guard error.kind != .cancelled else { return }
        uploads[id] = error
    }

    public mutating func uploaded(_ id: String) { uploads[id] = nil }

    /// Drops the reasons of recordings no longer waiting.
    public mutating func keepUploads(for ids: Set<String>) { uploads = uploads.filter { ids.contains($0.key) } }

    /// For a problem the app knows at once, such as no server connected.
    public mutating func show(_ error: FriendlyError?) { shown = error }
}
