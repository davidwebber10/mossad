import Foundation

/// The anonymous usage statistics, version 1: counts and fixed words only. Every string is a fixed choice, the
/// random install id, a version, the locale, or the chip family, so no name, title, address, path, call id, or
/// key can get in, whatever the records hold. The receiver reads exactly this shape; a change raises `v`.
public struct UsageStats: Codable, Equatable, Sendable {
    public static let version = 1

    public var v: Int
    public var installID: String
    public var appVersion: String
    public var build: Int
    public var os: String
    public var chip: String
    public var locale: String
    public var daysActive7: Int
    public var meetings7: Int
    public var meetingMinutes7: Int
    public var platforms7: Platforms
    public var providers: Providers
    public var features: Features
    public var counts: Counts
    public var errors7: Errors

    public struct Platforms: Codable, Equatable, Sendable {
        public var zoom = 0, meet = 0, teams = 0, inPerson = 0, geminiNotes = 0
        public init(zoom: Int = 0, meet: Int = 0, teams: Int = 0, inPerson: Int = 0, geminiNotes: Int = 0) {
            self.zoom = zoom; self.meet = meet; self.teams = teams; self.inPerson = inPerson; self.geminiNotes = geminiNotes
        }
    }

    public struct Providers: Codable, Equatable, Sendable {
        public var transcription: String
        public var summary: String
        public init(transcription: String, summary: String) { self.transcription = transcription; self.summary = summary }
    }

    public struct Features: Codable, Equatable, Sendable {
        public var coach, screens, google, server, iphone, backup, mcp, shares: Bool
        public init(coach: Bool, screens: Bool, google: Bool, server: Bool, iphone: Bool, backup: Bool, mcp: Bool, shares: Bool) {
            self.coach = coach; self.screens = screens; self.google = google; self.server = server
            self.iphone = iphone; self.backup = backup; self.mcp = mcp; self.shares = shares
        }
    }

    public struct Counts: Codable, Equatable, Sendable {
        public var people: String
        public var recurring: String
        public var commitmentsOpen: String
    }

    public struct Errors: Codable, Equatable, Sendable {
        public var transcribe = 0, identify = 0, summarize = 0, write = 0, detect = 0
        public init(transcribe: Int = 0, identify: Int = 0, summarize: Int = 0, write: Int = 0, detect: Int = 0) {
            self.transcribe = transcribe; self.identify = identify; self.summarize = summarize; self.write = write; self.detect = detect
        }
    }

    /// The kinds of failure counted in `errors7`.
    public enum Step: String, Codable, CaseIterable, Sendable {
        case transcribe, identify, summarize, write
        /// A call that Mossad could not confirm, or a recording that lost one side of the call.
        case detect

        /// The step that failed when a call stopped at `status`.
        public init?(failedAt status: CallStatus) {
            switch status {
            case .recorded: self = .transcribe
            case .transcribed: self = .identify
            case .identified: self = .summarize
            case .summarized: self = .write
            case .recording, .written, .failed: return nil
            }
        }
    }

    /// What the app knows, as it knows it. `make` reduces it to the payload.
    public struct Input: Sendable {
        public var installID: UUID
        public var appVersion: String
        public var build: String
        public var os: OperatingSystemVersion
        public var cpuBrand: String?
        public var language: String?
        public var region: String?
        public var records: [CallRecord]
        public var counters: UsageCounters
        /// Nil when no transcription can run (a provider without its key).
        public var transcription: TranscriptionProvider?
        /// Nil when no summary can run.
        public var summary: AIProvider?
        public var features: Features
        public var people: Int
        public var recurring: Int
        public var commitmentsOpen: Int

        public init(installID: UUID, appVersion: String, build: String, os: OperatingSystemVersion, cpuBrand: String?, language: String?,
                    region: String?, records: [CallRecord], counters: UsageCounters, transcription: TranscriptionProvider?,
                    summary: AIProvider?, features: Features, people: Int, recurring: Int, commitmentsOpen: Int) {
            self.installID = installID; self.appVersion = appVersion; self.build = build; self.os = os; self.cpuBrand = cpuBrand
            self.language = language; self.region = region; self.records = records; self.counters = counters
            self.transcription = transcription; self.summary = summary; self.features = features
            self.people = people; self.recurring = recurring; self.commitmentsOpen = commitmentsOpen
        }
    }

