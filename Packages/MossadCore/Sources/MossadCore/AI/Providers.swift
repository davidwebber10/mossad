import Foundation

public enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case anthropic, openai, openrouter

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        }
    }
    public var key: APIKey {
        switch self {
        case .anthropic: .anthropic
        case .openai: .openai
        case .openrouter: .openrouter
        }
    }
    /// The model used until one is picked. OpenRouter has hundreds, so it waits for a choice.
    public var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-6.1-sol"
        case .openrouter: ""
        }
    }

    public func model(_ name: String, apiKey: String, usage: UsageLog?) -> any LanguageModel {
        let name = name.isEmpty ? defaultModel : name
        return switch self {
        case .anthropic: AnthropicModel(apiKey: apiKey, model: name, usage: usage)
        case .openai: OpenAIModel(apiKey: apiKey, model: name, usage: usage)
        case .openrouter: OpenRouterModel(apiKey: apiKey, model: name, usage: usage)
        }
    }
}

public enum TranscriptionProvider: String, CaseIterable, Sendable, Identifiable {
    case assemblyai, deepgram, elevenlabs, openai, local

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .assemblyai: "AssemblyAI"
        case .deepgram: "Deepgram"
        case .elevenlabs: "ElevenLabs"
        case .openai: "OpenAI"
        case .local: "Local (on this Mac)"
        }
    }
    /// Nil for the local models, which need no key.
    public var key: APIKey? {
        switch self {
        case .assemblyai: .assemblyai
        case .deepgram: .deepgram
        case .elevenlabs: .elevenlabs
        case .openai: .openai
        case .local: nil
        }
    }
    /// Each provider's models that label speakers, first one the default.
    public var models: [ModelInfo] {
        switch self {
        case .assemblyai: [ModelInfo(id: "", name: "Universal (default)")]
        case .deepgram: [ModelInfo(id: "nova-3", name: "Nova-3"), ModelInfo(id: "nova-2-meeting", name: "Nova-2 Meeting")]
        case .elevenlabs: [ModelInfo(id: "scribe_v2", name: "Scribe v2")]
        case .openai: [ModelInfo(id: "gpt-4o-transcribe-diarize", name: "GPT-4o Transcribe Diarize")]
        case .local: [ModelInfo(id: "parakeet-tdt-v3", name: "Parakeet TDT v3")]
        }
    }
    /// What a person should know before picking it.
    public var note: String {
        switch self {
        case .assemblyai: "About $0.23 an hour of audio. Words, speakers, and filler words."
        case .deepgram: "About $0.26 an hour of audio. Words, speakers, and filler words."
        case .elevenlabs: "About $0.22 an hour of audio. Words and speakers."
        case .openai: "About $0.36 an hour. No word times, so interjections land less exactly. OpenAI retires this model on Feb 26, 2027. Tracks over about 2 hours are too large."
        case .local: "Free, and the audio never leaves this Mac. About 300 times faster than real time. Weaker on product names. The models download once, about 1 GB."
        }
    }

    public func transcriber(model: String, apiKey: String, usage: UsageLog?) -> Transcribing {
        let model = model.isEmpty ? (models.first?.id ?? "") : model
        return switch self {
        case .assemblyai: AssemblyAIClient(apiKey: apiKey, usage: usage)
        case .deepgram: DeepgramTranscriber(apiKey: apiKey, model: model, usage: usage)
        case .elevenlabs: ElevenLabsTranscriber(apiKey: apiKey, model: model, usage: usage)
        case .openai: OpenAITranscriber(apiKey: apiKey, model: model, usage: usage)
        case .local: LocalTranscriber()
        }
    }
}
