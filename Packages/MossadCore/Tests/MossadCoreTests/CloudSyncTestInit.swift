import Foundation
@testable import MossadCore

/// In the tests only: a sync with nothing leaving. The app and the worker must give `leaving:` (it has no default value),
/// so the compiler holds their wiring.
extension CloudSync {
    init(paths: Paths, store: any RecordStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(paths: paths, store: store, now: now, leaving: { [] })
    }
}
