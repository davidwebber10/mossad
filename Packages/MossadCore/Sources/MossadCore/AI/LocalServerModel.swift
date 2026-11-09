import Foundation

/// An OpenAI-compatible server the owner runs, such as Ollama or LM Studio.
public enum LocalServer {
    public static let ollama = URL(string: "http://localhost:11434/v1")!
    public static let lmStudio = URL(string: "http://localhost:1234/v1")!
    public static let getOllama = URL(string: "https://ollama.com/download")!

    /// Local models are slow, and a long meeting on a large model can take many minutes.
    static let timeout: TimeInterval = 1800

    /// True only for this Mac's own loopback address. Anything else, even on the same network, is another computer.
    public static func isOnThisMac(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// A typed address as the base URL: "http://" added when missing, and "/v1" when no path is given.
    public static func url(from typed: String) -> URL? {
        var t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "http://" + t }
        guard var parts = URLComponents(string: t), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host?.isEmpty == false else { return nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if parts.path.isEmpty { parts.path = "/v1" }
        return parts.url
    }

    static func endpoint(_ base: URL, _ path: String) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + "/" + path)!
    }

    /// The models the server has, sorted by id.
    static func parseModels(_ json: Data) -> [ModelInfo] {
        ModelCatalog.data(json).compactMap { m in (m["id"] as? String).map { ModelInfo(id: $0, name: $0, created: m["created"] as? Int) } }
            .sorted { $0.id < $1.id }
    }

    /// A refused connection or no answer at all means nothing is listening at the address.
    static func isDown(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed].contains(code)
    }
}

public enum LocalServerError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notRunning(String)
    /// The server sent the request somewhere else; meeting data goes only to the configured address.
    case redirected(String)

    public var description: String {
        switch self {
        case .notRunning(let url): "Local server not running at \(url)"
        case .redirected(let url): "Local server redirected the request to \(url); Mossad did not follow it"
        }
    }

    public var errorDescription: String? { description }
}

/// Any model on the owner's OpenAI-compatible server, through chat completions. The schema goes as
/// `response_format` when the server takes it; otherwise it goes in the instructions and the reply is mended
/// and checked. Requests go only to `baseURL`.
public struct LocalServerModel: LanguageModel {
    static let maxRounds = 12

    public let baseURL: URL
    private let model: String
    private let apiKey: String?
    private let session: URLSession
    private let usage: UsageLog?

    public init(baseURL: URL, model: String, apiKey: String?, session: URLSession = .shared, usage: UsageLog? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
        self.session = session
        self.usage = usage
    }

    // MARK: Which servers take a schema

    private static let lock = NSLock()
    nonisolated(unsafe) private static var noSchema: Set<String> = []
    private var serverKey: String { "\(baseURL.absoluteString)|\(model)" }
    private var takesSchema: Bool { Self.lock.withLock { !Self.noSchema.contains(serverKey) } }
    private func markNoSchema() { _ = Self.lock.withLock { Self.noSchema.insert(serverKey) } }
    static func resetSchemaSupport() { lock.withLock { noSchema = [] } }

    // MARK: Requests

