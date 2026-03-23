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
            let speakerLabel = json["speaker_label"] as? String
            var startMs = 0
            var endMs = 0
            if let words = json["words"] as? [[String: Any]], !words.isEmpty {
                startMs = words.first?["start"] as? Int ?? 0
                endMs = words.last?["end"] as? Int ?? 0
            }
            return .turn(FinalTranscriptData(
                text: text, audioStartMs: startMs, audioEndMs: endMs, speakerLabel: speakerLabel
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
    private var audioBuffer = Data()
    private let minChunkSize = 6400  // 200ms at 16kHz 16-bit mono (sweet spot for accuracy)

    private class SessionDelegate: NSObject, URLSessionWebSocketDelegate {
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            aaiLog.notice("WebSocket didOpen with protocol: \(`protocol` ?? "none", privacy: .public)")
        }
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "none"
            aaiLog.notice("WebSocket didClose: code=\(closeCode.rawValue, privacy: .public) reason=\(reasonStr, privacy: .public)")
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                aaiLog.error("URLSession task error: \(String(describing: error), privacy: .public)")
            }
        }
    }
    private let sessionDelegate = SessionDelegate()

    public init(apiKey: String) {
        self.apiKey = apiKey
        self.session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
    }

    public func connect() {
        let urlString = "wss://streaming.assemblyai.com/v3/ws?speech_model=u3-rt-pro&sample_rate=16000&encoding=pcm_s16le&speaker_labels=true&token=\(apiKey)"
        guard let url = URL(string: urlString) else { return }
        aaiLog.notice("Connecting to AssemblyAI streaming...")
        // Create a dedicated session with delegate for this connection
        let delegateSession = URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
        webSocketTask = delegateSession.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveMessage()
    }

    public func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        delegate?.clientDidDisconnect(self)
    }

    /// Send raw PCM audio data as binary, buffering to meet minimum chunk size
    public func sendAudio(_ pcmData: Data) {
        guard isConnected else { return }
        audioBuffer.append(pcmData)
        while audioBuffer.count >= minChunkSize {
            let chunk = audioBuffer.prefix(minChunkSize)
            audioBuffer.removeFirst(minChunkSize)
            let message = URLSessionWebSocketTask.Message.data(Data(chunk))
            webSocketTask?.send(message) { [weak self] error in
                if let error { self.map { self?.delegate?.client($0, didEncounterError: error) } }
            }
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
