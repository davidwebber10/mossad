import Foundation

/// A call recording that the owner shares to the iPhone app, such as the audio of a phone call from Notes: what the
/// phone reads of the file, and the rules that make it a recording for the Mac.
public enum CallImport {
    /// The meeting's name when the owner gives none.
    public static let placeholder = "Phone call"
    /// Lowercase names that say nothing, after digits and punctuation are taken away.
    static let emptyNames: Set<String> = ["recording", "audio", "new recording"]

    /// The file name without its extension, or "" when the name says nothing: only digits and punctuation, or one of
    /// `emptyNames` with any number after it.
    public static func title(fileName: String) -> String {
        let bare = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = String(bare.lowercased().map { $0.isLetter ? $0 : " " }).split(separator: " ").joined(separator: " ")
        return words.isEmpty || emptyNames.contains(words) ? "" : bare
    }

    // MARK: The start

    /// What a date of the file stands for.
    public enum DateMeaning: Sendable { case start, end, share }
    /// The rule for a handed call recording: the audio's own creation date is the start of the call, and the file's
    /// date is the moment of the share. Two guards read a metadata date as the share as well (see `start`).
    public static let metadataDate: DateMeaning = .start
    public static let fileDate: DateMeaning = .share
    /// A metadata date this close before the import can be a copy that was written for the share.
    static let shareWindow: TimeInterval = 120

    public struct Start: Equatable, Sendable {
        public var date: Date
        /// False when no date of the file gives the start: the owner should check it.
        public var sure: Bool
        public init(date: Date, sure: Bool) {
            self.date = date
            self.sure = sure
        }
    }

    /// The start of the call, cut to the whole second. A sure start from the metadata date, else from the file date;
    /// with neither, the share time minus the length, not sure. A date after `now` or before 2001 is no date. A start date whose end is after `now`, or a metadata
    /// date of the last `shareWindow` seconds, is read as the share time.
    public static func start(metadata: Date?, file: Date?, length: TimeInterval, now: Date,
                             metadataIs: DateMeaning = metadataDate, fileIs: DateMeaning = fileDate) -> Start {
        func read(_ date: Date?, as meaning: DateMeaning, recent: Bool) -> Start? {
            // A date after now, or before 2001 (an MPEG-4 header with no date reads as 1904), says nothing.
            guard let date, date <= now, date >= earliest else { return nil }
            var meaning = meaning
            if meaning == .start && date.addingTimeInterval(length) > now { meaning = .share }
            if recent, (0...shareWindow).contains(now.timeIntervalSince(date)) { meaning = .share }
            switch meaning {
            case .start: return Start(date: whole(date), sure: true)
            case .end: return Start(date: whole(date.addingTimeInterval(-length)), sure: true)
            case .share: return Start(date: whole(date.addingTimeInterval(-length)), sure: false)
            }
        }
        let found = [read(metadata, as: metadataIs, recent: true), read(file, as: fileIs, recent: false)].compactMap { $0 }
        return found.first(where: \.sure) ?? found.first ?? Start(date: whole(now.addingTimeInterval(-length)), sure: false)
    }

    /// Before this, a file date is a default and not a time: 2001-01-01.
    static let earliest = Date(timeIntervalSinceReferenceDate: 0)

    static func whole(_ date: Date) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    // MARK: The plan

    public enum Refusal: Error, Equatable, Sendable {
        case unreadable, tooShort, duplicate

        public var message: String {
            switch self {
            case .unreadable: "Mossad cannot read this audio file."
            case .tooShort: "This recording is shorter than a minute. Mossad does not keep a recording that short."
            case .duplicate: "This recording is already in Mossad."
            }
        }
    }

    /// A person the owner can say was on the call: a saved person with an id, or a name alone.
    public struct Choice: Equatable, Sendable, Hashable {
        public var name: String
        public var personID: String?
        public init(name: String, personID: String?) {
            self.name = name
            self.personID = personID
        }
    }

    /// A recording that the iPhone already has: one in the outbox, or a meeting from the Mac.
    public struct Known: Equatable, Sendable {
        public var id: String
        public var start: Date
        public var end: Date
        public init(id: String, start: Date, end: Date) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    /// What the import screen holds when the owner taps to add.
    public struct Draft: Equatable, Sendable {
        public var file: File
        public var title: String
        public var start: Date
        public var person: Choice?
        public init(file: File, title: String, start: Date, person: Choice?) {
            self.file = file
            self.title = title
            self.start = start
            self.person = person
        }
    }