    private func send(_ body: [String: Any], purpose: UsageEvent.Purpose) async throws -> [String: Any] {
        var body = body
        body["model"] = model
        body["stream"] = false
        var request = URLRequest(url: LocalServer.endpoint(baseURL, "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = LocalServer.timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status) = try await Self.load(request, session: session, base: baseURL)
        guard (200..<300).contains(status) else { throw ProviderError.http("Local server", status, data.snippet) }
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SummaryError.malformed }
        if let u = reply["usage"] as? [String: Any] {
            usage?.record(service: .local, purpose: purpose, model: reply["model"] as? String ?? model,
                          inputTokens: u["prompt_tokens"] as? Int, outputTokens: u["completion_tokens"] as? Int)
        }
        return reply
    }

    /// Loads a request with redirects to another address refused, and a closed port reported as a stopped server.
    static func load(_ request: URLRequest, session: URLSession, base: URL) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request, delegate: SameHostOnly(base: base))
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch where LocalServer.isDown(error) {
            throw LocalServerError.notRunning(base.absoluteString)
        }
    }

    private static func choice(_ reply: [String: Any]) throws -> [String: Any] {
        guard let c = (reply["choices"] as? [[String: Any]])?.first, let message = c["message"] as? [String: Any] else {
            throw ProviderError.failed("Local server", (reply["error"] as? [String: Any])?["message"] as? String ?? "the reply had no message")
        }
        if c["finish_reason"] as? String == "length" {
            throw ProviderError.failed("Local server", "the reply was cut off before it finished; the model's context may be too small")
        }
        return message
    }

    /// A 4xx that names the response format means the server cannot take a schema.
    static func refusesSchema(_ status: Int, _ body: String) -> Bool {
        let lower = body.lowercased()
        return (400..<500).contains(status) && ![401, 403, 404].contains(status)
            && ["response_format", "json_schema", "format", "schema", "grammar"].contains { lower.contains($0) }
    }

    public func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                        purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        var messages: [[String: Any]]
        var reply: [String: Any]
        if takesSchema {
            messages = [["role": "system", "content": system], ["role": "user", "content": user]]
            do {
                reply = try await send(["messages": messages,
                                        "response_format": ["type": "json_schema", "json_schema": ["name": "output", "strict": true, "schema": schema]]],
                                       purpose: purpose)
            } catch ProviderError.http(_, let status, let body) where Self.refusesSchema(status, body) {
                Log.info("The local server did not take a JSON schema; asking with the schema in the instructions")
                markNoSchema()
                return try await json(system: system, user: user, schema: schema, effort: effort, purpose: purpose, as: Output.self)
            }
        } else {
            messages = [["role": "system", "content": system + "\n\n" + JSONRepair.instructions(schema)], ["role": "user", "content": user]]
            reply = try await send(["messages": messages], purpose: purpose)
        }
        var text = try Self.choice(reply)["content"] as? String
        var read = JSONRepair.read(text, schema: schema, as: Output.self)
        if let output = read.output { return output }
        // One more try, with what was wrong.
        Log.info("The local model's reply did not match the schema (\(read.problems.joined(separator: "; "))); asking again")
        messages += [["role": "assistant", "content": text ?? ""], ["role": "user", "content": JSONRepair.correction(read.problems)]]
        var body: [String: Any] = ["messages": messages]
        if takesSchema { body["response_format"] = ["type": "json_schema", "json_schema": ["name": "output", "strict": true, "schema": schema]] }
        text = try Self.choice(try await send(body, purpose: purpose))["content"] as? String
        read = JSONRepair.read(text, schema: schema, as: Output.self)
        guard let output = read.output else { throw SummaryError.malformed }
        return output
    }

    public func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                         execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        messages += history.map { ["role": $0.role.rawValue, "content": $0.text] }
        messages.append(["role": "user", "content": question])
        let definitions = tools.map {
            ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema] as [String: Any]] as [String: Any]
        }
        for _ in 0..<Self.maxRounds {
            let message = try Self.choice(try await send(["messages": messages, "tools": definitions], purpose: purpose))
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            guard !calls.isEmpty else { return message["content"] as? String ?? "" }
            messages.append(message)
            messages += calls.map { call in
                let function = call["function"] as? [String: Any] ?? [:]
                // Ollama sends the arguments as an object, OpenAI as a string.
                let arguments = function["arguments"] as? [String: Any]
                    ?? (function["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
                return ["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": execute(function["name"] as? String ?? "", arguments)]
            }
        }
        throw ChatError.tooManySteps
    }
}

/// Refuses any redirect that leaves the configured server.
private final class SameHostOnly: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let base: URL
    init(base: URL) { self.base = base }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, url.host() == base.host(), url.port == base.port, url.scheme == base.scheme else {
            Log.error(LocalServerError.redirected(request.url?.absoluteString ?? "?").description)
            return nil
        }
        return request
    }
}
