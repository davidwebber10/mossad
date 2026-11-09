import Foundation

/// A model with a small context window, such as Apple's on-device model. Long inputs go in parts.
public protocol ContextLimitedModel: LanguageModel {
    /// Tokens for the instructions, the prompt, and the reply together.
    func contextTokens() async -> Int
    /// The text's size in tokens: measured when the model can, otherwise a safe estimate.
    func tokenCount(_ text: String) async -> Int
}

/// Why Apple's on-device model cannot answer, in words the owner can act on. The text is also the saved
/// failure reason, so it reads back to the same case.
public enum OnDeviceModelError: Error, Equatable, CaseIterable, CustomStringConvertible, LocalizedError {
    case appleIntelligenceOff, notEligible, notReady, unsupported, tooLong, declined

    public var description: String {
        switch self {
        case .appleIntelligenceOff: "Apple Intelligence is off. Turn it on in System Settings, then try again."
        case .notEligible: "This Mac can't run Apple Intelligence. Choose another provider in Settings."
        case .notReady: "Apple's on-device model is still downloading. Mossad tries again later."
        case .unsupported: "Apple's on-device model needs a newer version of macOS. Choose another provider in Settings."
        case .tooLong: "This is too long for Apple's on-device model. Choose a cloud or local server model for it."
        case .declined: "Apple's on-device model declined this text. Choose another provider in Settings."
        }
    }

    public var errorDescription: String? { description }

    public init?(description: String) {
        guard let match = Self.allCases.first(where: { $0.description == description }) else { return nil }
        self = match
    }
}

/// The one model the "Apple on-device" provider offers.
public enum AppleModelInfo {
    public static let id = "apple-on-device"
    public static let name = "Apple on-device"
    /// The context when the system does not say: the first on-device model's size.
    static let fallbackContext = 4096

    /// The on-device model, or one that explains why there is none on this system.
    static func make(usage: UsageLog?) -> any LanguageModel {
        #if canImport(FoundationModels)
        AppleModel(usage: usage)
        #else
        UnavailableModel(error: .unsupported)
        #endif
    }

    /// Why the model cannot run now, or nil when it can.
    public static func unavailableReason() -> OnDeviceModelError? {
        #if canImport(FoundationModels)
        AppleModel.unavailableReason()
        #else
        .unsupported
        #endif
    }
}

/// Stands in where the on-device model cannot exist; every request says why.
struct UnavailableModel: ContextLimitedModel {
    let error: OnDeviceModelError

    func contextTokens() async -> Int { AppleModelInfo.fallbackContext }
    func tokenCount(_ text: String) async -> Int { ChunkPlanner.estimate(text) }
    func json<Output: Decodable>(system: String, user: String, schema: [String: Any], effort: Effort,
                                 purpose: UsageEvent.Purpose, as: Output.Type) async throws -> Output { throw error }
    func runTools(system: String, history: [ChatMessage], question: String, tools: [ToolSpec], purpose: UsageEvent.Purpose,
                  execute: @escaping @Sendable (String, [String: Any]) -> String) async throws -> String { throw error }
}
