#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Apple's on-device model through FoundationModels. Free and private, with a small context: summaries of long
/// meetings go in parts (see `LLMSummarizer.summarizeInParts`). Output follows the schema by guided generation
/// when the schema converts, and otherwise by the schema in the instructions with the reply mended and checked.
struct AppleModel: ContextLimitedModel {
    private let usage: UsageLog?

    init(usage: UsageLog?) { self.usage = usage }

    /// Meeting text is transformed, not generated from nothing, so the permissive guardrails fit.
    private var model: SystemLanguageModel { SystemLanguageModel(guardrails: .permissiveContentTransformations) }

    static func unavailableReason() -> OnDeviceModelError? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceOff
        case .unavailable(.deviceNotEligible): .notEligible
        case .unavailable(.modelNotReady): .notReady
        case .unavailable: .unsupported
        }
    }

    func contextTokens() async -> Int { SystemLanguageModel.default.contextSize }

    func tokenCount(_ text: String) async -> Int {
        if #available(macOS 26.4, iOS 26.4, *), let n = try? await SystemLanguageModel.default.tokenCount(for: text) { return n }
        return ChunkPlanner.estimate(text)
    }

    private func ready() throws {
        if let reason = Self.unavailableReason() { throw reason }
    }

    private func record(_ purpose: UsageEvent.Purpose, input: String, output: String) async {
        guard let usage else { return }
        let i = await tokenCount(input), o = await tokenCount(output)
        usage.record(service: .local, purpose: purpose, model: AppleModelInfo.id, inputTokens: i, outputTokens: o)
    }

    // MARK: Structured output

    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output {
        try ready()
        if let guided = try? GuidedSchema.make(schema) {
            do {
                let session = LanguageModelSession(model: model, instructions: system)
                let text = try await session.respond(to: user, schema: guided).content.jsonString
                await record(purpose, input: system + user, output: text)
                let read = JSONRepair.read(text, schema: schema, as: Output.self)
                if let output = read.output { return output }
                Log.info("The on-device model's guided reply did not match (\(read.problems.joined(separator: "; "))); asking with the schema in the instructions")
            } catch {
                if let mapped = Self.map(error) { throw mapped }
                Log.info("Guided generation failed on the on-device model (\(error)); asking with the schema in the instructions")
            }
        }
        return try await jsonByInstructions(system: system, user: user, schema: schema, purpose: purpose, as: Output.self)
    }

    private func jsonByInstructions<Output: Decodable>(system: String, user: String, schema: [String: Any], purpose: UsageEvent.Purpose,
                                                       as: Output.Type) async throws -> Output {
        let session = LanguageModelSession(model: model, instructions: system + "\n\n" + JSONRepair.instructions(schema))
        do {
            var text = try await session.respond(to: user).content
            await record(purpose, input: system + user, output: text)
            var read = JSONRepair.read(text, schema: schema, as: Output.self)
            if let output = read.output { return output }
            // The session keeps the first reply, so the correction follows it.
            text = try await session.respond(to: JSONRepair.correction(read.problems)).content
            read = JSONRepair.read(text, schema: schema, as: Output.self)
            guard let output = read.output else { throw SummaryError.malformed }
            return output
        } catch {
            throw Self.map(error) ?? error
        }
    }

    /// The framework's errors that the owner can act on, in Mossad's words; nil for the rest.
    static func map(_ error: Error) -> OnDeviceModelError? {
        if let e = error as? OnDeviceModelError { return e }
        if #available(macOS 27, iOS 27, *), let e = error as? LanguageModelError {
            switch e {
            case .contextSizeExceeded: return .tooLong
            case .guardrailViolation, .refusal: return .declined
            default: return nil
            }
        }
        if let e = error as? LanguageModelSession.GenerationError {
            switch e {
            case .exceededContextWindowSize: return .tooLong
            case .guardrailViolation, .refusal: return .declined
            case .assetsUnavailable: return .notReady
            default: return nil
            }
        }
        return nil
    }

    // MARK: Chat

    /// Room for one tool's output: a quarter of the context, at about 3 characters a token.
    private func toolOutputLimit() async -> Int { await contextTokens() / 4 * 3 }

    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String {
        try ready()
        let limit = await toolOutputLimit()
        let dynamic: [any Tool] = tools.compactMap { spec in
            guard let parameters = try? GuidedSchema.make(spec.schema, lenient: true) else { return nil }
            return DynamicTool(name: spec.name, description: spec.description, parameters: parameters, limit: limit, execute: execute)
        }
        // Only the last few turns: the context is small.
        let earlier = history.suffix(6).map { "\($0.role == .user ? "Owner" : "You"): \($0.text.prefix(1500))" }.joined(separator: "\n\n")
        let prompt = earlier.isEmpty ? question : "Earlier in this chat:\n\(earlier)\n\nNow: \(question)"
        let session = LanguageModelSession(model: model, tools: dynamic, instructions: system)
        do {
            let answer = try await session.respond(to: prompt).content
            await record(purpose, input: system + prompt, output: answer)
            return answer
        } catch {
            throw Self.map(error) ?? error
        }
    }
}

