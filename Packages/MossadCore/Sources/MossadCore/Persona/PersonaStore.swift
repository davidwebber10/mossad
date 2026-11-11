import CryptoKit
import Foundation

/// One file for each person id in `~/Mossad/Coach/people/`. One changed person writes one small file, and one
/// damaged file costs one person: it is moved aside and not replaced. A file from a later build is read and never
/// saved over. Never in `people.json`, a call's record, or the Markdown note.
public struct PersonaStore: Sendable {
    public let directory: URL
    /// A reader that changes nothing (Chat in other AI apps): a file that does not decode is left where it is.
    public let readOnly: Bool

    public init(directory: URL, readOnly: Bool = false) {
        self.directory = directory
        self.readOnly = readOnly
    }
    public init(paths: Paths) { self.init(directory: paths.coach.appendingPathComponent("people")) }

    public struct NewerFile: Error, CustomStringConvertible {
        public let person: String
        public var description: String { "The persona file of \(person) is from a later build; it is left as it is." }
    }

    func url(_ person: String) -> URL {
        // An id is a UUID; anything else is kept to letters, digits, and dashes so a file name cannot leave the folder.
        let safe = String(person.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map(Character.init))
        return directory.appendingPathComponent("\(safe).json")
    }

    /// The person's file, or nil when there is none. A file that does not decode is moved aside and throws.
    public func load(_ person: String) throws -> Persona? {
        if readOnly {
            guard let data = try? Data(contentsOf: url(person)) else { return nil }
            return try JSONDecoder.coach.decode(Persona.self, from: data)
        }
        return try StoredFile.load(Persona.self, from: url(person), decoder: .coach, recovery: .local)
    }

    /// Writes the file, unless the file on disk is from a later build.
    public func save(_ persona: Persona) throws {
        if let data = try? Data(contentsOf: url(persona.person)), let version = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int,
           version > Persona.currentVersion {
            throw NewerFile(person: persona.person)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var p = persona
        p.version = min(p.version, Persona.currentVersion)
        try JSONEncoder.coach.encode(p).write(to: url(persona.person), options: .atomic)
    }

    public func delete(_ person: String) {
        try? FileManager.default.removeItem(at: url(person))
    }

    /// The ids with a file.
    public func people() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".unreadable") && !$0.lastPathComponent.hasPrefix("_") }
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    /// Each file that reads. One that does not is left out, and the others stay.
    public func all() -> [Persona] { people().compactMap { try? load($0) } }

    /// The persona of a person now: their own file and the file of each record they took in, as one. The files of a
    /// merged record stay, so an undo of the merge separates them again.
    public func persona(of id: String, saved: CoachPeople) -> Persona? {
        let ids = saved.isEmpty ? [id] : saved.ids(of: id)
        let files = ids.compactMap { (try? load($0)) ?? nil }
        guard !files.isEmpty else { return nil }
        var out = Persona(person: saved.isEmpty ? id : saved.canonical(id), updated: files.map(\.updated).max() ?? .distantPast)
        // Evidence of one moment in two files counts once.
        var seen: Set<String> = []
        for f in files {
            for e in f.evidence where seen.insert("\(e.pointer.callID)|\(e.pointer.at)|\(e.dimension)|\(e.value)").inserted { out.evidence.append(e) }
        }
        out.evidence.sort { ($0.date, $0.pointer.at) < ($1.date, $1.pointer.at) }
        // The texts are by trait id, which holds the person's id: under the id of now.
        for f in files {
            for (key, text) in f.texts {
                let parts = key.split(separator: "|", omittingEmptySubsequences: false)
                let newKey = ([out.person] + parts.dropFirst().map(String.init)).joined(separator: "|")
                if out.texts[newKey] == nil || f.person == out.person { out.texts[newKey] = text }
            }
        }
        return out
    }

    /// A deleted meeting: its evidence goes from each file, and the ledger forgets it.
    @discardableResult
    public func forget(callID: String, at date: Date = Date()) -> Int {
        var changed = 0
        for var p in all() where p.calls.contains(callID) {
            p.replace(callID: callID, with: [], at: date)
            if (try? save(p)) != nil { changed += 1 }
        }
        var ledger = PersonaLedger.load(from: directory)
        if ledger.calls.removeValue(forKey: callID) != nil { ledger.save(to: directory) }
        return changed
    }
}

/// The calls the persona step has read, each with its stamp, and when each person's sentences were last written.
/// The stamp is the prompt version and a hash of the call's speaker names, person ids, and lines: a voice that
/// gets a name, a name that is corrected, and "Transcribe again" all change it, and the call is read again.
public struct PersonaLedger: Codable, Equatable, Sendable {
    static let fileName = "_ledger.json"
    /// A call that fails this many times (not a reply in the wrong shape) is left out, so it cannot stop each run.
    static let maxFailures = 3

    public var calls: [String: String] = [:]
    public var written: [String: Date] = [:]
    public var failures: [String: Int] = [:]

    public init() {}

    enum CodingKeys: String, CodingKey { case calls, written, failures }

    /// A ledger of an earlier build (a number for each call) reads as empty calls: each call is read again once.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        calls = (try? c.decodeIfPresent([String: String].self, forKey: .calls)) ?? [:]
        written = (try? c.decodeIfPresent([String: Date].self, forKey: .written)) ?? [:]
        failures = (try? c.decodeIfPresent([String: Int].self, forKey: .failures)) ?? [:]
    }

    public static func load(from dir: URL) -> PersonaLedger {
        (try? Data(contentsOf: dir.appendingPathComponent(fileName))).flatMap { try? JSONDecoder.coach.decode(PersonaLedger.self, from: $0) } ?? PersonaLedger()
    }

    public func save(to dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        } catch {
            Log.error("The persona ledger could not be saved: \(error)")
        }
    }

    /// "v<prompt>|<hash>". The record must have the owner's lines under the owner's name of now, as the runner reads it.
    public static func stamp(_ r: CallRecord) -> String {
        var text = ""
        for (k, v) in r.speakerNames.sorted(by: { $0.key < $1.key }) { text += "n\(k)=\(v)\n" }
        for (k, v) in (r.speakerPeople ?? [:]).sorted(by: { $0.key < $1.key }) { text += "p\(k)=\(v)\n" }
        for u in r.utterances { text += "u\(u.speakerKey)|\(u.start)|\(u.text)\n" }
        let hash = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "v\(PersonaExtractor.promptVersion)|\(hash)"
    }

    /// Read with this prompt, as the call is now.
    public func isRead(_ r: CallRecord) -> Bool { calls[r.id] == Self.stamp(r) }

    /// Read once, maybe as it was before a change.
    public func wasRead(_ id: String) -> Bool { calls[id] != nil }

    public mutating func markRead(_ r: CallRecord) {
        calls[r.id] = Self.stamp(r)
        failures[r.id] = nil
    }
}
