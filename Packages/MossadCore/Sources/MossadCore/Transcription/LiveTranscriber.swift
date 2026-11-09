import AVFoundation
import Foundation
import Synchronization

/// The audio that waits for the network, with a limit. A slow uplink (a hotel, a phone hotspot) once let the
/// waiting audio grow in memory for the whole call. Above the limit the oldest audio goes; when that lasts, the
/// session is not worth its share of the uplink, which the call needs for video.
struct LiveSendQueue {
    /// 2 s of 16 kHz 16-bit audio.
    static let limitBytes = 64_000
    /// Dropping for this long without the queue running empty means the uplink cannot carry the stream.
    static let stuckAfter: TimeInterval = 10
    /// One send carries at most this much, so a queue that waited goes out in few messages.
    static let sendBytes = 16_000
    /// Drops further apart than this are not one stretch of a slow network.
    static let dropGap: TimeInterval = 3

    private var waiting: [Data] = []
    private(set) var waitingBytes = 0
    private(set) var droppedBytes = 0
    private(set) var inFlight = false
    private var droppingSince: TimeInterval?
    private var lastDrop: TimeInterval?

    /// Adds a chunk; false when the queue has been over its limit for too long.
    mutating func add(_ chunk: Data, at time: TimeInterval) -> Bool {
        waiting.append(chunk)
        waitingBytes += chunk.count
        var dropped = false
        while waitingBytes > Self.limitBytes, waiting.count > 1 {
            let old = waiting.removeFirst()
            waitingBytes -= old.count
            droppedBytes += old.count
            dropped = true
        }
        guard dropped else { return true }
        // A queue that stayed below its limit for a while and drops one chunk now starts a new count.
        if let last = lastDrop, time - last > Self.dropGap { droppingSince = nil }
        lastDrop = time
        if droppingSince == nil { droppingSince = time }
        return time - (droppingSince ?? time) < Self.stuckAfter
    }

    /// The next message for the socket, when none is on its way.
    mutating func next() -> Data? {
        guard !inFlight, !waiting.isEmpty else { return nil }
        var message = waiting.removeFirst()
        while let more = waiting.first, message.count + more.count <= Self.sendBytes {
            message.append(more)
            waiting.removeFirst()
        }
        waitingBytes -= message.count
        if waiting.isEmpty { droppingSince = nil }
        inFlight = true
        return message
    }

    mutating func sent() { inFlight = false }
}

/// While the owner is muted the mic stream is silence. The first second of it goes out (it ends the open turn);
/// after that only a short piece now and then, so the connection stays open at a fiftieth of the traffic.
struct SilenceThrottle {
    static let leadBytes = 32_000
    static let keepAliveEveryBytes = 160_000
    private var silentBytes = 0
    private var skippedBytes = 0

    mutating func shouldSend(bytes: Int, silent: Bool) -> Bool {
        guard silent else {
            silentBytes = 0
            skippedBytes = 0
            return true
        }
        silentBytes += bytes
        if silentBytes <= Self.leadBytes { return true }
        skippedBytes += bytes
        guard skippedBytes >= Self.keepAliveEveryBytes else { return false }
        skippedBytes = 0
        return true
    }
}

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
    private var outbox = LiveSendQueue()
    private var throttle = SilenceThrottle()
    private let skipsSilence: Bool
    private let dropped = Atomic<Int>(0)
    private var open = true
    /// Read on the capture side before any work, so a dead session costs nothing.
    private let alive = Atomic<Bool>(true)
    private let onMessage: @Sendable (Data) -> Void
    private let onFailure: (@Sendable () -> Void)?

    public var isAlive: Bool { alive.load(ordering: .relaxed) }
    /// Audio that never went out because the uplink was too slow. The service's times are short by this much.
    public var droppedSeconds: TimeInterval { Double(dropped.load(ordering: .relaxed)) / 32_000 }

    /// `skipsSilence` is for the owner's mic on a call: its times are not used, and it is silence while muted.
    public init(apiKey: String, speakers: Bool = false, skipsSilence: Bool = false, session: URLSession = .shared, url: URL? = nil,
                onFailure: (@Sendable () -> Void)? = nil, onMessage: @escaping @Sendable (Data) -> Void) {
        var request = URLRequest(url: url ?? Self.url(speakers: speakers))
        // The key goes in a header, never in the URL, so it is not logged with the address.
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        self.onMessage = onMessage
        self.onFailure = onFailure
        self.skipsSilence = skipsSilence
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
            if self.skipsSilence, !self.throttle.shouldSend(bytes: data.count, silent: data.allSatisfy({ $0 == 0 })) { return }
            self.pending.append(data)
            guard self.pending.count >= Self.chunkBytes else { return }
            let chunk = self.pending
            self.pending = Data()
            let carries = self.outbox.add(chunk, at: ProcessInfo.processInfo.systemUptime)
            self.dropped.store(self.outbox.droppedBytes, ordering: .relaxed)
            guard carries else { return self.giveUp() }
            self.pump()
        }
    }

    /// One message on its way at a time, so what waits is counted here and not hidden in the URL session. On the queue.
    private func pump() {
        guard open, let message = outbox.next() else { return }
        task.send(.data(message)) { [weak self] _ in
            self?.queue.async {
                self?.outbox.sent()
                self?.pump()
            }
        }
    }

    /// The uplink cannot carry the stream. On the queue.
    private func giveUp() {
        guard open else { return }
        open = false
        alive.store(false, ordering: .relaxed)
        Log.error("Live transcript stopped: the network is too slow for it (\(Int(droppedSeconds)) s of audio did not go out)")
        task.cancel(with: .goingAway, reason: nil)
        onFailure?()
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
