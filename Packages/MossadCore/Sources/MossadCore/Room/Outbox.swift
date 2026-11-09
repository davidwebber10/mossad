import Foundation

/// The iPhone's room recordings that the Mac has not turned into meetings yet. An entry exists from the first
/// second of a recording, so a recording that the app never finished (a crash, an empty battery) is found at the
/// next launch. The audio is deleted only when the Mac's meeting for it has arrived.
public struct Outbox: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public enum State: Equatable, Sendable {
            /// The recorder writes it now, or the app stopped before it finished.
            case recording
            /// Finished and waiting to upload.
            case waiting
            /// A store took it. `store` names the store (nil for entries from before the name was kept).
            case sent(store: String?, at: Date)
        }

        /// Why a row needs a word to the owner.
        public enum Trouble: String, Codable, Sendable {
            /// The parts could not be joined yet; the app tries again.
            case notSaved
            /// A part could not be read and is kept on the iPhone; the rest was joined and sent.
            case partUnreadable
        }

        public var recording: PhoneRecording
        public var state: State
        /// Uploads a store took since the owner last asked, which limits the automatic ones.
        public var sends = 0
        public var trouble: Trouble?
        public var id: String { recording.id }

        public init(recording: PhoneRecording, state: State) {
            self.recording = recording
            self.state = state
        }

        public var isSent: Bool { if case .sent = state { true } else { false } }

        /// Whether the row offers "Send again": the store took it, and the Mac had time to write the notes.
        public func canSendAgain(now: Date) -> Bool {
            if case .sent(_, let at) = state { now.timeIntervalSince(at) >= Outbox.offerSendAgainAfter } else { false }
        }
    }

    /// A sent recording whose meeting has not come back after this long is sent again: the Mac may have failed to
    /// import it, and it ignores a recording whose call exists.
    public static let resendAfter: TimeInterval = 6 * 3600

    /// The Mac usually writes the notes within minutes of the upload; after this long the row offers "Send again".
    public static let offerSendAgainAfter: TimeInterval = 15 * 60

    /// Uploads without the owner's tap. A meeting that the Mac never makes (it skipped it, or the owner deleted it
    /// there) must not upload every few hours for ever; the audio and "Send again" stay.
    public static let automaticSends = 3

    public private(set) var entries: [Entry]

    public init(_ entries: [Entry] = []) { self.entries = entries }

    public subscript(id: String) -> Entry? { entries.first { $0.id == id } }

    public mutating func begin(_ recording: PhoneRecording) {
        entries.removeAll { $0.id == recording.id }
        entries.append(Entry(recording: recording, state: .recording))
    }

    /// The recording is finished on disk and can upload.
    public mutating func finish(_ id: String, end: Date, title: String?) {
        update(id) {
            $0.recording.end = max(end, $0.recording.start)
            if let title { $0.recording.title = title }
            $0.state = .waiting
            $0.trouble = nil
        }
    }

    /// The name the owner types during the recording, kept so a recording the app never finished still has it.
    public mutating func retitle(_ id: String, _ title: String?) {
        update(id) { $0.recording.title = title }
    }

    public mutating func setTrouble(_ id: String, _ trouble: Entry.Trouble?) {
        update(id) { $0.trouble = trouble }
    }

    public mutating func markSent(_ id: String, store: String, at: Date) {
        update(id) {
            $0.state = .sent(store: store, at: at)
            $0.sends += 1
        }
    }

    /// The owner's "Send again".
    public mutating func sendAgain(_ id: String) {
        update(id) {
            guard $0.isSent else { return }
            $0.state = .waiting
            $0.sends = 0
        }
    }

    public mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }

    /// Whether the owner may remove a row with its audio: never the recording in progress, and not while the row
    /// uploads or its parts are joined (`busy`). Only the owner removes; nothing does it automatically.
    public func canRemove(_ id: String, active: String?, busy: Set<String>) -> Bool {
        self[id] != nil && id != active && !busy.contains(id)
    }

    /// The entries to upload to `store` now: the waiting ones, and the sent ones that went to another store or whose
    /// meeting has not come back in time.
    public func due(store: String, now: Date) -> [Entry] {
        entries.filter { e in
            switch e.state {
            case .recording: false
            case .waiting: true
            case .sent(let to, let at):
                (to != nil && to != store) || (e.sends < Self.automaticSends && now.timeIntervalSince(at) >= Self.resendAfter)
            }
        }
    }

    /// Removes the entries whose meeting arrived, and returns their ids so the app deletes their audio. A finished
    /// entry counts even when it is not marked sent: the upload may have worked just before the app stopped.
    public mutating func settle(arrived: Set<String>) -> [String] {
        // The Mac imports a recording as `<id>-iphone` when one of its own calls started in the same second.
        let done = entries.filter { $0.state != .recording && (arrived.contains($0.id) || arrived.contains($0.id + "-iphone")) }.map(\.id)
        entries.removeAll { done.contains($0.id) }
        return done
    }

    /// The recordings to recover at launch: entries still `recording` that are not the one recording now, and audio
    /// on disk with no entry at all.
    public func needsRecovery(audioIDs: Set<String>, active: String?) -> [String] {
        let known = Set(entries.map(\.id))
        let unfinished = entries.filter { $0.state == .recording && $0.id != active }.map(\.id)
        let orphans = audioIDs.subtracting(known).subtracting([active].compactMap { $0 }).sorted()
        return unfinished + orphans
    }

    /// Entries with no audio on disk, apart from the recording in progress: nothing can upload or recover them.
    public func withoutAudio(audioIDs: Set<String>, active: String?) -> [String] {
        entries.map(\.id).filter { $0 != active && !audioIDs.contains($0) }
    }

    private mutating func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[i])
    }

    // MARK: File

    public static let fileName = "outbox.json"

    /// A missing file is an empty outbox; a file that cannot be read throws, so it is never replaced in silence.
    public static func load(from file: URL) throws -> Outbox {
        guard FileManager.default.fileExists(atPath: file.path) else { return Outbox() }
        return Outbox(try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file)))
    }

    public func save(to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
    }

    /// Loads the outbox; a file that cannot be read moves aside as `outbox.unreadable-<date>.json` and the outbox
    /// starts empty, for the launch scan to fill from the audio on disk.
    public static func loadOrSetAside(from file: URL, now: Date = Date()) -> (outbox: Outbox, setAside: URL?) {
        do {
            return (try load(from: file), nil)
        } catch {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let aside = file.deletingLastPathComponent()
                .appendingPathComponent("\(file.deletingPathExtension().lastPathComponent).unreadable-\(f.string(from: now)).json")
            try? FileManager.default.moveItem(at: file, to: aside)
            return (Outbox(), aside)
        }
    }
}

