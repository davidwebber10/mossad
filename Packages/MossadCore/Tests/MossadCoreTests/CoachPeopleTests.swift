import XCTest
@testable import MossadCore

/// What the coach learns about a person stays with that person's id: through a new name, a name written the
/// other way, and a merge of two records. A name that is not one saved person on a sure match gets no id.
final class CoachPeopleTests: XCTestCase {
    private let owner = "Dana Lee"
    private let base = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func person(_ name: String, owner: Bool = false, email: String? = nil) -> Person {
        var p = Person(displayName: name, isOwner: owner, origin: .voiceNaming, at: base)
        if let email { p.addEmail(email, state: .verified, source: .owner, at: base) }
        return p
    }

    private lazy var dana = person("Dana Lee", owner: true)
    private lazy var sam = person("Sam Carter", email: "sam.carter@example.com")
    private lazy var riley = person("Riley Chen")
    private var saved: CoachPeople { CoachPeople(people: [dana, sam, riley]) }

    private func call(_ id: String = "c", day n: Double = 0, with other: String = "Sam Carter") -> CallRecord {
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: base.addingTimeInterval(n * day), end: base.addingTimeInterval(n * day + 1800), status: .written)
        r.speakerNames = ["me:A": owner, "them:A": other]
        r.utterances = [Utterance(track: .me, speakerLabel: "A", start: 10, end: 30, text: "I will send the forecast to finance."),
                        Utterance(track: .them, speakerLabel: "A", start: 40, end: 60, text: "Can you approve my leave for next week?")]
        return r
    }

    private func question(_ statement: String = "Sam reports to you.", about: String? = "Sam Carter", callID: String = "c") -> CoachQuestion {
        var q = CoachQuestion(statement: statement, kind: .relationship, evidence: "Can you approve my leave for next week?", callID: callID, at: 40, asked: base)
        q.about = about
        return q
    }

    private var review: CoachReview { CoachReview(headline: "H", overview: "", strengths: [], improvements: [], focusProgress: nil) }

    private func deck(_ profile: CoachProfile) -> [CoachFinding] {
        FindingRules.deck(callID: "c", date: base, review: review, profile: profile, now: base.addingTimeInterval(day))
    }

    // MARK: A sure match, or no person

    func testANameIsAPersonOnlyOnASureMatch() {
        XCTAssertEqual(saved.id(of: "Sam Carter"), sam.id.rawValue)
        XCTAssertEqual(saved.id(of: "Carter, Sam"), sam.id.rawValue, "last name first is the same person")
        XCTAssertEqual(saved.id(of: "Somebody Else", email: "sam.carter@example.com"), sam.id.rawValue, "the address says who it is")
        XCTAssertNil(saved.id(of: "Sam"), "a first name alone is a guess")
        XCTAssertNil(saved.id(of: "Sam Carte"), "almost the name is a guess")
        XCTAssertNil(saved.id(of: "Speaker B"))
        XCTAssertNil(saved.id(of: "Jordan Blake"), "nobody saved")
        XCTAssertNil(saved.id(of: "Dana Lee"), "the owner is not a person the owner learns about")
        // Two saved people with one name: nobody.
        let twins = CoachPeople(people: [dana, sam, person("Sam Carter")])
        XCTAssertNil(twins.id(of: "Sam Carter"))
        XCTAssertNil(CoachPeople.none.id(of: "Sam Carter"), "with no people store there are no ids")
    }

    func testAConclusionIsAboutAPersonOnlyWhenTheCallNamesThatPersonWhole() {
        let r = call()
        XCTAssertEqual(saved.subject(of: "Sam reports to you.", about: "Sam Carter", in: r)?.id, sam.id.rawValue, "the model named the speaker")
        XCTAssertEqual(saved.subject(of: "Sam Carter reports to you.", about: nil, in: r)?.id, sam.id.rawValue, "the whole name is in the claim")
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: nil, in: r), "a first name in the claim is a guess")
        XCTAssertNil(saved.subject(of: "Riley reports to you.", about: "Riley Chen", in: r), "that person is not in this call")
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: "Sam", in: r))
        XCTAssertNil(saved.subject(of: "The Monday call is for decisions.", about: "", in: r))
        XCTAssertNil(saved.subject(of: "You own the vendor contracts.", about: "Dana Lee", in: r), "about the owner")
        // A speaker that the voice library named with a name nobody saved.
        XCTAssertNil(saved.subject(of: "Pat Moreno decides the budget.", about: "Pat Moreno", in: call(with: "Pat Moreno")))
    }

    // MARK: Stored with the person id

    func testAConfirmedPersonLearningIsStoredWithThePersonID() {
        var q = question()
        let subject = saved.subject(of: q.statement, about: q.about, in: call())
        q.person = subject?.id
        q.personName = subject?.name
        var profile = CoachProfile()
        profile.ask([q])
        let card = deck(profile)[0]
        XCTAssertEqual(card.kind, .learning)
        XCTAssertEqual(card.person, sam.id.rawValue)
        XCTAssertEqual(card.personName, "Sam Carter")
        profile.answer(card, .yes, at: base.addingTimeInterval(day))
        XCTAssertEqual(profile.facts.map(\.person), [sam.id.rawValue])
        XCTAssertEqual(profile.learnings(about: sam.id.rawValue, people: saved).map(\.text), ["Sam reports to you."])
        XCTAssertEqual(profile.learnings(about: riley.id.rawValue, people: saved), [])
        // A conclusion about no one person is a fact with no person.
        var plain = CoachProfile()
        plain.ask([question("The Monday call is for decisions.", about: nil)])
        plain.answer(deck(plain)[0], .yes, at: base)
        XCTAssertEqual(plain.facts.map(\.person), [nil])
    }

    func testTheReasonForANoOnAPersonLearningIsGuidanceForThatPerson() {
        var q = question()
        q.person = sam.id.rawValue
        q.personName = "Sam Carter"
        var profile = CoachProfile()
        profile.ask([q])
        let card = deck(profile)[0]
        profile.answer(card, .no, at: base)
        profile.explain(card.id, note: "Sam reports to Riley, and I only cover for Riley this month.", at: base)
        XCTAssertEqual(profile.guidance.map(\.person), [sam.id.rawValue])
        XCTAssertEqual(profile.guidance(about: sam.id.rawValue, people: saved).count, 1)
        // The model reads it with that person, also after a new name.
        var renamed = sam
        renamed.rename(to: "Samuel Carter", source: .owner, at: base)
        let text = CoachPrompt.user(record: call("d", day: 2, with: "Samuel Carter"), owner: owner, profile: profile, saved: CoachPeople(people: [dana, renamed, riley]))
        let notes = text.components(separatedBy: "## Your notes on the people in this call\n").last ?? ""
        XCTAssertTrue(notes.hasPrefix("- Samuel Carter"), notes)
        XCTAssertTrue(notes.contains("Sam reports to Riley, and I only cover for Riley this month."))
    }

    // MARK: A rename, a name the other way, a merge

    private func learned() -> CoachProfile {
        var profile = CoachProfile()
        var fact = CoachFact(kind: .relationship, text: "Sam reports to you.", date: base)
        fact.person = sam.id.rawValue
        profile.facts = [fact]
        var note = CoachPerson(note: "Sam wants the answer first.", calls: 4, lastSeen: base)
        note.person = sam.id.rawValue
        profile.people["Sam Carter"] = note
        return profile
    }

    func testARenameKeepsTheLearningAndTheNoteWithThePerson() {
        var renamed = sam
        renamed.rename(to: "Samuel Carter-Reed", source: .owner, at: base.addingTimeInterval(day))
        let after = CoachPeople(people: [dana, renamed, riley])
        var profile = learned()
        XCTAssertEqual(profile.note(on: "Samuel Carter-Reed", people: after)?.value.note, "Sam wants the answer first.")
        XCTAssertEqual(after.name(of: sam.id.rawValue), "Samuel Carter-Reed")
        let text = CoachPrompt.user(record: call("d", day: 2, with: "Samuel Carter-Reed"), owner: owner, profile: profile, saved: after)
        XCTAssertTrue(text.contains("- Samuel Carter-Reed (4 earlier calls): Sam wants the answer first."), text)
        XCTAssertTrue(text.contains("Confirmed by \(owner): Sam reports to you."), text)
        // With no people store the notes are read by the name, as before.
        XCTAssertFalse(CoachPrompt.user(record: call("d", day: 2, with: "Samuel Carter-Reed"), owner: owner, profile: profile).contains("Sam wants the answer first."))
        XCTAssertTrue(CoachPrompt.user(record: call("d", day: 2), owner: owner, profile: profile).contains("- Sam Carter (4 earlier calls): Sam wants the answer first."))

        // The next review writes its note to the same person, under the name of now.
        let update = CoachProfileUpdate(summary: "", focus: "", patterns: [], people: [CoachPersonUpdate(name: "Samuel Carter-Reed", note: "Samuel asks for dates.")])
        profile.apply(update, review: review, callID: "d", title: "T", at: base.addingTimeInterval(2 * day), people: ["Samuel Carter-Reed": sam.id.rawValue])
        XCTAssertEqual(Array(profile.people.keys), ["Samuel Carter-Reed"])
        XCTAssertEqual(profile.people["Samuel Carter-Reed"]?.calls, 5)
        XCTAssertEqual(profile.people["Samuel Carter-Reed"]?.person, sam.id.rawValue)
    }

    func testAnInviteWithTheNameTheOtherWayReadsTheSamePerson() {
        let prep = PrepCoach(people: ["Carter, Sam", "Riley Chen", "Jordan Blake"], profile: learned(), saved: saved)
        XCTAssertEqual(prep.people.map(\.name), ["Carter, Sam"])
        XCTAssertEqual(prep.people[0].note, "Sam wants the answer first.")
        XCTAssertEqual(prep.people[0].learnings, ["Sam reports to you."])
        // The page's own names (the saved name) read the same.
        XCTAssertEqual(PrepCoach(people: ["Sam Carter"], profile: learned(), saved: saved).people.first?.learnings, ["Sam reports to you."])
        // A person with a learning and no note is on the page too.
        var only = learned()
        only.people = [:]
        XCTAssertEqual(PrepCoach(people: ["Sam Carter"], profile: only, saved: saved).people.map(\.learnings), [["Sam reports to you."]])
    }

    func testAMergeOfTwoRecordsKeepsWhatWasLearnedOfBoth() {
        var absorbed = person("Sam C. Carter")
        var survivor = sam
        absorbed.mergedInto = survivor.id
        survivor.mergedFrom = [absorbed.id]
        survivor.addForm("Sam C. Carter", kind: .alias, source: .owner, confirmed: true, at: base)
        let after = CoachPeople(people: [dana, survivor, absorbed, riley])
        XCTAssertEqual(after.canonical(absorbed.id.rawValue), sam.id.rawValue)

        var profile = learned()
        var fact = CoachFact(kind: .context, text: "Sam C. Carter prefers written updates.", date: base)
        fact.person = absorbed.id.rawValue
        profile.facts.append(fact)
        var other = CoachPerson(note: "Short and written works.", calls: 2, lastSeen: base.addingTimeInterval(day))
        other.person = absorbed.id.rawValue
        profile.people["Sam C. Carter"] = other
        XCTAssertEqual(profile.learnings(about: sam.id.rawValue, people: after).map(\.text), ["Sam reports to you.", "Sam C. Carter prefers written updates."])
        XCTAssertEqual(profile.learnings(about: absorbed.id.rawValue, people: after).count, 2, "the old id reads the same person")

        // The link step joins the two notes: the newer words, and the calls of both.
        XCTAssertGreaterThan(profile.linkPeople(after, records: []), 0)
        XCTAssertEqual(profile.people.count, 1)
        let note = profile.note(on: "Sam Carter", people: after)?.value
        XCTAssertEqual(note?.note, "Short and written works.")
        XCTAssertEqual(note?.calls, 6)
        XCTAssertEqual(note?.person, sam.id.rawValue)
        XCTAssertEqual(Set(profile.facts.compactMap(\.person)), [sam.id.rawValue])
    }

    // MARK: The move to ids

    func testTheMoveToIDsLinksWhatIsSureAndLeavesTheRestUntouched() {
        var profile = CoachProfile()
        profile.people = ["Sam Carter": CoachPerson(note: "A", calls: 3, lastSeen: base), "Sam": CoachPerson(note: "B", calls: 1, lastSeen: base),
                          "Speaker B": CoachPerson(note: "C", calls: 1, lastSeen: base), "Michael Reid": CoachPerson(note: "D", calls: 1, lastSeen: base),
                          "Chen, Riley": CoachPerson(note: "E", calls: 1, lastSeen: base)]
        var confirmed = question("Sam Carter reports to you.", about: nil)
        confirmed.status = .confirmed
        var first = question("Sam leads the vendor work.", about: nil)
        first.status = .confirmed
        let open = question("Riley Chen decides the budget.", about: nil, callID: "r")
        let nobody = question("The Monday call is for decisions.", about: nil)
        let lost = question("Sam Carter owns the forecast.", about: nil, callID: "gone")
        profile.questions = [confirmed, first, open, nobody, lost]
        profile.facts = [CoachFact(kind: .relationship, text: "Sam Carter reports to you.", date: base), CoachFact(kind: .context, text: "Sam leads the vendor work.", date: base),
                         CoachFact(kind: .relationship, text: "Riley Chen is my peer in finance", date: base), CoachFact(kind: .role, text: "Head of data", date: base),
                         CoachFact(kind: .relationship, text: "Sam Carter and Riley Chen share a team", date: base)]
        let before = profile
        let records = [call(), call("r", with: "Riley Chen")]

        XCTAssertEqual(profile.linkPeople(saved, records: records), 6)
        XCTAssertEqual(profile.people["Sam Carter"]?.person, sam.id.rawValue)
        // The note has the person's name of now as its label, so a device with no people store finds it.
        XCTAssertNil(profile.people["Chen, Riley"])
        XCTAssertEqual(profile.people["Riley Chen"]?.person, riley.id.rawValue)
        XCTAssertEqual(profile.people["Riley Chen"]?.note, "E")
        for key in ["Sam", "Speaker B", "Michael Reid"] { XCTAssertEqual(profile.people[key], before.people[key], key) }
        XCTAssertEqual(profile.questions.map(\.person), [sam.id.rawValue, nil, riley.id.rawValue, nil, nil])
        XCTAssertEqual(profile.questions[0].personName, "Sam Carter")
        XCTAssertEqual(profile.questions[1], before.questions[1], "a first name is left as it is")
        XCTAssertEqual(profile.questions[4], before.questions[4], "its call is gone: nothing says who was there")
        XCTAssertEqual(profile.facts.map(\.person), [sam.id.rawValue, nil, riley.id.rawValue, nil, nil], "a fact that names two people is about no one person")
        // Nothing but the ids changed.
        var plain = profile
        plain.people["Chen, Riley"] = plain.people.removeValue(forKey: "Riley Chen")
        for key in plain.people.keys { plain.people[key]?.person = nil }
        for i in plain.questions.indices { plain.questions[i].person = nil; plain.questions[i].personName = nil }
        for i in plain.facts.indices { plain.facts[i].person = nil }
        XCTAssertEqual(plain, before)
        // A second run changes nothing.
        let once = profile
        XCTAssertEqual(profile.linkPeople(saved, records: records), 0)
        XCTAssertEqual(profile, once)
        // With no people store nothing is written.
        var none = before
        XCTAssertEqual(none.linkPeople(.none, records: records), 0)
        XCTAssertEqual(none, before)
    }

    // MARK: Readers

    func testTheReadOnAPersonUsesWhatWasLearnedByID() async throws {
        var renamed = sam
        renamed.rename(to: "Samuel Carter", source: .owner, at: base)
        let after = CoachPeople(people: [dana, renamed, riley])
        var profile = learned()
        profile.facts[0].text = "He reports to you."
        let model = FakeModel(output: ["headline": "H", "sections": []])
        var a = call("a", day: -3, with: "Samuel Carter"), b = call("b", day: -1, with: "Samuel Carter")
        a.summary = "S"
        b.summary = "S"
        _ = try await PersonBriefWriter(llm: model, ownerName: owner).brief(for: "Samuel Carter", records: [a, b], profile: profile, now: base, saved: after)
        XCTAssertTrue(model.user.contains("He reports to you."), "the learning has no name in its words: the id finds it")
        XCTAssertTrue(model.user.contains("Sam wants the answer first."), "the note under the old name")
        // The read is saved with the person, and found under the new name.
        profile.setBrief(PersonBrief(headline: "Lead with the answer.", sections: [], calls: 2, updated: base), for: "Samuel Carter", people: after)
        XCTAssertEqual(profile.people.count, 1)
        XCTAssertEqual(profile.note(on: "Samuel Carter", people: after)?.value.brief?.headline, "Lead with the answer.")
        XCTAssertEqual(profile.note(on: "Samuel Carter", people: after)?.value.note, "Sam wants the answer first.")
        XCTAssertFalse(PersonBriefWriter.due(profile: profile, records: [a, b], owner: owner, now: base.addingTimeInterval(3600), saved: after).contains("Samuel Carter"),
                       "the read is there")
        // The note has the name of now as its label, so a device with no people store finds it too.
        XCTAssertEqual(Array(profile.people.keys), ["Samuel Carter"])
    }

    func testIDsHoldBetweenDevicesAndInFilesOfBothAges() throws {
        // The phone has an older build: it saves the memory with no ids. The Mac's ids stay.
        let mac = learned()
        var phone = mac
        phone.facts[0].person = nil
        var asked = question("Sam decides the vendor budget.")
        asked.person = sam.id.rawValue
        var macAsked = mac
        macAsked.ask([asked])
        var phoneAsked = phone
        var stripped = asked
        stripped.person = nil
        stripped.about = nil
        phoneAsked.questions = [stripped]
        let merged = macAsked.merged(with: phoneAsked)
        XCTAssertEqual(merged.facts.map(\.person), [sam.id.rawValue])
        XCTAssertEqual(merged.questions.map(\.person), [sam.id.rawValue])
        XCTAssertEqual(merged.people["Sam Carter"]?.person, sam.id.rawValue)
        // The new memory reads in a build that does not know the new fields.
        struct OldFact: Decodable { var kind: String; var text: String }
        struct OldPerson: Decodable { var note: String; var calls: Int }
        struct OldProfile: Decodable { var facts: [OldFact]; var people: [String: OldPerson] }
        let old = try JSONDecoder.coach.decode(OldProfile.self, from: JSONEncoder.coach.encode(mac))
        XCTAssertEqual(old.facts.map(\.text), ["Sam reports to you."])
        XCTAssertEqual(old.people["Sam Carter"]?.calls, 4)
        XCTAssertEqual(try JSONDecoder.coach.decode(CoachProfile.self, from: JSONEncoder.coach.encode(mac)), mac)
    }

    // MARK: A first name among the people who spoke

    /// A call where the owner spoke with the given people, and where the invite names the others.
    private func call(speakers: [String], invited: [String] = []) -> CallRecord {
        var r = call()
        r.speakerNames = ["me:A": owner]
        for (i, name) in speakers.enumerated() { r.speakerNames["them:\(Character(UnicodeScalar(65 + i)!))"] = name }
        r.invitees = invited.isEmpty ? nil : invited.map { Invitee(name: $0, email: nil) }
        return r
    }

    func testAFirstNameFromTheModelIsThePersonOnlyUnderAllFiveConditions() {
        let r = call(speakers: ["Sam Carter"])
        // The rule: the model gave "Sam", one speaker has that first name, and that speaker is a saved person.
        XCTAssertEqual(saved.subject(of: "Sam reports to you.", about: "Sam", in: r, firstName: true)?.id, sam.id.rawValue)
        // 1. Only the model's own person field: a first name in the claim is still a guess.
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: nil, in: r, firstName: true))
        // 2. Only among the people who spoke: an invited person who did not speak does not count.
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: "Sam", in: call(speakers: ["Riley Chen"], invited: ["Sam Carter"]), firstName: true))
        // 3. Exactly one speaker with that first name, and no other speaker or invited person with it.
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: "Sam", in: call(speakers: ["Sam Carter", "Sam Ortiz"]), firstName: true))
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: "Sam", in: call(speakers: ["Sam Carter"], invited: ["Sam Ortiz"]), firstName: true))
        XCTAssertEqual(saved.subject(of: "Sam reports to you.", about: "Sam", in: call(speakers: ["Sam Carter"], invited: ["Sam Carter"]), firstName: true)?.id,
                       sam.id.rawValue, "the invite of the same person is not another person")
        //    The owner's own first name gives nobody.
        XCTAssertNil(saved.subject(of: "Dana owns the budget.", about: "Dana", in: r, firstName: true))
        XCTAssertNil(saved.subject(of: "Dana owns the budget.", about: "Dana", in: call(speakers: ["Dana Ruiz"]), firstName: true), "a speaker who shares the owner's first name")
        // 4. That speaker is a saved person on a sure match of the whole name.
        XCTAssertNil(saved.subject(of: "Pat decides the budget.", about: "Pat", in: call(speakers: ["Pat Moreno"]), firstName: true))
        XCTAssertNil(CoachPeople(people: [dana, sam, person("Sam Carter")]).subject(of: "Sam reports to you.", about: "Sam", in: r, firstName: true))
        // 5. Only for a conclusion that is still a card: older data keeps the whole-name rule.
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: "Sam", in: r))
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: "Sam", in: r, firstName: false))
        // No nicknames, and a first name that is only almost right gives nobody.
        XCTAssertNil(saved.subject(of: "Sammy reports to you.", about: "Sammy", in: r, firstName: true))
        XCTAssertNil(saved.subject(of: "Sa reports to you.", about: "Sa", in: r, firstName: true))
    }

    func testOnlyANewConclusionThatIsACardUsesTheFirstNameAndTheMoveOfOlderDataDoesNot() {
        var profile = CoachProfile()
        var q = question(about: "Sam")
        profile.ask([q])
        XCTAssertEqual(profile.linkPeople(saved, records: [call()]), 0, "an older conclusion keeps the whole-name rule")
        XCTAssertNil(profile.questions[0].person)
        q.at = nil
        XCTAssertFalse(CoachPeople.isCard(q), "a conclusion with no moment is no card")
        XCTAssertTrue(CoachPeople.isCard(question(about: "Sam")))
    }

    // MARK: Ids that point to nobody, and former names

    func testAnIDThatIsNotInThePeopleStoreIsNoIDAndIsLinkedAgain() {
        var profile = learned()
        profile.questions = [question()]
        profile.questions[0].status = .confirmed
        profile.questions[0].person = "gone-id"
        profile.questions[0].personName = "Sam Carter"
        for i in profile.facts.indices { profile.facts[i].person = "gone-id" }
        profile.people["Sam Carter"]?.person = "gone-id"
        // The people store started again: each person has a new id.
        XCTAssertGreaterThan(profile.linkPeople(saved, records: [call()]), 0)
        XCTAssertEqual(profile.people["Sam Carter"]?.person, sam.id.rawValue)
        XCTAssertEqual(profile.questions[0].person, sam.id.rawValue)
        XCTAssertTrue(profile.facts.filter { $0.text == "Sam reports to you." }.allSatisfy { $0.person == sam.id.rawValue })
        // A stale id with no sure match is cleared, not kept.
        var lone = CoachProfile()
        lone.updateFacts(add: [CoachFact(kind: .context, text: "The Monday call is for decisions.", person: "gone-id")], remove: [], at: base)
        lone.linkPeople(saved, records: [])
        XCTAssertNil(lone.facts[0].person)
    }

    func testANameThatAnotherPersonHadBeforeIsNotThatPerson() {
        var jordan = person("Jordan Blake")
        _ = jordan.addForm("Sam Carter", kind: .former, source: .owner, confirmed: true, at: base)
        // Nobody has the name now: a former name of another person is not a sure match.
        XCTAssertNil(CoachPeople(people: [dana, jordan, riley]).id(of: "Sam Carter"))
        XCTAssertNil(CoachPeople(people: [dana, jordan, riley]).subject(of: "Sam Carter reports to you.", about: "Sam Carter", in: call()))
        // The person who has the name now is still found.
        XCTAssertEqual(CoachPeople(people: [dana, jordan, sam]).id(of: "Sam Carter"), sam.id.rawValue)
    }

    func testANoteWithNoIDDoesNotReplaceTheNoteOfAPersonUnderTheSameName() {
        var profile = CoachProfile()
        var known = CoachPerson(note: "Sam wants the answer first.", calls: 3, lastSeen: base)
        known.person = sam.id.rawValue
        profile.people["S. Carter"] = known
        profile.people["Sam Carter"] = CoachPerson(note: "An older note.", calls: 1, lastSeen: base.addingTimeInterval(day))
        // Two saved people have the name "Sam Carter": the note under that name has no id.
        let other = person("Sam Carter")
        profile.linkPeople(CoachPeople(people: [dana, sam, other, riley]), records: [])
        XCTAssertEqual(profile.people.count, 2)
        XCTAssertEqual(profile.people.values.filter { $0.person == sam.id.rawValue }.map(\.note), ["Sam wants the answer first."])
        XCTAssertEqual(profile.people.values.filter { $0.person == nil }.map(\.note), ["An older note."])
    }

    // MARK: On the person page

    func testWhatTheOwnerConfirmedAboutAPersonIsFoundByIDAndByTheLabelOnTheIPhone() {
        let profile = learned()
        XCTAssertEqual(profile.learnings(about: sam.id.rawValue, people: saved).map(\.text), ["Sam reports to you."])
        // The iPhone has no people store: the label of the note gives the id.
        XCTAssertEqual(profile.learnings(named: "Sam Carter").map(\.text), ["Sam reports to you."])
        XCTAssertEqual(profile.learnings(named: "Riley Chen"), [])
    }

    // MARK: Second review fixes

    func testAFirstNameLinkGoesToAFactOnlyThroughTheCardThatShowsTheWholeName() {
        var q = question(about: "Sam")
        let subject = saved.subject(of: q.statement, about: q.about, in: call(speakers: ["Sam Carter"]), firstName: true)
        q.person = subject?.id
        q.personName = subject?.name
        XCTAssertEqual(q.person, sam.id.rawValue)
        // A yes on a question row, which does not show the person: the fact gets no id, also at the next launch.
        var row = CoachProfile()
        row.ask([q])
        row.answer(q.id, .confirmed, note: nil, at: base)
        row.linkPeople(saved, records: [call(speakers: ["Sam Carter"])])
        XCTAssertEqual(row.facts.map(\.person), [nil])
        // A yes on the card, which shows "About Sam Carter": the fact has the id.
        var card = CoachProfile()
        card.ask([q])
        card.answer(deck(card)[0], .yes, at: base)
        card.linkPeople(saved, records: [call(speakers: ["Sam Carter"])])
        XCTAssertEqual(card.facts.map(\.person), [sam.id.rawValue])
        // A whole name from the model is a sure match on any path.
        var whole = CoachProfile()
        var w = question()
        w.person = sam.id.rawValue
        whole.ask([w])
        whole.answer(w.id, .confirmed, note: nil, at: base)
        whole.linkPeople(saved, records: [call()])
        XCTAssertEqual(whole.facts.map(\.person), [sam.id.rawValue])
    }

    func testAnInvitedPersonWithOnlyAnAddressCountsForTheFirstName() {
        var r = call(speakers: ["Sam Carter"])
        r.invitees = [Invitee(name: nil, email: "sam.ortiz@example.com")]
        XCTAssertNil(saved.subject(of: "Sam reports to you.", about: "Sam", in: r, firstName: true))
        r.invitees = [Invitee(name: nil, email: "sam.carter@example.com")]
        XCTAssertEqual(saved.subject(of: "Sam reports to you.", about: "Sam", in: r, firstName: true)?.id, sam.id.rawValue, "the speaker's own address")
    }
}
