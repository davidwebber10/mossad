import AVFoundation
import Foundation

/// One AssemblyAI streaming session for one track. Audio comes from the capture threads; messages go to
/// `onMessage` on a background queue. Billed while the connection is open, so it is closed on pause and end.
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
    private let onMessage: @Sendable (Data) -> Void

    public init(apiKey: String, speakers: Bool = false, session: URLSession = .shared, onMessage: @escaping @Sendable (Data) -> Void) {
        var request = URLRequest(url: Self.url(speakers: speakers))
        // The key goes in a header, never in the URL, so it is not logged with the address.
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        self.onMessage = onMessage
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
                if self.queue.sync(execute: { self.open }) { Log.error("Live transcript stopped: \(error.localizedDescription)") }
                return
            }
            self.receive()
        }
    }

    /// Takes a 16 kHz mono buffer from the track writer.
    public func send(_ buffer: AVAudioPCMBuffer) {
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
        var data = Data(capacity: Int(buffer.frameLength) * 2)
        for i in 0..<Int(buffer.frameLength) {
            let value = Int16(max(-1, min(1, samples[i])) * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
