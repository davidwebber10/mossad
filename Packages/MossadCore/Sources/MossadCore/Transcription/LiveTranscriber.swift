import AVFoundation
import Foundation
import Synchronization

/// One AssemblyAI streaming session for one track. Audio comes from the capture threads; messages go to
/// `onMessage` on a background queue. Billed while the connection is open, so it is closed on pause and end.
/// A connection that fails is not opened again here: `onFailure` runs once, and the owner of the session starts a new
/// one at the track's current length, so the new session's times still match the file.
public final class LiveTranscriber: @unchecked Sendable {
    /// Speaker labels only for the call audio: the mic is the owner.
    static func url(speakers: Bool) -> URL {
        URL(string: "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000&format_turns=true" + (speakers ? "&speaker_labels=true" : ""))!
    }
    /// About 100 ms of 16 kHz 16-bit audio per send.
    static let chunkBytes = 3_200

    private let queue = DispatchQueue(label: "com.dwebber.mossad.live")
    private let task: URLSessionWebSocketTask
    private var pending = Data()
    private var open = true
    /// Read on the capture side before any work, so a dead session costs nothing.
    private let alive = Atomic<Bool>(true)
    private let onMessage: @Sendable (Data) -> Void
    private let onFailure: (@Sendable () -> Void)?

    public var isAlive: Bool { alive.load(ordering: .relaxed) }

    public init(apiKey: String, speakers: Bool = false, session: URLSession = .shared, url: URL? = nil,
                onFailure: (@Sendable () -> Void)? = nil, onMessage: @escaping @Sendable (Data) -> Void) {
        var request = URLRequest(url: url ?? Self.url(speakers: speakers))
        // The key goes in a header, never in the URL, so it is not logged with the address.
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        self.onMessage = onMessage
        self.onFailure = onFailure
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)): self.onMessage(Data(text.utf8))
            case .success(.data(let data)): self.onMessage(data)
            case .success: break
            case .failure(let error):
                // Only a session that was not stopped on purpose failed.
                let failed = self.queue.sync {
                    defer { self.open = false }
                    return self.open
                }
                self.alive.store(false, ordering: .relaxed)
                if failed {
                    Log.error("Live transcript stopped: \(error.localizedDescription)")
                    self.task.cancel(with: .goingAway, reason: nil)
                    self.onFailure?()
                }
                return
            }
            self.receive()
        }
    }

    /// Takes a 16 kHz mono buffer from the track writer.
    public func send(_ buffer: AVAudioPCMBuffer) {
        guard isAlive else { return }
        let data = Self.pcm16(buffer)
        queue.async {
            guard self.open else { return }
            self.pending.append(data)
            guard self.pending.count >= Self.chunkBytes else { return }
            let chunk = self.pending
            self.pending = Data()
            self.task.send(.data(chunk)) { _ in }
        }
    }

    /// Ends the session: the server finalizes the open turn, then the connection closes.
    public func stop() {
        alive.store(false, ordering: .relaxed)
        queue.async {
            guard self.open else { return }
            self.open = false
            self.task.send(.string(#"{"type":"Terminate"}"#)) { _ in }
            self.queue.asyncAfter(deadline: .now() + 2) { self.task.cancel(with: .normalClosure, reason: nil) }
        }
    }

    /// Float samples to 16-bit little-endian PCM, clipped to the 16-bit range.
    static func pcm16(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let samples = buffer.floatChannelData?[0] else { return Data() }
        let count = Int(buffer.frameLength)
        // One pass into a fixed buffer, not two bytes appended at a time.
        let values = [Int16](unsafeUninitializedCapacity: count) { out, n in
            for i in 0..<count { out[i] = Int16(max(-1, min(1, samples[i])) * Float(Int16.max)).littleEndian }
            n = count
        }
        return values.withUnsafeBytes { Data($0) }
    }
}
