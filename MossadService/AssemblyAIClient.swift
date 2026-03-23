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

        // v3 uses "type" field
        let messageType = json["type"] as? String ?? json["message_type"] as? String ?? ""

        switch messageType {
        case "Begin", "SessionBegins":
            let sessionId = json["id"] as? String ?? json["session_id"] as? String ?? ""
            return .begin(sessionId: sessionId)

        case "Turn":
            let text = json["transcript"] as? String ?? ""
            let endOfTurn = json["end_of_turn"] as? Bool ?? false
            var startMs = 0
            var endMs = 0
            var speakerLabel: String? = nil

            if let words = json["words"] as? [[String: Any]], !words.isEmpty {
                startMs = words.first?["start"] as? Int ?? 0
                endMs = words.last?["end"] as? Int ?? 0
            }

            return .turn(FinalTranscriptData(
                text: text, audioStartMs: startMs, audioEndMs: endMs, speakerLabel: speakerLabel
            ), endOfTurn: endOfTurn)

        case "Termination", "SessionTerminated":
            return .termination

        // v2 compat
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
            return .turn(FinalTranscriptData(text: text, audioStartMs: audioStart, audioEndMs: audioEnd, speakerLabel: speakerLabel), endOfTurn: true)

        case "PartialTranscript":
            let text = json["text"] as? String ?? ""
            return .turn(FinalTranscriptData(text: text, audioStartMs: 0, audioEndMs: 0, speakerLabel: nil), endOfTurn: false)

        default:
            aaiLog.debug("Unknown message type: \(messageType)")
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

    /// Connect using v3 API: get a token first, then open WebSocket
    public func connect() {
        aaiLog.notice("Requesting streaming token...")
        fetchToken { [weak self] token in
            guard let self, let token else {
                aaiLog.error("Failed to get streaming token")
                return
            }
            aaiLog.notice("Token received, connecting WebSocket...")
            self.connectWebSocket(token: token)
        }
    }

    private func fetchToken(completion: @escaping (String?) -> Void) {
        let urlString = "https://streaming.assemblyai.com/v3/token?expires_in_seconds=600"
        guard let url = URL(string: urlString) else { completion(nil); return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { data, response, error in
            if let error {
                aaiLog.error("Token request failed: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["token"] as? String else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "no body"
                aaiLog.error("Token response parse failed: \(body)")
                completion(nil)
                return
            }
            completion(token)
        }.resume()
    }

    private func connectWebSocket(token: String) {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "streaming.assemblyai.com"
        components.path = "/v3/ws"
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "token", value: token),
        ]
        aaiLog.notice("Connecting WebSocket (token length: \(token.count, privacy: .public))...")
        guard let url = components.url else {
            aaiLog.error("Invalid WebSocket URL from components")
            return
        }
        webSocketTask = session.webSocketTask(with: url)
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
