import Foundation

/// One thing the coach found in a call, as a card for the owner to answer: something the owner did, did not do,
/// or could do better, a conclusion to confirm, or a goal to take. A card always has proof: a moment to play, or
/// a number with its usual value. The answers train the coach (`CoachTraining`).
public struct CoachFinding: Codable, Equatable, Sendable, Hashable, Identifiable {
    /// Text, not a closed list: a card of a kind from a later build is not shown here, and its file still reads.
    public struct Kind: RawRepresentable, Hashable, Codable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let didWell = Kind(rawValue: "did_well")
        public static let missed = Kind(rawValue: "missed")
        public static let couldBeBetter = Kind(rawValue: "could_be_better")
        /// A conclusion of the coach for the owner to confirm.
        public static let learning = Kind(rawValue: "learning")
        /// A focus the coach proposes.
        public static let goalOffer = Kind(rawValue: "goal_offer")

        public static let all: [Kind] = [.didWell, .missed, .couldBeBetter, .learning, .goalOffer]
        public var isKnown: Bool { Self.all.contains(self) }
        /// About how the owner acted in the call: its answer moves the weight of its skill.
        public var isBehavior: Bool { self == .didWell || self == .missed || self == .couldBeBetter }

        /// What the card says it is.
        public var title: String {
            switch self {
            case .didWell: "You did this"
            case .missed: "You did not do this"
            case .couldBeBetter: "This could be better"
            case .learning: "Is this right?"
            case .goalOffer: "A goal for you?"
            default: ""
            }
        }
    }

    /// The same for the same finding of the same call, so an answer finds its card after the call is reviewed again.
    public var id: String
    public var callID: String
    /// The start of the call. A card with no answer goes `FindingRules.expiryDays` after it.
    public var date: Date
    public var kind: Kind
    public var text: String
    /// The skill's id (`CoachSkill.id`), "number:<metric>", or "pattern:<name>". Empty for a conclusion.
    public var skill: String
    /// A second line: why a goal is offered.
    public var detail: String?
    /// The words that are the proof, with their time: the owner's own for a finding, the quote behind a conclusion.
    public var quote: String?
    public var at: TimeInterval?
    /// A number the app measured, and what it stands against.
    public var number: String?
    public var usual: String?
    /// The words the owner could say.
    public var say: String?
    public var questionID: UUID?
    public var focusID: UUID?
    /// The id of the saved person a conclusion is about, on a sure match only, and that person's name then.
    public var person: String?
    public var personName: String?

    public init(id: String, callID: String, date: Date, kind: Kind, text: String, skill: String, detail: String? = nil, quote: String? = nil,
                at: TimeInterval? = nil, number: String? = nil, usual: String? = nil, say: String? = nil, questionID: UUID? = nil, focusID: UUID? = nil,
                person: String? = nil, personName: String? = nil) {
        self.id = id
        self.callID = callID
        self.date = date
        self.kind = kind
        self.text = text
        self.skill = skill
        self.detail = detail
        self.quote = quote
        self.at = at
        self.number = number
        self.usual = usual
        self.say = say
        self.questionID = questionID
        self.focusID = focusID
        self.person = person
        self.personName = personName
    }

    /// A moment to play, or a number with its usual value. A card without one is never made.
    public var hasProof: Bool { at != nil || usual != nil }
}

/// The owner's answer to a card. A swipe to the right is yes, a swipe to the left is no: a no to this one card.
/// "No, never again" is its own button.
public enum FindingVerdict: String, Codable, Sendable, CaseIterable { case yes, no, never }

/// One answer, as the coach's memory and the call's own file keep it. An answer that was taken back stays as an
/// entry with no verdict, so the newer copy wins when two devices merge.
public struct FindingAnswer: Codable, Equatable, Sendable, Hashable, Identifiable {
    /// The finding's id.
    public var id: String
    public var callID: String
    public var kind: CoachFinding.Kind
    public var skill: String
    /// The card's words, for the list of what was blocked in Settings.
    public var text: String
    public var verdict: FindingVerdict?
    public var date: Date
    /// Why not, in the owner's words.
    public var note: String?
    public var questionID: UUID?
    public var focusID: UUID?
    public var person: String?
    /// The active focus that a yes on a goal offer replaced: Undo makes it active again.
    public var replaced: UUID?

    public init(_ finding: CoachFinding, verdict: FindingVerdict?, date: Date) {
        id = finding.id
        callID = finding.callID
        kind = finding.kind
        skill = finding.skill
        text = finding.text
        self.verdict = verdict
        self.date = date
        questionID = finding.questionID
        focusID = finding.focusID
        person = finding.person
    }

    enum CodingKeys: String, CodingKey { case id, callID, kind, skill, text, verdict, date, note, questionID, focusID, person, replaced }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        callID = try c.decodeIfPresent(String.self, forKey: .callID) ?? ""
        kind = try c.decode(CoachFinding.Kind.self, forKey: .kind)
        skill = try c.decodeIfPresent(String.self, forKey: .skill) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        // A verdict from a later build is no verdict here, not a log that cannot be read.
        verdict = (try? c.decodeIfPresent(FindingVerdict.self, forKey: .verdict)) ?? nil
        date = try c.decode(Date.self, forKey: .date)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        questionID = try c.decodeIfPresent(UUID.self, forKey: .questionID)
        focusID = try c.decodeIfPresent(UUID.self, forKey: .focusID)
        person = try c.decodeIfPresent(String.self, forKey: .person)
        replaced = try c.decodeIfPresent(UUID.self, forKey: .replaced)
    }
}

/// The owner's answers to the cards of one call, saved as `findings.json` next to `coach.json`. The coach's
/// memory holds the same answers and is what the devices sync; this file keeps them with the call.
public struct CallFindings: Codable, Equatable, Sendable {
    public static let fileName = "findings.json"

    public var version = 1
    public var answers: [FindingAnswer] = []

    public init(answers: [FindingAnswer] = []) { self.answers = answers }

    enum CodingKeys: String, CodingKey { case version, answers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        answers = try c.decodeIfPresent(LossyArray<FindingAnswer>.self, forKey: .answers)?.values ?? []
    }

    public static func load(in dir: URL) -> CallFindings? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.coach.decode(CallFindings.self, from: data)
    }

    /// The call's folder must be there: an answer must not bring back the folder of a deleted meeting.
    public func save(in dir: URL) throws {
        try JSONEncoder.coach.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

public enum FindingStore {
    /// Writes the answers of one call next to its review, when they differ from the file. Only that call's folder
    /// is read. A call whose folder is gone gets none. True when it wrote the file.
    @discardableResult
    public static func mirror(_ answers: [FindingAnswer], callID: String, paths: Paths) -> Bool {
        guard !callID.isEmpty else { return false }
        let own = answers.filter { $0.callID == callID }
        let dir = paths.callDirectory(callID)
        guard FileManager.default.fileExists(atPath: dir.path), CallFindings.load(in: dir)?.answers ?? [] != own else { return false }
        do {
            try CallFindings(answers: own).save(in: dir)
            return true
        } catch {
            Log.error("The answers to the findings of \(callID) could not be saved: \(error)")
            return false
        }
    }
}
