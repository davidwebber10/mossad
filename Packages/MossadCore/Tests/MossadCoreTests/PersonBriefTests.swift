import XCTest
@testable import MossadCore

/// The coach's read on one person: goals, how to communicate with them, how they communicate, and what else
/// the calls show, kept up to date across calls.
final class PersonBriefTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func call(_ id: String, daysAgo: Double, with people: [String], line: String = "I need the numbers by Friday.") -> CallRecord {
        let start = t0.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: start, end: start.addingTimeInterval(1800), status: .written)
        r.speakerNames["me:A"] = "Dana"
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 0, end: 10, text: "Morning.")]
        for (i, p) in people.enumerated() {
            let label = String(UnicodeScalar(UInt8(65 + i)))
            r.speakerNames["them:\(label)"] = p
            r.utterances.append(Utterance(track: .them, speakerLabel: label, start: 12, end: 40, text: "\(p.split(separator: " ")[0]): \(line)"))
        }
        r.summary = "Budget review for \(id)."
        return r
    }

    private let output: [String: Any] = [
        "headline": "Lead with the number, then the reason.",
        "sections": [
            ["title": "Goals", "points": [["text": "Wants a budget finance trusts.", "call_id": "c2"]]],
            ["title": "How to communicate with them", "points": [["text": "Send numbers before the call.", "call_id": ""],
                                                                 ["text": "Made up.", "call_id": "nope"]]],
        ],
    ]

    func testTheBriefComesFromTheirCallsAndKeepsOnlyRealSources() async throws {
        let model = FakeModel(output: output)
        var profile = CoachProfile()
        profile.updateFacts(add: [CoachFact(kind: .relationship, text: "Mitch Haus reports to you.")], remove: [])
        profile.people["Mitch Haus"] = CoachPerson(note: "Likes data.", calls: 2, lastSeen: t0)
        let records = [call("c1", daysAgo: 3, with: ["Mitch Haus"]), call("c2", daysAgo: 1, with: ["Mitch Haus", "Jo Park"]),
                       call("c3", daysAgo: 2, with: ["Jo Park"])]
        let brief = try await PersonBriefWriter(llm: model, ownerName: "Dana").brief(for: "Mitch Haus", records: records, profile: profile, now: t0)
        XCTAssertEqual(brief.headline, "Lead with the number, then the reason.")
        XCTAssertEqual(brief.sections.map(\.title), ["Goals", "How to communicate with them"])
        XCTAssertEqual(brief.sections[0].points[0].callID, "c2")
        XCTAssertNil(brief.sections[1].points[0].callID, "no source")
        XCTAssertNil(brief.sections[1].points[1].callID, "a call it never read is dropped as a source")
        XCTAssertEqual(brief.calls, 2)
        XCTAssertEqual(brief.updated, t0)
        XCTAssertTrue(model.user.contains("c1") && model.user.contains("c2"))
        XCTAssertFalse(model.user.contains("c3"), "only calls with them")
        XCTAssertTrue(model.user.contains("Mitch: I need the numbers by Friday."), "their own words")
        XCTAssertTrue(model.user.contains("Mitch Haus reports to you."), "what the owner confirmed")
        XCTAssertTrue(model.user.contains("Likes data."))
    }

    func testAReviewKeepsThePersonsBrief() {
        var profile = CoachProfile()
        profile.people["Mitch Haus"] = CoachPerson(note: "Old", calls: 1, lastSeen: t0)
        profile.people["Mitch Haus"]!.brief = PersonBrief(headline: "H", sections: [], calls: 1, updated: t0)
        let review = CoachReview(headline: "", overview: "", strengths: [], improvements: [], focusProgress: nil)
        profile.apply(CoachProfileUpdate(summary: "", focus: "", patterns: [], people: [CoachPersonUpdate(name: "Mitch Haus", note: "New")]),
                      review: review, callID: "c", title: "T", at: t0)
        XCTAssertEqual(profile.people["Mitch Haus"]?.note, "New")
        XCTAssertEqual(profile.people["Mitch Haus"]?.brief?.headline, "H")
    }

    func testABriefIsDueAfterANewCallAtMostOnceADay() {
        var profile = CoachProfile()
        let records = [call("c1", daysAgo: 3, with: ["Mitch Haus", "Jo Park"]), call("c2", daysAgo: 1, with: ["Mitch Haus"]),
                       call("c3", daysAgo: 0.1, with: ["Ed Ng"])]
        XCTAssertEqual(PersonBriefWriter.due(profile: profile, records: records, owner: "Dana", now: t0), ["Mitch Haus"],
                       "two calls or more; Jo and Ed have one")
        profile.people["Mitch Haus"] = CoachPerson(note: "", calls: 2, lastSeen: t0)
        profile.people["Mitch Haus"]!.brief = PersonBrief(headline: "H", sections: [], calls: 2, updated: t0.addingTimeInterval(-3600))
        XCTAssertEqual(PersonBriefWriter.due(profile: profile, records: records, owner: "Dana", now: t0), [], "no new call since")
        let newer = records + [call("c4", daysAgo: 0.01, with: ["Mitch Haus"])]
        XCTAssertEqual(PersonBriefWriter.due(profile: profile, records: newer, owner: "Dana", now: t0), [], "updated less than a day ago")
        XCTAssertEqual(PersonBriefWriter.due(profile: profile, records: newer, owner: "Dana", now: t0.addingTimeInterval(86_400)), ["Mitch Haus"])
    }
}
