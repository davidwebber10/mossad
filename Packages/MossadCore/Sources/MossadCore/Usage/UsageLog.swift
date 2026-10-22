import Foundation

/// One billed request to AssemblyAI or Claude, as the service reported it.
public struct UsageEvent: Codable, Equatable, Sendable {
    public enum Service: String, Codable, Sendable, CaseIterable { case assemblyai, claude, openai, openrouter, deepgram, elevenlabs }
    public enum Purpose: String, Codable, Sendable, CaseIterable { case transcription, live, summary, coach, weeklyEmail, question }

    public var date: Date
    public var callID: String?
    public var service: Service
    public var purpose: Purpose
    public var model: String?
    public var audioSeconds: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    /// The charged amount when the provider reports it (OpenRouter does); it wins over the price table.
    public var costUSD: Double?
    /// Worked out from a call's length and transcript, for calls from before usage was logged.
    public var estimated = false

    public init(date: Date, callID: String?, service: Service, purpose: Purpose, model: String?, audioSeconds: Double? = nil,
                inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil,
                estimated: Bool = false) {
        self.date = date
        self.callID = callID
        self.service = service
        self.purpose = purpose
        self.model = model
        self.audioSeconds = audioSeconds
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.estimated = estimated
    }
}

/// Which call the requests in this task belong to. Set where a call is processed, read where usage is logged,
/// so the API clients need no call ID of their own.
public enum UsageContext {
    @TaskLocal public static var callID: String?
}

/// Usage events, one JSON object per line in `~/Mossad/Usage/usage.jsonl`. Appends are serialized by a lock
/// because both tracks transcribe at the same time.
public final class UsageLog: Sendable {
    public static let fileName = "usage.jsonl"

    private let url: URL
    private let lock = NSLock()

    public init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
    }

    public func record(_ event: UsageEvent) {
        guard var line = try? JSONEncoder.coach.encode(event).compactJSON() else { return }
        line.append(0x0A)
        lock.withLock {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                } else {
                    try line.write(to: url)
                }
            } catch {
                Log.error("Logging usage failed: \(error)")
            }
        }
    }

    public func record(service: UsageEvent.Service, purpose: UsageEvent.Purpose, model: String?, audioSeconds: Double? = nil,
                       inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil, cacheWriteTokens: Int? = nil,
                       costUSD: Double? = nil, at date: Date = Date()) {
        var event = UsageEvent(date: date, callID: UsageContext.callID, service: service, purpose: purpose, model: model, audioSeconds: audioSeconds,
                               inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens)
        event.costUSD = costUSD
        record(event)
    }

    public func all() -> [UsageEvent] {
        let text = lock.withLock { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return text.split(separator: "\n").compactMap { try? JSONDecoder.coach.decode(UsageEvent.self, from: Data($0.utf8)) }
    }
}

private extension Data {
    /// The pretty encoder adds newlines; one event must stay on one line.
    func compactJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: self), options: [.sortedKeys])
    }
}
