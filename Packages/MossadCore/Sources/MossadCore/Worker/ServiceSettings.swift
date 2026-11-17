import Foundation

/// The settings a process builds its services from, with the keys and the defaults of the window app's
/// `@AppStorage` lines, and the factories that the app used to hold. The app and a worker use the same code, so a
/// worker transcribes and writes with what the window app of the same profile chose.
public struct ServiceSettings: Equatable, Sendable {
    public enum MissingKey: String, Sendable { case transcription, notes }

    /// The sync stores of this profile: the main one by the sync choice, and the server's copy while iCloud syncs.
    public struct SyncStores {
        public var main: (key: String, store: any RecordStore)?
        public var mirror: (key: String, store: any RecordStore)?
        /// The main store's key, also when its store cannot be made (no iCloud in this build, or no server).
        public var mainKey: String?
        public var place: String
        public var serverIsMain: Bool
    }

    public var ownerName: String
    public var organization: String
    public var voiceFingerprints: Bool
    public var transcriptionProvider: TranscriptionProvider
    public var transcriptionModel: String
    public var aiProvider: AIProvider
    public var aiModel: String
    public var localServerURL: String
    public var syncWith: SyncChoice
    public var serverAddress: String
    public var serverID: String
    public var serverRecordingLimit: Double
    public var backup: BackupSettings
    public var coachEnabled: Bool
    public var coachSince: Double
    public var personaEnabled: Bool
    public var personaInMCP: Bool
    public var personaSince: Double
    public var commitmentsSince: Double
    /// Nil when the owner never chose: then the Mac's calendar reads every calendar.
    public var calendarIDs: [String]?
    public var googleScopes: Set<GoogleScope>
    public var ownerEmail: String
    public var notDuplicates: [String]
    public var setupDone: Bool

    public static func read(_ d: UserDefaults, fullUserName: String) -> ServiceSettings {
        func string(_ key: String, _ fallback: String) -> String { d.string(forKey: key) ?? fallback }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        let typed = d.string(forKey: "ownerName") ?? fullUserName
        // Before the sync choice existed, turning iCloud sync off was its own switch.
        let syncWith: SyncChoice = d.string(forKey: "syncWith").flatMap(SyncChoice.init(rawValue:))
            ?? (d.object(forKey: "syncWith") == nil && d.object(forKey: "iCloudSync") as? Bool == false ? .off : .icloud)
        return ServiceSettings(
            ownerName: typed.trimmingCharacters(in: .whitespaces).isEmpty ? fullUserName : typed,
            organization: string("organization", "").trimmingCharacters(in: .whitespaces),
            voiceFingerprints: bool("voiceFingerprints", true),
            transcriptionProvider: d.string(forKey: "transcriptionProvider").flatMap(TranscriptionProvider.init(rawValue:)) ?? .assemblyai,
            transcriptionModel: string("transcriptionModel", ""),
            aiProvider: d.string(forKey: "aiProvider").flatMap(AIProvider.init(rawValue:)) ?? .anthropic,
            aiModel: string("aiModel", ""),
            localServerURL: string("localServerURL", LocalServer.ollama.absoluteString),
            syncWith: syncWith,
            serverAddress: string("serverAddress", ""),
            serverID: string("serverID", ""),
            serverRecordingLimit: d.object(forKey: "serverRecordingLimit") as? Double ?? 0,
            backup: BackupSettings(choice: string("storage", "local"), bucketKind: string("cloudBucketKind", ""), endpoint: string("cloudEndpoint", ""),
                                   bucket: string("cloudBucket", ""), region: string("cloudRegion", "us-east-1"),
                                   accessKeyID: string("cloudAccessKeyID", "")),
            coachEnabled: bool("coachEnabled", false),
            coachSince: d.object(forKey: "coachSince") as? Double ?? 0,
            personaEnabled: bool("personaEnabled", true),
            personaInMCP: bool("personaInMCP", true),
            personaSince: d.object(forKey: "personaSince") as? Double ?? 0,
            commitmentsSince: d.object(forKey: "commitmentsSince") as? Double ?? 0,
            calendarIDs: d.stringArray(forKey: "calendarIDs"),
            googleScopes: d.stringArray(forKey: "googleScopes").map { Set($0.compactMap(GoogleScope.init(rawValue:))) } ?? Set(GoogleScope.allCases),
            ownerEmail: string("ownerEmail", ""),
            notDuplicates: string("peopleNotDuplicates", "").split(separator: "\n").map(String.init),
            // Whether setup is finished: the old welcome's flag counts too.
            setupDone: d.bool(forKey: "welcomeDone") || OnboardingProgress.resume(from: d.data(forKey: "onboardingProgress")).completed)
    }

    /// The local server's address as typed, or Ollama's when it does not read as an address.
    public var localServerBase: URL { LocalServer.url(from: localServerURL) ?? LocalServer.ollama }

