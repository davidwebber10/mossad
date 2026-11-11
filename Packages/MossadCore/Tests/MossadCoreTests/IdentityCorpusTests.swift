import XCTest
@testable import MossadCore

/// One table of what was written, who was in the meeting, and who it must be. Each bug the owner reports becomes
/// one more row. The rows run through `PersonDirectory`, as the meeting pages and Analytics do.
final class IdentityCorpusTests: XCTestCase {
    private struct Row {
        let written: String
        var meeting: [String] = []
        /// The profile a click on the name opens.
        let link: String?
        /// The saved person the invited entry is.
        let match: String?
        let why: String
    }

    private let saved = PersonDirectory([
        .init(name: "Sam Carter", email: "sam.carter@example.com"),
        .init(name: "Dana Lee", email: "dana@example.com"),
        .init(name: "Michael Reed", email: nil),
        .init(name: "Maria De La Cruz", email: nil),
        .init(name: "Zoë Carter-Reed", email: nil),
        .init(name: "Pat O'Neil", email: nil),
        .init(name: "Riley A. Chen", email: nil),
        .init(name: "Jo", email: nil),
    ])

    private var rows: [Row] {
        let spoke = ["Sam Carter", "Dana Lee"]
        return [
            // The owner's report: the invite wrote the last name first, and the person did not link.
            Row(written: "Carter, Sam", link: "Sam Carter", match: "Sam Carter", why: "the comma proves the order"),
            Row(written: "Carter, Sam", meeting: spoke, link: "Sam Carter", match: "Sam Carter", why: "the same in the meeting where Sam spoke"),
            Row(written: "carter,sam", link: "Sam Carter", match: "Sam Carter", why: "no space and no capitals"),
            Row(written: "Lee, Dana", link: "Dana Lee", match: "Dana Lee", why: "the comma form"),
            Row(written: "Carter, Sam A.", link: "Sam Carter", match: "Sam Carter", why: "the comma form with a middle initial"),
            Row(written: "Carter, Sam (Acme)", link: "Sam Carter", match: "Sam Carter", why: "the comma form with a company"),
            Row(written: "Carter, Sam, PhD", link: "Sam Carter", match: "Sam Carter", why: "the comma form with a suffix"),
            Row(written: "De La Cruz, Maria", link: "Maria De La Cruz", match: "Maria De La Cruz", why: "a family name of three words"),
            Row(written: "Carter-Reed, Zoe", link: "Zoë Carter-Reed", match: "Zoë Carter-Reed", why: "a hyphen and no diacritic"),
            Row(written: "O’Neil, Pat", link: "Pat O'Neil", match: "Pat O'Neil", why: "the other apostrophe"),
            Row(written: "Chen, Riley", link: "Riley A. Chen", match: "Riley A. Chen", why: "the saved name has the middle initial"),
            Row(written: "CARTER Sam", link: "Sam Carter", match: "Sam Carter", why: "capitals prove the family name"),
            Row(written: "Sam CARTER", link: "Sam Carter", match: "Sam Carter", why: "capitals at the end"),
            Row(written: "LEE Dana", link: "Dana Lee", match: "Dana Lee", why: "capitals, three letters"),
            // "Last First" with no comma and no capitals has no proof. It links only where that person is.
            Row(written: "Carter Sam", meeting: spoke, link: "Sam Carter", match: "Sam Carter", why: "Sam spoke in this meeting"),
            Row(written: "Lee Dana", meeting: spoke, link: "Dana Lee", match: "Dana Lee", why: "Dana spoke in this meeting"),
            Row(written: "Carter Sam", meeting: ["Carter, Sam"], link: "Sam Carter", match: "Sam Carter", why: "Sam is invited in a proved form too"),
            Row(written: "Carter Sam", link: nil, match: nil, why: "with nobody around it, the order is a guess"),
            Row(written: "Carter Sam", meeting: ["Dana Lee"], link: nil, match: nil, why: "Sam is not known to be there"),
            Row(written: "Reed Michael", meeting: ["Michael Reed"], link: "Michael Reed", match: "Michael Reed", why: "two first names: the roster decides"),
            // Other written forms of the whole name.
            Row(written: "Sam A. Carter", link: "Sam Carter", match: "Sam Carter", why: "a middle initial"),
            Row(written: "Dr. Sam Carter Jr.", link: "Sam Carter", match: "Sam Carter", why: "a title and a suffix"),
            Row(written: "Sam Carter <sam@other.example.com>", link: "Sam Carter", match: "Sam Carter", why: "an unknown address leaves the name to decide"),
            Row(written: "Someone Else <dana@example.com>", link: "Dana Lee", match: "Dana Lee", why: "the email beats the name"),
            Row(written: "Zoe Carter Reed", link: "Zoë Carter-Reed", match: "Zoë Carter-Reed", why: "the hyphen is a space"),
            Row(written: "Riley Chen", link: "Riley A. Chen", match: "Riley A. Chen", why: "no middle initial on one side"),
            Row(written: "Riley B. Chen", link: nil, match: nil, why: "another middle initial is another person"),
            // Short forms never open a profile. Among the people of the meeting they say who was invited.
            Row(written: "Mike Reed", meeting: ["Michael Reed"], link: nil, match: "Michael Reed", why: "a short first name"),
            Row(written: "Reed, Mike", meeting: ["Michael Reed"], link: nil, match: "Michael Reed", why: "a short first name, last name first"),
            Row(written: "Mike Reed", link: nil, match: nil, why: "a short first name with no meeting"),
            Row(written: "Sam", meeting: spoke, link: nil, match: "Sam Carter", why: "the one Sam of the meeting"),
            Row(written: "Sam", meeting: ["Sam Carter", "Lee, Sam"], link: nil, match: nil, why: "another Sam is invited, last name first"),
            Row(written: "Jo", link: nil, match: "Jo", why: "a person saved under one word"),
            Row(written: "Speaker B", meeting: spoke, link: nil, match: nil, why: "a label is not a name"),
            Row(written: "Carter, Dana", meeting: spoke, link: nil, match: nil, why: "two saved names mixed are nobody"),
        ]
    }