    static let maxMeetings = 500
    static let maxMinutes = 20_000
    static let maxErrors = 1_000

    public static func make(_ i: Input, now: Date = Date(), calendar: Calendar = .current) -> UsageStats {
        let since = now.addingTimeInterval(-7 * 86_400)
        let week = i.records.filter { $0.status != .recording && $0.start >= since && $0.start <= now }
        var platforms = Platforms()
        var minutes = 0.0
        for r in week {
            if r.isNotesOnly {
                platforms.geminiNotes += 1
                continue
            }
            minutes += max(0, r.end.timeIntervalSince(r.start)) / 60
            switch r.platform {
            case .zoom: platforms.zoom += 1
            case .meet: platforms.meet += 1
            case .teams: platforms.teams += 1
            case .inPerson: platforms.inPerson += 1
            }
        }
        let cap = { (n: Int) in min(max(n, 0), maxMeetings) }
        platforms = Platforms(zoom: cap(platforms.zoom), meet: cap(platforms.meet), teams: cap(platforms.teams),
                              inPerson: cap(platforms.inPerson), geminiNotes: cap(platforms.geminiNotes))
        let errors = i.counters.errors7(now: now, calendar: calendar)
        let e = { (s: Step) in min(max(errors[s] ?? 0, 0), maxErrors) }
        return UsageStats(
            v: version,
            installID: i.installID.uuidString.lowercased(),
            appVersion: versionText(i.appVersion),
            build: Int(i.build).map { min(max($0, 0), 10_000_000) } ?? 0,
            os: "\(min(max(i.os.majorVersion, 0), 999)).\(min(max(i.os.minorVersion, 0), 999))",
            chip: chipFamily(i.cpuBrand),
            locale: localeTag(language: i.language, region: i.region),
            daysActive7: min(max(i.counters.daysActive7(now: now, calendar: calendar), 0), 7),
            meetings7: cap(week.count),
            meetingMinutes7: min(Int(minutes.rounded()), maxMinutes),
            platforms7: platforms,
            providers: Providers(transcription: i.transcription?.rawValue ?? "none", summary: i.summary?.rawValue ?? "none"),
            features: i.features,
            counts: Counts(people: bucket(i.people), recurring: bucket(i.recurring), commitmentsOpen: bucket(i.commitmentsOpen)),
            errors7: Errors(transcribe: e(.transcribe), identify: e(.identify), summarize: e(.summarize), write: e(.write), detect: e(.detect)))
    }

    /// A count as a range, so a number never singles out one person's library.
    public static func bucket(_ n: Int) -> String {
        switch n {
        case ...0: "0"
        case 1...5: "1-5"
        case 6...20: "6-20"
        case 21...100: "21-100"
        default: "100+"
        }
    }

    /// "M3" from "Apple M3 Pro": the family only. Any other chip is "other".
    public static func chipFamily(_ brand: String?) -> String {
        guard let brand, let match = brand.firstMatch(of: /\bM([0-9]+)\b/), let n = Int(match.1), (1...5).contains(n) else { return "other" }
        return "M\(n)"
    }

    /// "2.20.0", or "0" when the text is anything but a version.
    static func versionText(_ text: String) -> String {
        text.wholeMatch(of: /[0-9]{1,4}(\.[0-9]{1,4}){0,3}/) != nil ? text : "0"
    }

    /// "en-US", "fr", or "und" when the language is not a plain language code.
    static func localeTag(language: String?, region: String?) -> String {
        guard let language = language?.lowercased(), language.wholeMatch(of: /[a-z]{2,3}/) != nil else { return "und" }
        guard let region = region?.uppercased(), region.wholeMatch(of: /[A-Z]{2}/) != nil else { return language }
        return "\(language)-\(region)"
    }

    /// The body that is sent, with its keys in one order. Pretty for the "What is sent" sheet.
    public func json(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