/// A Mossad tool as a FoundationModels tool: the arguments arrive as generated content and go to `execute` as JSON.
private struct DynamicTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let limit: Int
    let execute: @Sendable (String, [String: Any]) -> String

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        let input = (try? JSONSerialization.jsonObject(with: Data(arguments.jsonString.utf8))) as? [String: Any] ?? [:]
        let output = execute(name, input)
        guard output.count > limit else { return output }
        return String(output.prefix(limit)) + "\n[Cut short: the on-device model has a small context.]"
    }
}

/// Mossad's JSON Schema dictionaries as FoundationModels generation schemas.
enum GuidedSchema {
    struct Unsupported: Error {}

    /// The summary reads best when the overview comes first, so these keys lead; the rest follow by name.
    static let leading = ["summary", "headline", "title", "kind", "topics", "action_items", "decisions", "has_outcomes", "tags"]

    /// `lenient` turns a property of unknown shape into a string, for tool arguments; otherwise it throws.
    static func make(_ schema: [String: Any], lenient: Bool = false) throws -> GenerationSchema {
        var counter = 0
        let root = try node(schema, name: "Output", lenient: lenient, counter: &counter)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func nullable(_ s: [String: Any]) -> Bool {
        (s["anyOf"] as? [[String: Any]])?.contains { $0["type"] as? String == "null" } == true
    }

    private static func node(_ s: [String: Any], name: String, lenient: Bool, counter: inout Int) throws -> DynamicGenerationSchema {
        if let choices = s["anyOf"] as? [[String: Any]] {
            // A nullable value is an optional property; other unions do not convert.
            let concrete = choices.filter { $0["type"] as? String != "null" }
            guard concrete.count == 1 else {
                if lenient { return DynamicGenerationSchema(type: String.self) }
                throw Unsupported()
            }
            return try node(concrete[0], name: name, lenient: lenient, counter: &counter)
        }
        switch s["type"] as? String {
        case "object":
            counter += 1
            let unique = "\(name)_\(counter)"
            let properties = s["properties"] as? [String: [String: Any]] ?? [:]
            let required = Set(s["required"] as? [String] ?? [])
            let keys = properties.keys.sorted { a, b in
                let ia = leading.firstIndex(of: a) ?? leading.count, ib = leading.firstIndex(of: b) ?? leading.count
                return ia != ib ? ia < ib : a < b
            }
            var converted: [DynamicGenerationSchema.Property] = []
            for key in keys {
                let sub = properties[key]!
                converted.append(.init(name: key, description: sub["description"] as? String,
                                       schema: try node(sub, name: key, lenient: lenient, counter: &counter),
                                       isOptional: !required.contains(key) || nullable(sub)))
            }
            return DynamicGenerationSchema(name: unique, description: s["description"] as? String, properties: converted)
        case "array":
            return DynamicGenerationSchema(arrayOf: try node(s["items"] as? [String: Any] ?? ["type": "string"], name: name + "_item",
                                                         lenient: lenient, counter: &counter))
        case "string":
            if let options = s["enum"] as? [String] {
                counter += 1
                return DynamicGenerationSchema(name: "\(name)_\(counter)", anyOf: options)
            }
            return DynamicGenerationSchema(type: String.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default:
            if lenient { return DynamicGenerationSchema(type: String.self) }
            throw Unsupported()
        }
    }
}
#endif
