import Foundation

/// A function the model can call during a chat, with its input as a JSON Schema object.
public struct ToolSpec: @unchecked Sendable {
    public let name: String
    public let description: String
    public let schema: [String: Any]

    public init(name: String, description: String, schema: [String: Any]) {
        self.name = name
        self.description = description
        self.schema = schema
    }
}

public enum Effort: String, Sendable { case low, medium, high }

/// One AI provider and model. Summaries, the coach, the weekly email, and the chat use only this, so any
/// provider that can return schema-shaped JSON and call tools can do all of them.
public protocol LanguageModel: Sendable {
    /// One request whose reply is JSON that matches `schema`.
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output

    /// Answers `question` after the earlier turns, calling `execute` for each tool call until the model answers.
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (_ name: String, _ input: [String: Any]) -> String) async throws -> String
}

public enum ChatError: Error, CustomStringConvertible {
    case tooManySteps

    public var description: String { "The model looked up too many things without an answer. Try a narrower question." }
}

/// Builders for the JSON schema dictionaries, so each schema reads like its shape.
enum Schema {
    static var string: [String: Any] { ["type": "string"] }
    static var nullableString: [String: Any] { ["anyOf": [["type": "string"], ["type": "null"]]] }
    static var nullableNumber: [String: Any] { ["anyOf": [["type": "number"], ["type": "null"]]] }
    static func array(_ items: [String: Any]) -> [String: Any] { ["type": "array", "items": items] }
    static func object(_ properties: [String: [String: Any]]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": Array(properties.keys).sorted(), "additionalProperties": false]
    }
    static func oneOf(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
}

extension Data {
    /// The start of an error body, for logs and messages.
    var snippet: String { String(decoding: prefix(500), as: UTF8.self) }
}

/// Sends a JSON request and returns the decoded JSON object, or throws the HTTP status and body.
func postJSON(_ url: URL, headers: [String: String], body: [String: Any], session: URLSession) async throws -> [String: Any] {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 600
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else { throw SummaryError.http(status, data.snippet) }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SummaryError.malformed }
    return object
}

/// Decodes the model's JSON text into `Output`.
func decodeOutput<Output: Decodable>(_ text: String?, as: Output.Type) throws -> Output {
    guard let text, let result = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else { throw SummaryError.malformed }
    return result
}
