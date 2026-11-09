import Foundation

/// Runs async work one piece at a time, in the order it was added. Two writers of the same file (a sync's pull and
/// an edit on the phone) go through one queue, so neither saves over what the other merged.
public actor SerialQueue {
    private var last: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = last
        let task = Task<T, Error> {
            await previous?.value
            return try await work()
        }
        last = Task { _ = try? await task.value }
        // A caller that stops waiting stops its own work too, such as a sync left for another store.
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
