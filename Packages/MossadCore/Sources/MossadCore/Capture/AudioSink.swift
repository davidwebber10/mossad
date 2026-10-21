import AVFoundation
import Foundation

/// Where a track's converted audio also goes while recording, for the live transcript.
/// A constant object with a lock, so the audio threads can call it while the app changes the handler.
public final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public init() {}

    public func set(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) { lock.withLock { self.handler = handler } }

    func send(_ buffer: AVAudioPCMBuffer) { lock.withLock { handler }?(buffer) }
}