    /// The chosen transcriber; with no key the meeting waits for one (`MissingKeyTranscriber`).
    public func transcriber(key: (APIKey) -> String?, usage: UsageLog?) -> Transcribing {
        let provider = transcriptionProvider
        if let apiKey = provider.key {
            return key(apiKey).map { provider.transcriber(model: transcriptionModel, apiKey: $0, usage: usage) } ?? MissingKeyTranscriber(service: provider.displayName)
        }
        return provider.transcriber(model: transcriptionModel, apiKey: "", usage: usage)
    }

    /// The chosen AI model, or nil without its key (or without a picked OpenRouter or local server model).
    public func languageModel(key: (APIKey) -> String?, usage: UsageLog?) -> (any LanguageModel)? {
        let apiKey = aiProvider.key.flatMap { key($0) }
        guard apiKey != nil || !aiProvider.requiresKey, !(aiModel.isEmpty && aiProvider.defaultModel.isEmpty) else { return nil }
        return aiProvider.model(aiModel, apiKey: apiKey, usage: usage, serverURL: localServerBase)
    }

    public func summarizer(key: (APIKey) -> String?, usage: UsageLog?) -> Summarizing? {
        languageModel(key: key, usage: usage).map { LLMSummarizer(llm: $0, ownerName: ownerName, organization: organization) }
    }

    public func configuration(key: (APIKey) -> String?, usage: UsageLog?) -> Pipeline.Configuration {
        Pipeline.Configuration(transcriber: transcriber(key: key, usage: usage), summarizer: summarizer(key: key, usage: usage),
                               ownerName: ownerName, voiceFingerprints: voiceFingerprints)
    }

    /// The owner's server, when an address and a secret are both set.
    public func serverConnection(key: (APIKey) -> String?) -> ServerConnection? {
        guard let address = ServerConnection.address(from: serverAddress), let secret = key(.serverSecret) else { return nil }
        return ServerConnection(address: address, secret: secret)
    }

    /// The server answered that it keeps recordings, and named itself. A server from before that needs its update
    /// first: without its id, a recording on it cannot be told from one on another server.
    public func serverKeepsRecordings(server: ServerConnection?) -> Bool {
        server != nil && serverRecordingLimit > 0 && !serverID.isEmpty
    }

    /// Every place that is set up, with the chosen one for new recordings. A place stays readable after the owner
    /// chooses another, so the recordings in it can be played, moved, and deleted. `server` is the connection the
    /// process has (the app's preview has a made-up one).
    public func archive(key: (APIKey) -> String?, paths: Paths, server: ServerConnection?) -> CloudArchive? {
        var places: [any ArchiveBackend] = []
        if backup.hasBucket, let config = backup.bucketConfig(secret: key(.cloudSecret)) { places.append(BucketArchive(config: config)) }
        if let c = server {
            places.append(ServerArchive(c, id: serverID.isEmpty ? nil : serverID, maxBytes: serverRecordingLimit > 0 ? Int64(serverRecordingLimit) : nil))
        }
        guard !places.isEmpty else { return nil }
        let target = backup.choice == .server && !serverKeepsRecordings(server: server) ? nil : backup.choice.target
        return CloudArchive(target: target, places: places, paths: paths)
    }

    /// The stores, by the sync choice. The caller keeps one `CloudSync` for each key and makes a new one when a key
    /// changes. `iCloud` makes the iCloud store (a test gives its own: CloudKit stops a process without the entitlement).
    public func syncStores(server: ServerConnection?, hasICloud: Bool,
                           iCloud: () -> any RecordStore = { CloudKitStore() }) -> SyncStores {
        var stores = SyncStores(main: nil, mirror: nil, mainKey: nil, place: syncWith == .server ? "your server" : "iCloud",
                                serverIsMain: syncWith == .server)
        switch syncWith {
        case .icloud:
            stores.mainKey = "icloud"
            if hasICloud { stores.main = ("icloud", iCloud()) }
            // The server's copy of the meetings while iCloud syncs: only pushes, so the MCP has the meetings.
            if let c = server { stores.mirror = (c.address.absoluteString, ServerStore(c)) }
        case .server:
            let key = "server:\(server?.address.absoluteString ?? "")"
            stores.mainKey = key
            if let c = server { stores.main = (key, ServerStore(c)) }
        case .off:
            break
        }
        return stores
    }

    public func missingKeys(key: (APIKey) -> String?) -> Set<MissingKey> {
        var missing: Set<MissingKey> = []
        if let apiKey = transcriptionProvider.key, key(apiKey) == nil { missing.insert(.transcription) }
        if languageModel(key: key, usage: nil) == nil { missing.insert(.notes) }
        return missing
    }

    /// The coach's reads of people go to other AI apps by the same switch as `--mcp`.
    public var personasInMCP: Bool { MCPServer.showsPersonas(coachEnabled: coachEnabled, personaEnabled: personaEnabled, personaInMCP: personaInMCP) }
}

extension ServiceSettings.SyncStores: @unchecked Sendable {}