extension Outbox.Entry.State: Codable {
    private enum Keys: String, CodingKey { case state, store, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "recording": self = .recording
        case "waiting": self = .waiting
        default: self = .sent(store: try c.decodeIfPresent(String.self, forKey: .store), at: try c.decode(Date.self, forKey: .at))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .recording: try c.encode("recording", forKey: .state)
        case .waiting: try c.encode("waiting", forKey: .state)
        case .sent(let store, let at):
            try c.encode("sent", forKey: .state)
            try c.encodeIfPresent(store, forKey: .store)
            try c.encode(at, forKey: .at)
        }
    }
}

extension Outbox.Entry {
    private enum Keys: String, CodingKey { case recording, state, sent, sends, trouble }

    /// Reads the older entries too, which had only `sent`; those count as sent now, to the store in use.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        recording = try c.decode(PhoneRecording.self, forKey: .recording)
        if let state = try c.decodeIfPresent(State.self, forKey: .state) {
            self.state = state
        } else {
            self.state = try c.decodeIfPresent(Bool.self, forKey: .sent) == true ? .sent(store: nil, at: Date()) : .waiting
        }
        sends = try c.decodeIfPresent(Int.self, forKey: .sends) ?? (isSent ? 1 : 0)
        trouble = try? c.decodeIfPresent(Trouble.self, forKey: .trouble)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(recording, forKey: .recording)
        try c.encode(state, forKey: .state)
        try c.encode(sends, forKey: .sends)
        try c.encodeIfPresent(trouble, forKey: .trouble)
    }
}