    func testEachRow() {
        for row in rows {
            XCTAssertEqual(saved.link(for: row.written, in: row.meeting), row.link, "link \"\(row.written)\" in \(row.meeting): \(row.why)")
            XCTAssertEqual(saved.match(row.written, among: row.meeting), row.match, "match \"\(row.written)\" among \(row.meeting): \(row.why)")
        }
    }

    /// The owner's case end to end: the invite names "Carter, Sam", and Sam Carter spoke. Before, Analytics showed
    /// the invited person as not matched and the speaker as not invited.
    func testAnInviteWithTheLastNameFirstIsTheSpeakerInParticipation() {
        var r = CallRecord(id: "c", platform: .meet, bundleID: "b", start: Date(timeIntervalSince1970: 1_780_000_000),
                           end: Date(timeIntervalSince1970: 1_780_001_800), status: .written)
        r.calendarTitle = "Review"
        r.attendees = ["Carter, Sam", "Lee, Dana", "Webb, Avery"]
        r.speakerNames = ["me:A": "Avery Webb", "them:A": "Sam Carter"]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Hello."),
                        Utterance(track: .them, speakerLabel: "A", start: 10, end: 30, text: "Hello to you.")]
        let p = MeetingAnalytics(record: r, owner: "Avery Webb", people: saved).participation
        XCTAssertEqual(p?.invited.map(\.label), ["Carter, Sam", "Lee, Dana", "Webb, Avery"])
        XCTAssertEqual(p?.invited.map(\.person), ["Sam Carter", "Dana Lee", nil])
        XCTAssertEqual(p?.spoke.map(\.label), ["Carter, Sam", "Webb, Avery"], "the owner is not saved here, and is still the speaker of that name")
        XCTAssertEqual(p?.notMatched.map(\.label), [])
        XCTAssertEqual(p?.unmatchedSpeakers, [], "nobody who spoke shows as not invited")
    }

    // MARK: Naming a voice

    private func library(_ names: [String], _ body: (VoiceLibrary) throws -> Void) throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = VoiceLibrary(directory: dir)
        for (i, name) in names.enumerated() { try library.add([Float(i + 1), 1, 0, 0], to: name) }
        try body(library)
    }

    /// A voice joins a saved person only on a sure match: the whole name, in either order, or the email.
    func testAVoiceJoinsASavedPersonOnTheWholeNameInEitherOrder() throws {
        try library(["Sam Carter", "Michael Reed", "Jo", "Maria De La Cruz"]) { library in
            try library.setEmail("sam.carter@example.com", for: "Sam Carter")
            for typed in ["sam  carter", "SAM CARTER", "Carter, Sam", "CARTER Sam", "Carter Sam", "Dr. Sam Carter", "Sam Carter Jr."] {
                XCTAssertEqual(library.existingName(name: typed, email: nil), "Sam Carter", typed)
            }
            XCTAssertEqual(library.existingName(name: "De La Cruz, Maria", email: nil), "Maria De La Cruz")
            XCTAssertEqual(library.existingName(name: "jo", email: nil), "Jo", "a person saved under one word, as before")
            XCTAssertEqual(library.existingName(name: "Someone Else", email: " Sam.Carter@Example.com "), "Sam Carter", "the email the owner picked")
        }
    }

    /// A short first name, a middle name, a name a letter off, and a first name alone are guesses. The voice then
    /// gets the name as typed, as before this resolver, and the People page can offer the pair to merge.
    func testAVoiceNeverJoinsASavedPersonOnAGuess() throws {
        try library(["Sam Carter", "Michael Reed", "Jo"]) { library in
            for typed in ["Mike Reed", "Reed, Mike", "Sam A. Carter", "Carter, Sam A.", "Sam Carver", "Sam", "Sam C.", "Sam Carter (Acme)", "Jo Park", "Riley Chen", ""] {
                XCTAssertNil(library.existingName(name: typed, email: nil), typed)
            }
            XCTAssertNil(library.existingName(name: "Sam Carter-Reed", email: "nobody@example.com"))
        }
    }

    /// Review scenario A: Samantha Carter is saved, and a new person, Samuel Carter, is named "Sam Carter".
    func testAShortNameOfANewPersonDoesNotGoIntoAnotherPersonsProfile() throws {
        try library(["Samantha Carter", "Alexandra Smith", "Patricia Lee", "Christopher Nair"]) { library in
            for typed in ["Sam Carter", "Alex Smith", "Pat Lee", "Chris Nair"] { XCTAssertNil(library.existingName(name: typed, email: nil), typed) }
        }
    }

    /// Review scenario B: two saved people fit the typed name. Two who fit are nobody.
    func testANameThatTwoSavedPeopleFitJoinsNobody() throws {
        try library(["Riley A. Chen", "Riley B. Chen"]) { library in
            XCTAssertNil(library.existingName(name: "Riley Chen", email: nil))
            XCTAssertEqual(library.existingName(name: "riley b chen", email: nil), "Riley B. Chen", "the whole name of one of them")
        }
        try library(["Dr. Sam Carter", "Carter, Sam"]) { library in
            XCTAssertNil(library.existingName(name: "Sam Carter", email: nil), "each of the two is this name in another written form")
        }
        // Two profiles with the same name in another case were one person before this resolver: the first one.
        try library(["Sam Carter", "sam carter"]) { library in
            XCTAssertEqual(library.existingName(name: "SAM CARTER", email: nil), "Sam Carter")
        }
    }

    func testTwoProfilesOfOneNameWrittenTwoWaysAreAPossibleDuplicate() {
        func profile(_ name: String, _ v: [Float]) -> VoiceProfile { VoiceProfile(name: name, isOwner: false, embeddings: [v]) }
        let found = PeopleDuplicates.find([profile("Sam Carter", [1, 0, 0, 0]), profile("Carter, Sam", [0, 1, 0, 0]), profile("Michael Reed", [0, 0, 1, 0]),
                                           profile("Mike Reed", [0, 0, 0, 1]), profile("Dana A. Lee", [1, 1, 0, 0]), profile("Dana B. Lee", [0, 0, 1, 1])])
        XCTAssertEqual(found.map(\.reason), [.sameName, .sameName])
        XCTAssertEqual(Set(found.map(\.id)), ["Carter, Sam|Sam Carter", "Michael Reed|Mike Reed"])
    }
}