    /// What to save: a recording of whole seconds, with `title` nil when blank.
    public struct Plan: Equatable, Sendable {
        public var id: String
        public var start: Date
        public var end: Date
        public var title: String?
        public var person: Choice?
        public var convert: Bool
        public init(id: String, start: Date, end: Date, title: String?, person: Choice?, convert: Bool) {
            self.id = id
            self.start = start
            self.end = end
            self.title = title
            self.person = person
            self.convert = convert
        }
    }

    /// The one rule that the screen and the Shortcuts action run. `hash` is nil when the file could not be hashed.
    /// `outbox` and `meetings` are what the iPhone has: the recordings that wait, and the meetings from the Mac.
    public static func plan(_ draft: Draft, hash: String?, outbox: [Known], meetings: [Known],
                            memory: ImportMemory, now: Date) -> Result<Plan, Refusal> {
        guard let fileLength = draft.file.length else { return .failure(.unreadable) }
        guard fileLength >= ProcessingQueue.minimumCallDuration else { return .failure(.tooShort) }
        let length = fileLength.rounded()
        let latest = whole(now).addingTimeInterval(-length)
        var start = min(whole(draft.start), latest)

        let known = outbox + meetings
        let ids = Set(known.map { bare($0.id) })
        if let hash, let id = memory.id(of: hash), ids.contains(id) { return .failure(.duplicate) }
        if known.contains(where: { whole($0.start) == start && $0.end.timeIntervalSince($0.start).rounded() == length }) {
            return .failure(.duplicate)
        }

        // Another recording at this second: the next free second, or the one before when that would end after now.
        let first = start
        while ids.contains(CallID.make(start)) { start = start.addingTimeInterval(1) }
        if start > latest {
            start = first
            while ids.contains(CallID.make(start)) { start = start.addingTimeInterval(-1) }
        }

        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Plan(id: CallID.make(start), start: start, end: start.addingTimeInterval(length),
                             title: title.isEmpty ? nil : title, person: draft.person,
                             convert: converts(typeIdentifier: draft.file.typeIdentifier, bytes: draft.file.bytes, length: fileLength)))
    }

    /// A meeting from a phone recording has the id of the recording with "-iphone" after it.
    static func bare(_ id: String) -> String { id.hasSuffix("-iphone") ? String(id.dropLast("-iphone".count)) : id }

    /// MPEG-4 audio goes as it is unless it is more than 4 times the bytes of a room recording of that length.
    /// Any other file, or one whose type or size is not known, becomes AAC.
    public static func converts(typeIdentifier: String?, bytes: Int64?, length: TimeInterval) -> Bool {
        guard let typeIdentifier, ["com.apple.m4a-audio", "public.mpeg-4-audio"].contains(typeIdentifier), let bytes else { return true }
        return Double(bytes) > 16_000 * length
    }

    // MARK: The person

    /// The people the owner can pick, by name. With saved people on the phone, the live ones who are not the owner
    /// that match `query` by name or address; else the named speakers of the meetings without the owner, with no id.
    public static func choices(query: String, people: [Person], heard: [String], owner: String) -> [Choice] {
        let search = ListSearch(query)
        if !people.isEmpty {
            return people
                .filter { $0.isLive && !$0.isOwner }
                .filter { search.match(title: $0.displayName, fields: $0.emails.map { ListField("Email", $0.address) }) != nil }
                .map { Choice(name: $0.displayName, personID: $0.id.rawValue) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let ownerKey = PersonNames.key(owner)
        var seen = Set<String>()
        return heard
            .filter { PersonNames.key($0) != ownerKey && search.match(title: $0, fields: []) != nil }
            .filter { seen.insert(PersonNames.key($0)).inserted }
            .map { Choice(name: $0, personID: nil) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The person for a typed name: the one choice with that name, else the name alone; nil when blank. Two saved
    /// people with that name are nobody: the name goes with no id.
    public static func typed(_ text: String, among choices: [Choice]) -> Choice? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let key = PersonNames.key(name)
        let same = choices.filter { PersonNames.key($0.name) == key }
        return same.count == 1 ? same[0] : Choice(name: name, personID: nil)
    }

    /// The Shortcuts action's answer.
    public static func resultWords(sent: Bool) -> String {
        sent ? "Added to Mossad." : "Added. Mossad sends it when you next open the app."
    }
}
