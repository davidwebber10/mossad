import Foundation

public enum AIProvider: String, CaseIterable, Sendable, Identifiable {
    case anthropic, openai, openrouter
    /// An OpenAI-compatible server the owner runs, such as Ollama or LM Studio.
    case localServer
    /// Apple's on-device model, through the FoundationModels framework.
    case apple

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .localServer: "Local server"
        case .apple: "Apple on-device"
        }
    }
    /// The key in the Keychain: required for the cloud providers, optional for a local server, none for Apple.
    public var key: APIKey? {
        switch self {
        case .anthropic: .anthropic
        case .openai: .openai
        case .openrouter: .openrouter
        case .localServer: .localServer
        case .apple: nil
        }
    }
    public var requiresKey: Bool { !isLocal }
    /// Runs without a cloud service: nothing is billed and no key is needed.
    public var isLocal: Bool { self == .localServer || self == .apple }

    /// What a person should know before picking it, when there is more to say than the model's rating.
    public var note: String? {
        switch self {
        case .anthropic, .openai, .openrouter: nil
        case .localServer: "Free. Meeting text goes only to the server address below. Quality and speed depend on the model."
        case .apple: "Apple on-device: free and private, lower quality, slower on long meetings. It needs Apple Intelligence."
        }
    }

    /// The model used until one is picked. OpenRouter and a local server have many, so they wait for a choice.
    public var defaultModel: String {
        switch self {
        case .anthropic: "claude-opus-5-5"
        case .openai: "gpt-6.1-sol"
        case .openrouter, .localServer: ""
        case .apple: AppleModelInfo.id
        }
    }

    /// A cheap model for short jobs such as a provisional title; nil when the provider has no known small
    /// model, and the chosen model is used instead.
    public var smallModel: String? {
        switch self {
        case .anthropic: "claude-haiku-5-5"
        case .openai, .openrouter, .localServer, .apple: nil
        }
    }

    /// The model for a question during a call, which must answer in seconds: on Anthropic a Haiku or Sonnet choice
    /// stays and any larger one (Opus, Fable) steps down to Sonnet; elsewhere the choice.
    public func liveChatModel(_ chosen: String) -> String {
        guard self == .anthropic else { return chosen }
        let id = chosen.isEmpty ? defaultModel : chosen
        return id.contains("haiku") || id.contains("sonnet") ? id : "claude-sonnet-5-5"
    }

    /// `serverURL` is the local server's address; the other providers ignore it.
    public func model(_ name: String, apiKey: String?, usage: UsageLog?, serverURL: URL = LocalServer.ollama,
                      cache: LatestModelCache = .shared, session: URLSession = .shared) -> any LanguageModel {
        let name = resolvedModel(name, cache: cache)
        let key = apiKey ?? ""
        return switch self {
        case .anthropic: AnthropicModel(apiKey: key, model: name, session: session, usage: usage)
        case .openai: OpenAIModel(apiKey: key, model: name, session: session, usage: usage)
        case .openrouter: OpenRouterModel(apiKey: key, model: name, session: session, usage: usage)
        case .localServer: LocalServerModel(baseURL: serverURL, model: name, apiKey: apiKey, session: session, usage: usage)
        case .apple: AppleModelInfo.make(usage: usage)
        }
    }
}


public enum AssemblyAIModel {
    public static let stt37 = "assemblyai-stt-3-7"

    /// The id when the list has it; else "" (the account's default), so a value left from another provider is never sent.
    static func known(_ id: String) -> String {
        TranscriptionProvider.assemblyai.models.contains { $0.id == id } ? id : ""
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
        // "" sends no model, so the account's default runs; AssemblyAI changes that default over time.
        case .assemblyai: [ModelInfo(id: "", name: "Account default"), ModelInfo(id: AssemblyAIModel.stt37, name: "AssemblyAI-STT-3.7")]
        case .deepgram: [ModelInfo(id: "nova-3", name: "Nova-3"), ModelInfo(id: "nova-2-meeting", name: "Nova-2 Meeting")]
        case .elevenlabs: [ModelInfo(id: "scribe_v2", name: "Scribe v2")]
        case .openai: [ModelInfo(id: "gpt-4o-transcribe-diarize", name: "GPT-4o Transcribe Diarize")]
        case .local: LocalModel.allCases.map(\.info)
        }
    }
    /// What a person should know before picking it.
    public var note: String {
        switch self {
        case .assemblyai: note(model: "")
        case .deepgram: "About $0.26 an hour of audio. Words, speakers, and filler words."
        case .elevenlabs: "About $0.22 an hour of audio. Words and speakers."
        case .openai: "About $0.36 an hour. No word times, so interjections land less exactly. OpenAI retires this model on Feb 26, 2027. Tracks over about 2 hours are too large."
        case .local: LocalModel.parakeetV3.note
        }
    }

    /// The note for one of the provider's models. Only the local models differ enough to need their own.
    public func note(model: String) -> String {
        switch self {
        case .local: LocalModel(id: model).note
        case .assemblyai: AssemblyAIModel.known(model) == AssemblyAIModel.stt37
            ? "About $0.23 an hour of audio. Words, speakers, and filler words, with repetitions and false starts."
            : "Your AssemblyAI account's default model: about $0.17 to $0.23 an hour of audio. Words, speakers, and filler words."
        default: note
        }
    }

    public func transcriber(model: String, apiKey: String, usage: UsageLog?) -> Transcribing {
        let model = model.isEmpty ? (models.first?.id ?? "") : model
        return switch self {
        case .assemblyai: AssemblyAIClient(apiKey: apiKey, model: AssemblyAIModel.known(model), usage: usage)
        case .deepgram: DeepgramTranscriber(apiKey: apiKey, model: model, usage: usage)
        case .elevenlabs: ElevenLabsTranscriber(apiKey: apiKey, model: model, usage: usage)
        case .openai: OpenAITranscriber(apiKey: apiKey, model: model, usage: usage)
        case .local: LocalTranscriber(model: LocalModel(id: model))
        }
    }
}
