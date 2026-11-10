import CloudKit
import Foundation

/// Tries a network step again after a short pause when it failed for a reason that passes: a dropped or slow
/// connection, or a server error. A phone that wakes the app often has no route for a moment, and one such miss
/// must not show "Sync failed".
public enum TransientRetry {
    public static func run<T>(tries: Int = 2, pause: Duration = .seconds(2), isolation: isolated (any Actor)? = #isolation,
                              _ body: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch where attempt < tries && isTransient(error) {
                attempt += 1
                if pause > .zero { try await Task.sleep(for: pause) }
            }
        }
    }

    public static func isTransient(_ error: Error) -> Bool {
        if let e = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                    .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(e.code)
        }
        if case .http(let code, _) = error as? ServerError { return code >= 500 }
        if case .http(let code) = error as? ArchiveError { return code >= 500 }
        if let e = error as? CKError {
            return [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy].contains(e.code)
        }
        return false
    }
}
