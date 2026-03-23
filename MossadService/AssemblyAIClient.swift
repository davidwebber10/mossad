import Foundation
import os.log

private let aaiLog = Logger(subsystem: "com.mossad.app", category: "AssemblyAI")

// MARK: - Message Types

public struct FinalTranscriptData {
    public let text: String
    public let audioStartMs: Int
    public let audioEndMs: Int
    public let speakerLabel: String?
}

public enum AssemblyAIMessage {
    case begin(sessionId: String)
    case turn(FinalTranscriptData, endOfTurn: Bool)
    case termination
    case unknown

    public static func parse(_ jsonString: String) throws -> AssemblyAIMessage {
        guard let data = jsonString.data(using: .utf8) else { return .unknown }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let messageType = json["type"] as? String ?? ""

        switch messageType {
        case "Begin":
            let sessionId = json["id"] as? String ?? ""
            return .begin(sessionId: sessionId)

        case "Turn":
            let text = json["transcript"] as? String ?? ""
            let endOfTurn = json["end_of_turn"] as? Bool ?? false
            var startMs = 0
            var endMs = 0
            if let words = json["words"] as? [[String: Any]], !words.isEmpty {
                startMs = words.first?["start"] as? Int ?? 0
                endMs = words.last?["end"] as? Int ?? 0
            }
            return .turn(FinalTranscriptData(
                text: text, audioStartMs: startMs, audioEndMs: endMs, speakerLabel: nil
            ), endOfTurn: endOfTurn)

        case "Termination":
            return .termination

        default:
            aaiLog.debug("Unknown message type: \(messageType, privacy: .public)")
            return .unknown
        }
    }
}

// MARK: - Client

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
        let urlString = "wss://streaming.assemblyai.com/v3/ws?sample_rate=16000"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        aaiLog.notice("Connecting to AssemblyAI streaming...")
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

    /// Send raw PCM audio data as binary
    public func sendAudio(_ pcmData: Data) {
        guard isConnected else { return }
        let message = URLSessionWebSocketTask.Message.data(pcmData)
        webSocketTask?.send(message) { [weak self] error in
            if let error { self.map { self?.delegate?.client($0, didEncounterError: error) } }
        }
    }

    /// Send end-of-stream signal
    public func terminateSession() {
        guard isConnected else { return }
        let json = "{\"terminate_session\": true}"
        let message = URLSessionWebSocketTask.Message.string(json)
        webSocketTask?.send(message) { _ in }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.handleMessage(text)
                default: break
                }
                self.receiveMessage()
            case .failure(let error):
                aaiLog.error("WebSocket receive error: \(String(describing: error), privacy: .public)")
                self.delegate?.client(self, didEncounterError: error)
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let message = try? AssemblyAIMessage.parse(text) else { return }
        switch message {
        case .begin:
            isConnected = true
            aaiLog.notice("Session started")
            delegate?.clientDidConnect(self)
        case .turn(let transcript, let endOfTurn):
            if endOfTurn && !transcript.text.isEmpty {
                delegate?.client(self, didReceiveFinalTranscript: transcript)
            } else if !transcript.text.isEmpty {
                delegate?.client(self, didReceivePartialTranscript: transcript.text)
            }
        case .termination:
            aaiLog.notice("Session terminated by server")
            disconnect()
        case .unknown:
            break
        }
    }
}
