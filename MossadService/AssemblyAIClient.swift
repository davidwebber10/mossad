import Foundation

// MARK: - Message Types and Parser

public struct FinalTranscriptData {
    public let text: String
    public let audioStartMs: Int
    public let audioEndMs: Int
    public let speakerLabel: String?
}

public enum AssemblyAIMessage {
    case sessionBegins(sessionId: String)
    case partialTranscript(text: String)
    case finalTranscript(FinalTranscriptData)
    case terminated
    case unknown

    public static func parse(_ jsonString: String) throws -> AssemblyAIMessage {
        guard let data = jsonString.data(using: .utf8) else { return .unknown }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let messageType = json["message_type"] as? String else { return .unknown }

        switch messageType {
        case "SessionBegins":
            let sessionId = json["session_id"] as? String ?? ""
            return .sessionBegins(sessionId: sessionId)
        case "PartialTranscript":
            let text = json["text"] as? String ?? ""
            return .partialTranscript(text: text)
        case "FinalTranscript":
            let text = json["text"] as? String ?? ""
            let audioStart = json["audio_start"] as? Int ?? 0
            let audioEnd = json["audio_end"] as? Int ?? 0
            var speakerLabel: String? = nil
            if let words = json["words"] as? [[String: Any]] {
                var counts: [String: Int] = [:]
                for word in words { if let speaker = word["speaker"] as? String { counts[speaker, default: 0] += 1 } }
                speakerLabel = counts.max(by: { $0.value < $1.value })?.key
            }
            return .finalTranscript(FinalTranscriptData(text: text, audioStartMs: audioStart, audioEndMs: audioEnd, speakerLabel: speakerLabel))
        case "SessionTerminated":
            return .terminated
        default:
            return .unknown
        }
    }
}

// MARK: - WebSocket Client

public protocol AssemblyAIClientDelegate: AnyObject {
    func client(_ client: AssemblyAIClient, didReceiveFinalTranscript transcript: FinalTranscriptData)
    func client(_ client: AssemblyAIClient, didReceivePartialTranscript text: String)
    func clientDidConnect(_ client: AssemblyAIClient)
    func clientDidDisconnect(_ client: AssemblyAIClient)
    func client(_ client: AssemblyAIClient, didEncounterError error: Error)
}

public final class AssemblyAIClient {
    private let apiKey: String
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    public weak var delegate: AssemblyAIClientDelegate?
    private var isConnected = false

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default)
    }

    public func connect() {
        let urlString = "wss://api.assemblyai.com/v2/realtime/ws?sample_rate=16000&speaker_labels=true"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()
        receiveMessage()
    }

    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        delegate?.clientDidDisconnect(self)
    }

    public func sendAudio(_ pcmData: Data) {
        guard isConnected else { return }
        let base64 = pcmData.base64EncodedString()
        let json = "{\"audio_data\": \"\(base64)\"}"
        let message = URLSessionWebSocketTask.Message.string(json)
        webSocketTask?.send(message) { [weak self] error in
            if let error = error { self.map { self?.delegate?.client($0, didEncounterError: error) } }
        }
    }

    public func terminateSession() {
        guard isConnected else { return }
        let json = "{\"terminate_session\": true}"
        let message = URLSessionWebSocketTask.Message.string(json)
        webSocketTask?.send(message) { _ in }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handleMessage(text)
                default: break
                }
                self.receiveMessage()
            case .failure(let error):
                self.delegate?.client(self, didEncounterError: error)
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let message = try? AssemblyAIMessage.parse(text) else { return }
        switch message {
        case .sessionBegins:
            isConnected = true
            delegate?.clientDidConnect(self)
        case .partialTranscript(let partialText):
            delegate?.client(self, didReceivePartialTranscript: partialText)
        case .finalTranscript(let transcript):
            if !transcript.text.isEmpty { delegate?.client(self, didReceiveFinalTranscript: transcript) }
        case .terminated:
            disconnect()
        case .unknown:
            break
        }
    }
}
