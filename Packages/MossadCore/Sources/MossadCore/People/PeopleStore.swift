import Foundation

/// One line of `people-log.jsonl`: what changed on a person, so a later build can show the history and undo.
/// The log is evidence, not the store.
public struct PeopleLogEntry: Codable, Equatable, Sendable {
    public var id = UUID()
    public var at: Date
    /// "create", "rename", "email", "merge", "delete", "ownerName", or "migrate".
    public var kind: String
    /// "owner", "migration", or "voices" for a change that followed the voice library.
    public var actor: String
    /// The person's id.
    public var subject: String
    /// The other person of a merge.
    public var other: String?
    public var before: String?
    public var after: String?

    public init(at: Date, kind: String, actor: String, subject: PersonID, other: PersonID? = nil, before: String? = nil, after: String? = nil) {
        self.at = at
        self.kind = kind
        self.actor = actor
        self.subject = subject.rawValue
        self.other = other?.rawValue
        self.before = before
        self.after = after
    }
}

/// The store was written by a newer build. This build reads it and does not save.
public struct NewerPeopleFile: Error, CustomStringConvertible {
    public let version: Int
    public var description: String { "people.json is from a newer Mossad (version \(version)); this build does not change it" }
}

/// The people, in `~/Mossad/People/people.json`. One whole file for each save. Only the main Mac app writes it.
///
/// In this phase the voice library (`voices.json`) is still what the app reads. This store follows it: each
/// person has an id that stays through a rename, and keeps each written form and address.
public final class PeopleStore: @unchecked Sendable {
    public static let fileName = "people.json"
    public static let logName = "people-log.jsonl"
    public static let currentVersion = 1

    private struct File: Codable {
        var version: Int
        var people: [Person]

        init(version: Int, people: [Person]) {
            self.version = version
            self.people = people
        }

