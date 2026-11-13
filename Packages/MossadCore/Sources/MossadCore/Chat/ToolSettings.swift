import Foundation

/// What the Chat and MCP tools read of the owner's settings: names and switches. Built from a list of allowed keys,
/// so a key, a secret, a server's address, a bucket, or an email address of the settings never reaches a tool's
/// answer. The owner's own address is read for the invite rules and never printed.
public struct ToolSettings: Sendable, Equatable {
    public var ownerEmail = ""
    /// The pairs the owner called two people on the People page, one per line.
    public var notDuplicates = ""
    public var version: String?
    public var aiProvider: AIProvider = .anthropic
    public var aiModel = ""
    public var transcriptionProvider: TranscriptionProvider = .assemblyai
    public var transcriptionModel = ""
    public var coach = false
    public var personaReads = true
    public var personaInMCP = true
    public var liveTranscript = true
    public var captureScreens = false
    public var voiceFingerprints = true
    public var sync: SyncChoice = .icloud
    /// "local" keeps the recordings on this Mac only; anything else has a backup.
    public var backup = "local"
    public var recordingDays = 90
    public var coachEmail = false
    public var googleParts: [GoogleScope] = []

    public init() {}

    public static func read(_ d: UserDefaults, bundle: Bundle = .main) -> ToolSettings {
        var s = ToolSettings()
        s.ownerEmail = d.string(forKey: "ownerEmail") ?? ""
        s.notDuplicates = d.string(forKey: "peopleNotDuplicates") ?? ""
        s.version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        s.aiProvider = d.string(forKey: "aiProvider").flatMap(AIProvider.init(rawValue:)) ?? .anthropic
        s.aiModel = d.string(forKey: "aiModel") ?? ""
        s.transcriptionProvider = d.string(forKey: "transcriptionProvider").flatMap(TranscriptionProvider.init(rawValue:)) ?? .assemblyai
        s.transcriptionModel = d.string(forKey: "transcriptionModel") ?? ""
        s.coach = d.bool(forKey: "coachEnabled")
        s.personaReads = d.object(forKey: "personaEnabled") as? Bool ?? true
        s.personaInMCP = d.object(forKey: "personaInMCP") as? Bool ?? true
        s.liveTranscript = d.object(forKey: "liveTranscript") as? Bool ?? true
        s.captureScreens = d.bool(forKey: "captureScreens")
        s.voiceFingerprints = d.object(forKey: "voiceFingerprints") as? Bool ?? true
        s.sync = d.string(forKey: "syncWith").flatMap(SyncChoice.init(rawValue:)) ?? .icloud
        s.backup = d.string(forKey: "storage") ?? "local"
        s.recordingDays = d.object(forKey: "recordingDays") as? Int ?? 90
        s.coachEmail = d.bool(forKey: "coachEmailEnabled")
        s.googleParts = (d.stringArray(forKey: "googleScopes") ?? []).compactMap(GoogleScope.init(rawValue:))
        return s
    }
}
