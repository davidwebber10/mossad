import Foundation

/// Recent loudness of one track, for the live waveform. Written on the audio threads, read by the UI.
public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var levels: [Float] = []

    public init(capacity: Int = 96) {
        self.capacity = capacity
    }

    public func record(_ level: Float) {
        lock.withLock {
            levels.append(level)
            if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        }
    }

    /// Oldest first.
    public var history: [Float] { lock.withLock { levels } }

    public func reset() { lock.withLock { levels.removeAll() } }
}