        enum CodingKeys: String, CodingKey { case version, people }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        }
    }

    private struct VersionOnly: Decodable { var version: Int? }

    private let url: URL
    private let logURL: URL
    private let lock = NSLock()
    private var storage: [Person]
    private var onDisk: Bool
    private let now: @Sendable () -> Date

    /// Set when `people.json` was there and could not be read; a damaged file is moved aside first.
    public let loadError: Error?
    /// True for a file from a newer build: it is read, and never saved.
    public let isReadOnly: Bool
    /// The name of the copy when the file could not be read and was set aside. The store then saves nothing.
    public let setAside: String?
    private let newerVersion: Int?

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        url = directory.appendingPathComponent(Self.fileName)
        logURL = directory.appendingPathComponent(Self.logName)
        self.now = now
        onDisk = FileManager.default.fileExists(atPath: url.path)
        // Newer is not unreadable: a file with a higher version is never moved aside and never replaced.
        if let data = try? Data(contentsOf: url), let v = Self.version(of: data), v > Self.currentVersion {
            isReadOnly = true
            newerVersion = v
            setAside = nil
            do {
                storage = try JSONDecoder.callRecord.decode(File.self, from: data).people
                loadError = nil
            } catch {
                storage = []
                loadError = error
            }
            return
        }
        isReadOnly = false
        newerVersion = nil
        let marker = Self.marker(in: directory)
        do {
            if let people = try StoredFile.load(File.self, from: url, decoder: .callRecord)?.people {
                storage = people
                loadError = nil
                setAside = nil
                // The file is back and reads.
                try? FileManager.default.removeItem(at: marker)
            } else if let kept = try? String(contentsOf: marker, encoding: .utf8) {
                // The file is gone because an earlier start set it aside. That is not "no people yet".
                storage = []
                setAside = kept
                loadError = UnreadableFile(url: url, kept: nil, reason: "it was set aside as \(kept)")
            } else {
                storage = []
                loadError = nil
                setAside = nil
            }
        } catch {
            // Unreadable is not empty. A new file would give each person a new id, so no save is made until the file
            // is back or the owner starts again.
            storage = []
            loadError = error
            onDisk = FileManager.default.fileExists(atPath: url.path)
            setAside = (error as? UnreadableFile)?.kept?.lastPathComponent
            if let setAside { try? Data(setAside.utf8).write(to: marker, options: .atomic) }
        }
    }

    /// The note that `people.json` was set aside, with the name of the copy. While it is there and the file is
    /// not, the store makes no new file.
    static func marker(in directory: URL) -> URL { directory.appendingPathComponent("people.set-aside") }

    /// The name of the copy, when `people.json` could not be read and was set aside, now or at an earlier start.
    public static func setAside(in directory: URL) -> String? {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path) else { return nil }
        return try? String(contentsOf: marker(in: directory), encoding: .utf8)
    }

    // MARK: Reading

    /// The people for code that only looks: nil when there is no file or it does not decode. Unlike the store, it
    /// never moves a damaged file aside.
    public static func peek(in directory: URL) -> [Person]? {
        (try? Data(contentsOf: directory.appendingPathComponent(fileName))).flatMap(decode)
    }

    static func decode(_ data: Data) -> [Person]? { (try? JSONDecoder.callRecord.decode(File.self, from: data))?.people }
    static func version(of data: Data) -> Int? { (try? JSONDecoder().decode(VersionOnly.self, from: data))?.version }

    public var people: [Person] { lock.withLock { storage } }
    /// Whether `people.json` is on disk: false before the first save.
    public var exists: Bool { lock.withLock { onDisk } }
    public var owner: Person? { people.first { $0.isOwner && $0.isLive } }
    public func person(_ id: PersonID) -> Person? { people.first { $0.id == id } }
    public var resolver: PersonResolver { PersonResolver(people: people) }

    /// Each name the owner has or had, the current one last.
    public var ownerNames: [String] { owner?.forms.map(\.text) ?? [] }

    /// The person an id stands for now: a merged record points to the one that took it in.
    public func canonical(_ id: PersonID) -> PersonID {
        let all = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var current = id
        var seen: Set<PersonID> = [id]
        while let next = all[current]?.mergedInto {
            // A loop in the file must not hang the app.
            guard seen.insert(next).inserted else { return id }
            current = next
        }
        return current
    }

    /// The person of a profile in the voice library. The owner's profile is the owner, under any name; another
    /// profile is the person with exactly that display name.
    public func id(forVoiceName name: String, isOwner: Bool = false) -> PersonID? {
        lock.withLock { Self.id(forVoiceName: name, isOwner: isOwner, in: storage) }
    }

    public static func id(forVoiceName name: String, isOwner: Bool, in people: [Person]) -> PersonID? {
        if isOwner, let owner = people.first(where: { $0.isOwner && $0.isLive }) { return owner.id }
        // Another person with this name comes before the owner: "Your name" can hold another person's name for a moment.
        let hits = people.filter { $0.isLive && $0.displayName == name }
        return (hits.first { !$0.isOwner } ?? hits.first)?.id
    }

    // MARK: Changes

    /// Changes the people and saves. `body` returns the log lines of what it did; none means nothing changed, and
    /// then nothing is written.
    private func change(_ body: (inout [Person], Date) throws -> [PeopleLogEntry]) throws {
        try lock.withLock {
            var copy = storage
            let entries = try body(&copy, now())
            guard !entries.isEmpty || copy != storage else { return }
            try save(copy)
            storage = copy
            append(entries)
        }
    }

    private func save(_ people: [Person]) throws {
        if let newerVersion { throw NewerPeopleFile(version: newerVersion) }
        // A file that could not be read must not be replaced by what this copy knows, also after it was set aside.
        if let loadError { throw loadError }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(File(version: Self.currentVersion, people: people)).write(to: url, options: .atomic)
        onDisk = true
    }

    private func append(_ entries: [PeopleLogEntry]) {
        guard !entries.isEmpty else { return }
        do {
            var text = Data()
            for e in entries {
                text.append(try JSONEncoder.callRecord.encode(e))
                text.append(Data("\n".utf8))
            }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: text)
            } else {
                try text.write(to: logURL, options: .atomic)
            }
        } catch {
            Log.error("Could not write the people log: \(error)")
        }
    }

    /// The person of a voice profile, made when there is none.
    @discardableResult
    public func ensure(voiceName name: String, isOwner: Bool, origin: SourceKind) throws -> PersonID {
        var id: PersonID?
        try change { people, date in
            if let known = Self.id(forVoiceName: name, isOwner: isOwner, in: people) {
                id = known
                return []
            }
            let person = Person(displayName: name, isOwner: isOwner, origin: origin, at: date)
            people.append(person)
            id = person.id
            return [PeopleLogEntry(at: date, kind: "create", actor: "voices", subject: person.id, after: name)]
        }
        guard let id else { throw CocoaError(.fileWriteUnknown) }
        return id
    }

    /// Fills the people from Google's directory and contacts by `DirectoryMerge`. Returns how many changed.
    @discardableResult
    public func applyDirectory(_ profiles: [GoogleProfile]) throws -> Int {
        var count = 0
        try change { people, date in
            let result = DirectoryMerge.apply(profiles, to: people, at: date)
            people = result.people
            count = result.changed.count
            return result.log
        }
        return count
    }

    /// Removes the directory's details of these sources from every person. Returns how many changed.
    @discardableResult
    public func clearDirectory(_ sources: Set<GoogleProfile.Source>) throws -> Int {
        var count = 0
        try change { people, date in
            let next = DirectoryMerge.clear(sources, from: people, at: date)
            count = zip(people, next).filter { $0 != $1 }.count
            people = next
            return count > 0 ? [PeopleLogEntry(at: date, kind: "directory", actor: "google", subject: PersonID(rawValue: "all"), after: "cleared")] : []
        }
        return count
    }

    public func rename(_ id: PersonID, to new: String, actor: String = "owner") throws {
        try change { people, date in
            guard let i = people.firstIndex(where: { $0.id == id && $0.isLive }) else { return [] }
            let old = people[i].displayName
            people[i].rename(to: new, source: .owner, at: date)
            guard people[i].displayName != old else { return [] }
            return [PeopleLogEntry(at: date, kind: "rename", actor: actor, subject: id, before: old, after: people[i].displayName)]
        }
    }

    /// One verified address, as the People page keeps it today: a new one replaces the old one, and a blank one
    /// clears it.
    public func setEmail(_ email: String?, for id: PersonID, actor: String = "owner") throws {
        try change { people, date in
            guard let i = people.firstIndex(where: { $0.id == id && $0.isLive }) else { return [] }
            let old = people[i].email
            guard people[i].setVerifiedEmail(email, at: date) else { return [] }
            return [PeopleLogEntry(at: date, kind: "email", actor: actor, subject: id, before: old, after: people[i].email)]
        }
    }

    /// Joins `absorbed` into `survivor`. The absorbed record stays as a redirect, so its id continues to resolve;
    /// the survivor gets its forms and its addresses.
    public func merge(_ absorbed: PersonID, into survivor: PersonID) throws {
        try change { people, date in
            guard absorbed != survivor, let a = people.firstIndex(where: { $0.id == absorbed && $0.isLive }),
                  let s = people.firstIndex(where: { $0.id == survivor && $0.isLive }) else { return [] }
            let gone = people[a]
            for form in gone.forms {
                people[s].addForm(form.text, kind: form.kind == .display ? .alias : form.kind, source: form.source, confirmed: form.confirmed, at: date)
            }
            for email in gone.emails where !people[s].emails.contains(where: { $0.address == email.address }) { people[s].emails.append(email) }
            for identity in gone.identities where !people[s].identities.contains(where: { $0.isSame(identity) }) { people[s].identities.append(identity) }
            people[s].isOwner = people[s].isOwner || gone.isOwner
            people[s].mergedFrom.append(absorbed)
            people[s].updated = date
            people[a].mergedInto = survivor
            people[a].isOwner = false
            people[a].updated = date
            let whole = (try? JSONEncoder.callRecord.encode(gone)).map { String(decoding: $0, as: UTF8.self) }
            // The whole absorbed record, so the merge can be undone.
            return [PeopleLogEntry(at: date, kind: "merge", actor: "owner", subject: survivor, other: absorbed, before: whole)]
        }
    }

    /// The per-person switch "Keep a read on this person". Off stops new evidence; the app deletes the person's
    /// persona files (`PersonaStore`). The meetings stay.
    public func setDoNotProfile(_ off: Bool, for id: PersonID) throws {
        try change { people, date in
            guard let i = people.firstIndex(where: { $0.id == id && $0.isLive }), people[i].doNotProfile != off else { return [] }
            people[i].doNotProfile = off
            people[i].updated = date
            return [PeopleLogEntry(at: date, kind: "profile", actor: "owner", subject: id, before: off ? "read" : "no read", after: off ? "no read" : "read")]
        }
    }

    /// The owner said these two are other people. It holds through a rename of either, on each device.
    public func setDistinct(_ a: PersonID, _ b: PersonID) throws {
        try change { people, date in
            guard a != b, let i = people.firstIndex(where: { $0.id == a && $0.isLive }), let j = people.firstIndex(where: { $0.id == b && $0.isLive }) else { return [] }
            var changed = false
            if !people[i].distinctFrom.contains(b) { people[i].distinctFrom.append(b); people[i].updated = date; changed = true }
            if !people[j].distinctFrom.contains(a) { people[j].distinctFrom.append(a); people[j].updated = date; changed = true }
            return changed ? [PeopleLogEntry(at: date, kind: "distinct", actor: "owner", subject: a, other: b)] : []
        }
    }

    /// Leaves a marker with no personal data: the id and the date.
    public func delete(_ id: PersonID) throws {
        try change { people, date in
            guard let i = people.firstIndex(where: { $0.id == id && $0.deleted == nil }) else { return [] }
            var marker = Person(id: id, displayName: "", origin: people[i].origin, at: people[i].created)
            marker.forms = []
            marker.name = NameParts()
            marker.updated = date
            marker.deleted = date
            people[i] = marker
            return [PeopleLogEntry(at: date, kind: "delete", actor: "owner", subject: id)]
        }
    }

    /// The name in Settings is the owner's display name. A new one renames the owner's record, and the old name
    /// stays as a form, so the owner's lines in old meetings are still the owner's.
    public func setOwnerName(_ name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try change { people, date in
            guard let i = people.firstIndex(where: { $0.isOwner && $0.isLive }) else {
                let person = Person(displayName: name, isOwner: true, origin: .owner, at: date)
                people.append(person)
                return [PeopleLogEntry(at: date, kind: "create", actor: "owner", subject: person.id, after: name)]
            }
            let old = people[i].displayName
            guard old != name else { return [] }
            // Another live person's name is that person's: the owner keeps their own, so no label of the owner's
            // ever becomes the other person's name.
            guard !Self.isOtherPersonsName(name, owner: people[i].id, in: people) else {
                Log.error("People: \"Your name\" is the name of another saved person, so the owner keeps the name \(old)")
                return []
            }
            people[i].rename(to: name, source: .owner, at: date)
            return [PeopleLogEntry(at: date, kind: "ownerName", actor: "owner", subject: people[i].id, before: old, after: name)]
        }
    }

    /// Whether a name is the name of now of a live person other than the owner.
    static func isOtherPersonsName(_ name: String, owner: PersonID, in people: [Person]) -> Bool {
        let key = PersonNames.key(name)
        return people.contains { $0.isLive && $0.id != owner && PersonNames.key($0.displayName) == key }
    }

    /// Replaces the whole list: the migration's write.
    public func replaceAll(_ people: [Person], log entries: [PeopleLogEntry] = []) throws {
        try change { current, _ in
            current = people
            return entries
        }
    }
}
