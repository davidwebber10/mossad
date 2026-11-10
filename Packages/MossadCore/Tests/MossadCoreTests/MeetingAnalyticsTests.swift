import XCTest
@testable import MossadCore

/// The numbers of one call for the meeting page's Analytics tab.
final class MeetingAnalyticsTests: XCTestCase {
    private typealias Line = (key: String, start: Double, end: Double, text: String)

    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let trio = ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Jo Park"]

    private func call(id: String = "c", daysAgo: Double = 0, minutes: Double = 30, names: [String: String]? = nil, title: String? = "Weekly sync",
                      _ lines: [Line] = []) -> CallRecord {
        let begin = start.addingTimeInterval(-daysAgo * 86_400)
        var r = CallRecord(id: id, platform: .meet, bundleID: "", start: begin, end: begin.addingTimeInterval(minutes * 60), status: .written)
        r.speakerNames = names ?? trio
        r.calendarTitle = title
        r.summary = "A summary."
        r.utterances = lines.map(utterance)
        return r
    }

    private func utterance(_ l: Line) -> Utterance {
        let parts = l.key.split(separator: ":")
        return Utterance(track: parts[0] == "me" ? .me : .them, speakerLabel: String(parts[1]), start: l.start, end: l.end, text: l.text)
    }

    /// A line with word times: each word takes `pace` seconds, and `pauses` adds silence before the word at an index.
    private func timed(_ key: String, _ begin: Double, _ text: String, pace: Double = 0.5, pauses: [Int: Double] = [:]) -> Utterance {
        var t = begin
        let words = text.split(separator: " ").enumerated().map { i, w -> Word in
            t += pauses[i] ?? 0
            defer { t += pace }
            return Word(text: String(w), start: t, end: t + pace)
        }
        var u = utterance((key, begin, t, text))
        u.words = words
        return u
    }

    private func analytics(_ r: CallRecord, owner: String = "Dana Lee") -> MeetingAnalytics { MeetingAnalytics(record: r, owner: owner) }

    // MARK: Talk time

    func testTalkTimeListsTheOwnerFirstThenTheMostTalk() {
        let a = analytics(call(names: ["me:A": "Dana Lee", "them:A": "Sam Carter"], [
            ("them:A", 0, 60, "Morning all."),
            ("me:A", 60, 80, "Morning."),
            ("them:B", 80, 100, "Hello."),
            ("them:A", 100, 120, "Shall we start?"),
        ]))
        XCTAssertEqual(a.speakers.map(\.name), ["Dana Lee", "Sam Carter", "Speaker A"])
        XCTAssertEqual(a.speakers.map(\.id), ["me:A", "them:A", "them:B"])
        XCTAssertEqual(a.speakers.map(\.seconds), [20, 80, 20])
        XCTAssertEqual(a.speakers.map(\.isOwner), [true, false, false])
        XCTAssertEqual(a.speakers.map(\.isUnknown), [false, false, true])
        XCTAssertEqual(a.speechSeconds, 120)
        XCTAssertEqual(a.ownerShare!, 20.0 / 120, accuracy: 0.0001)
        XCTAssertEqual(a.speakers[1].share, 80.0 / 120, accuracy: 0.0001)
        XCTAssertEqual(a.duration, 1800)
    }

    func testAPersonWithTwoKeysIsOneSpeaker() {
        let a = analytics(call(names: ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:C": "Sam Carter"], [
            ("them:A", 0, 10, "One."), ("me:A", 10, 20, "Two."), ("them:C", 20, 40, "Three."),
        ]))
        XCTAssertEqual(a.speakers.map(\.name), ["Dana Lee", "Sam Carter"])
        XCTAssertEqual(a.speakers[1].seconds, 30)
        XCTAssertEqual(a.speakers[1].turns, 2)
    }

    func testTheOwnersShareIsNilWhenTheOwnerDidNotSpeak() {
        let a = analytics(call([("them:A", 0, 10, "Only me here.")]))
        XCTAssertNil(a.ownerShare)
        XCTAssertNil(a.owner)
    }

    func testTheFloorGivesEachStretchToWhoTalkedMostInIt() {
        // 120 buckets over 20 minutes are 10 s each.
        let a = analytics(call(minutes: 20, [
            ("them:A", 0, 30, "A long start."),
            ("me:A", 30, 34, "Short."),
            ("them:A", 31, 40, "Goes on over it."),
            ("them:B", 100, 101, "Hm."),
            ("me:A", 600, 620, "Much later."),
        ]))
        XCTAssertEqual(a.floor, [
            .init(start: 0, end: 40, speaker: "them:A"),
            .init(start: 600, end: 620, speaker: "me:A"),
        ], "one second of speech in ten is nobody's stretch")
    }

    // MARK: Turns and delivery

    func testTurnsFollowTheCoachsRuleForEveryone() {
        let r = call([
            ("me:A", 0, 40, "First part of a long answer."),
            ("me:A", 41, 100, "Second part, one breath later."),
            ("them:A", 101, 110, "Thanks."),
            ("me:A", 111, 120, "Sure."),
            ("me:A", 125, 130, "After a pause."),
            ("them:A", 131, 151, "A longer reply here."),
        ])
        let a = analytics(r)
        let dana = a.speakers[0], sam = a.speakers[1]
        XCTAssertEqual(dana.turns, 3)
        XCTAssertEqual(dana.longestTurn, .init(start: 0, seconds: 100))
        XCTAssertEqual(dana.averageTurn, 9, accuracy: 0.0001, "the typical turn is the median of 100, 9, and 5")
        XCTAssertEqual(sam.turns, 2)
        XCTAssertEqual(sam.longestTurn, .init(start: 131, seconds: 20))
        XCTAssertEqual(a.flow?.turns, 5)
        let coach = CallMetrics(record: r, owner: "Dana Lee", history: [])
        XCTAssertEqual(dana.longestTurn?.seconds, coach.longestTurn?.seconds, "the Coach tab shows the same longest turn")
        XCTAssertEqual(dana.longestTurn?.start, coach.longestTurn?.start)
    }

    func testTheOwnersDeliveryIsTheCoachsDelivery() {
        let r = call([
            ("me:A", 0, 30, "Um, so the plan is, uh, to ship on Friday. Does that work?"),
            ("them:A", 31, 61, "Yes. Hmm, what about the budget? And who signs?"),
            ("me:A", 62, 92, "I sign. Um, the budget is fine."),
        ])
        let a = analytics(r)
        let d = DeliveryStats(record: r, owner: "Dana Lee")
        let dana = a.speakers[0], sam = a.speakers[1]
        XCTAssertEqual(dana.words, d.words)
        XCTAssertEqual(dana.wordsPerMinute!, d.wordsPerMinute, accuracy: 0.0001)
        XCTAssertEqual(dana.fillers, d.fillers)
        XCTAssertEqual(dana.fillers, 3)
        XCTAssertEqual(dana.fillersPerMinute!, d.fillersPerMinute, accuracy: 0.0001)
        XCTAssertEqual(dana.questions, d.questions)
        XCTAssertEqual(a.ownerShare!, d.talkShare, accuracy: 0.0001)
        XCTAssertEqual(sam.words, 9)
        XCTAssertEqual(sam.fillers, 1)
        XCTAssertEqual(sam.questions, 1, "a line with two question marks is one line with a question")
        XCTAssertEqual(sam.wordsPerMinute!, 18, accuracy: 0.0001)
    }

    func testAPaceNeedsTwentySecondsOfSpeech() {
        let a = analytics(call([("me:A", 0, 19, "Too short to time."), ("them:A", 20, 40, "Just long enough to time.")]))
        XCTAssertNil(a.speakers[0].wordsPerMinute)
        XCTAssertNil(a.speakers[0].fillersPerMinute)
        XCTAssertEqual(a.speakers[0].words, 4)
        XCTAssertNotNil(a.speakers[1].wordsPerMinute)
    }

    // MARK: Interruptions and overlaps

    func testAnInterruptionIsALateStartThatTakesTheFloor() {
        let a = analytics(call([
            ("them:A", 0, 20, "Here is the plan for the whole quarter."),
            ("me:A", 15, 30, "Wait, that date is wrong."),
            ("me:A", 40, 50, "Next topic is hiring."),
            ("them:A", 44, 60, "Before that, one more thing."),
            ("me:A", 62, 80, "Fine, then hiring it is."),
            ("them:B", 70, 90, "Sorry, also the budget."),
        ]))
        let flow = a.flow!
        XCTAssertTrue(flow.crossTalkMeasured)
        XCTAssertEqual(flow.interruptions, [
            .init(by: "me:A", of: "them:A", moments: [15]),
            .init(by: "them:A", of: "me:A", moments: [44]),
            .init(by: "them:B", of: "me:A", moments: [70]),
        ])
        XCTAssertEqual(flow.interruptionCount, 3)
        XCTAssertEqual(a.speakers.map(\.interruptionsMade), [1, 1, 1])
        XCTAssertEqual(a.speakers.map(\.interruptionsReceived), [2, 1, 0])
        XCTAssertEqual(flow.overlaps, [
            .init(first: "me:A", second: "them:A", count: 2, seconds: 11),
            .init(first: "me:A", second: "them:B", count: 1, seconds: 10),
        ])
        XCTAssertEqual(flow.overlapSeconds, 21)
    }

    func testTwoPeopleOfTheCallAreNeverCountedAgainstEachOther() {
        // The call track holds one line after the other: two of its people who talk at once leave no trace in a
        // real record. So lines of one track that do overlap count for nothing, and nobody "cut in 0 times".
        let a = analytics(call([
            ("me:A", 0, 5, "Go ahead."),
            ("them:A", 10, 30, "Here is the plan for the whole quarter."),
            ("them:B", 20, 45, "Wait, that date is wrong, I think."),
        ]))
        XCTAssertEqual(a.flow?.interruptions, [])
        XCTAssertEqual(a.flow?.overlaps, [])
        XCTAssertEqual(a.flow?.crossTalkMeasured, true, "Dana's microphone is the other track")
        XCTAssertEqual(a.speakers.map(\.interruptionsMade), [0, 0, 0], "each person against the other track only")
    }

    func testACallOnOneTrackHasNoCountOfCutInsAtAll() {
        // A meeting in a room: every voice is on the microphone.
        let a = analytics(call(names: ["me:A": "Dana Lee", "me:B": "Sam Carter"], [
            ("me:A", 0, 20, "Here is the plan for the whole quarter."),
            ("me:B", 15, 40, "Wait, that date is wrong, I think."),
        ]))
        XCTAssertEqual(a.flow?.crossTalkMeasured, false)
        XCTAssertEqual(a.speakers.map(\.interruptionsMade), [nil, nil], "not measured is not 0")
        XCTAssertEqual(a.speakers.map(\.interruptionsReceived), [nil, nil])
        XCTAssertEqual(a.flow?.overlaps, [])
        XCTAssertNotNil(a.flow?.medianResponse ?? a.flow?.silenceSeconds, "the rest of the flow does not need two tracks")
    }

    func testListeningAndTalkingAlongAreNotInterruptions() {
        let a = analytics(call([
            ("them:A", 0, 60, "A long explanation of the plan."),
            ("me:A", 10, 12, "Yeah."),
            ("me:A", 20, 30, "Right, and the budget too."),
            ("me:A", 59.5, 70, "Thanks, my turn now."),
            ("me:A", 100, 110, "Both of us start."),
            ("them:B", 100.5, 115, "At the same moment here."),
        ]))
        let flow = a.flow!
        XCTAssertEqual(flow.interruptions, [], "a word, a line the other talks through, a hand-off, and a joint start")
        XCTAssertEqual(flow.overlaps.map(\.id), ["me:A|them:A", "me:A|them:B"])
        XCTAssertEqual(flow.overlaps.first { $0.id == "me:A|them:A" }?.count, 2, "half a second together at the hand-off is not one")
        XCTAssertEqual(flow.overlaps.first { $0.id == "me:A|them:B" }?.seconds, 9.5)
    }

    func testAnAgreementSaidAcrossAPauseIsNotAnInterruption() {
        // Sam talks for 10 s, stops for 1.2 s, and goes on in the same line. Dana agrees across the pause.
        var r = call()
        r.utterances = [timed("them:A", 0, "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty", pauses: [10: 1.2]),
                        timed("me:A", 4, "yeah that makes sense", pace: 0.4)]
        let flow = analytics(r).flow!
        XCTAssertEqual(flow.overlaps.map(\.count), [1], "they did talk at once")
        XCTAssertEqual(flow.interruptions, [], "but Dana did not hold the floor for 3 s after Sam stopped")
    }

    func testWordTimesShowThatAPauseInALineIsNotSpeech() {
        // Sam's one line pauses for ten seconds after its fourth word; Dana talks only in that pause.
        var r = call()
        let sam = timed("them:A", 0, "This is the first half and this is the second half", pauses: [4: 10])
        let dana = timed("me:A", 4, "I will take that question now")
        r.utterances = [sam, dana]
        XCTAssertEqual(sam.end, 15.5)
        XCTAssertEqual(analytics(r).flow?.overlaps, [], "with word times nobody talked at once")
        XCTAssertEqual(analytics(r).flow?.interruptions, [])

        r.utterances = [sam, dana].map { var u = $0; u.words = nil; return u }
        XCTAssertEqual(analytics(r).flow?.overlaps.map(\.count), [1], "without them the lines can only be taken whole")
        XCTAssertEqual(analytics(r).flow?.interruptions, [], "and Dana stopped first, so it is still no interruption")
    }

    func testWordTimesFindTheInterruptionInsideALongLine() {
        var r = call()
        // Sam stops at 5 s (ten words); Dana starts at 3 s and goes on to 8 s.
        r.utterances = [timed("them:A", 0, "one two three four five six seven eight nine ten"),
                        timed("me:A", 3, "no wait that is not what we agreed on last week")]
        let flow = analytics(r).flow!
        XCTAssertEqual(flow.interruptions, [.init(by: "me:A", of: "them:A", moments: [3])])
        XCTAssertEqual(flow.overlaps, [.init(first: "me:A", second: "them:A", count: 1, seconds: 2)])
    }

    // MARK: Answers and silence

    func testAnAnswerIsATurnThatBeginsSoonAfterSomeoneElseStopped() {
        let a = analytics(call([
            ("them:A", 0, 10, "Ready?"),
            ("me:A", 11, 20, "Yes."),
            ("them:A", 23, 30, "Good."),
            ("me:A", 29, 40, "Overlapping is not an answer."),
            ("them:B", 40.5, 50, "A quick one."),
            ("them:B", 55, 60, "My own pause is not an answer."),
            ("me:A", 80, 90, "Twenty seconds later is a new thought."),
            ("them:A", 91, 95, "Agreed."),
        ]))
        XCTAssertEqual(a.speakers[0].medianResponse, 1, "Dana answered one time, after 1 s")
        XCTAssertEqual(a.speakers[1].medianResponse, 2, "Sam after 3 s and after 1 s")
        XCTAssertEqual(a.speakers[2].medianResponse, 0.5)
        XCTAssertEqual(a.flow?.medianResponse, 1)
    }

    func testAWordSaidWhileSomeoneTalksIsNotWhatTheNextPersonAnswers() {
        let a = analytics(call([
            ("them:A", 0, 60, "A long explanation."),
            ("me:A", 20, 21, "Yeah."),
            ("them:B", 22, 30, "Talking over it."),
            ("them:B", 62, 70, "Now I answer Sam."),
        ]))
        XCTAssertEqual(a.speakers.first { $0.id == "them:B" }?.medianResponse, 2)
        XCTAssertNil(a.speakers.first { $0.id == "me:A" }?.medianResponse)
    }

    func testSilenceIsThePausesOfThreeSecondsBetweenTheFirstWordAndTheLast() {
        let a = analytics(call([
            ("them:A", 100, 110, "We begin late."),
            ("me:A", 112, 120, "A two second pause does not count."),
            ("them:A", 150, 160, "Thirty seconds of nothing."),
            ("me:A", 164, 200, "Four more."),
        ]))
        let flow = a.flow!
        XCTAssertEqual(flow.silenceSeconds, 34)
        XCTAssertEqual(flow.longestSilence, .init(start: 120, seconds: 30))
        XCTAssertEqual(flow.silenceShare, 0.34, accuracy: 0.0001, "of the 100 s from the first word to the last")
    }

    // MARK: Participation

    func testInvitedPeopleAreMatchedToTheVoices() {
        var r = call(names: ["me:A": "Dana Lee", "them:A": "Sam Carter", "them:B": "Riley Chen"], [
            ("me:A", 0, 10, "Hi."), ("them:A", 10, 20, "Hi."), ("them:B", 20, 30, "Hi."),
        ])
        r.attendees = ["dana@example.com", "Samuel Carter", "Jordan Lee", "casey@example.com", "sam.carter@example.com"]
        let people = PersonDirectory([.init(name: "Dana Lee", email: "dana@example.com"), .init(name: "Sam Carter", email: "sam.carter@example.com"),
                                      .init(name: "Jordan Lee", email: nil)])
        var p = MeetingAnalytics(record: r, owner: "Dana Lee", people: people).participation!
        XCTAssertEqual(p.invited.map(\.label), ["Dana Lee", "Samuel Carter", "Jordan Lee", "casey@example.com"], "Sam by name and by email is one entry")
        XCTAssertEqual(p.invited.map(\.person), ["Dana Lee", "Sam Carter", "Jordan Lee", nil])
        XCTAssertEqual(p.invited.map(\.speaker), ["me:A", "them:A", nil, nil])
        XCTAssertEqual(p.invited.map(\.email), ["dana@example.com", nil, nil, "casey@example.com"])
        XCTAssertEqual(p.spoke.map(\.label), ["Dana Lee", "Samuel Carter"])
        XCTAssertEqual(p.didNotSpeak.map(\.label), ["Jordan Lee"], "a saved person with no voice, in a call where every voice has a name")
        XCTAssertEqual(p.notMatched.map(\.label), ["casey@example.com"], "an email nobody saved: Mossad does not know who it is")
        XCTAssertEqual(p.unmatchedSpeakers, ["them:B"])
        XCTAssertEqual(p.uninvited, [], "Riley can be casey@example.com, so Riley is not \"without an invite\"")
        XCTAssertEqual(MeetingFindings.participation(p), "At least 2 of 4 invited people spoke; 1 invited entry is not matched to a person")

        r.attendees.removeAll { $0 == "casey@example.com" }
        p = MeetingAnalytics(record: r, owner: "Dana Lee", people: people).participation!
        XCTAssertTrue(p.isMatched)
        XCTAssertEqual(p.uninvited, ["them:B"], "with every entry matched, Riley spoke with no invite")
        XCTAssertEqual(MeetingFindings.participation(p), "2 of 3 invited people spoke")
    }

    func testAnInvitedEmailOfSomeoneWhoSpokeIsNotSilence() {
        // The review's case: the invite has an email that nobody saved, and Sam Carter spoke.
        var r = call([("me:A", 0, 10, "Hi."), ("them:A", 10, 20, "Hi.")])
        r.attendees = ["sam@x.com"]
        let p = analytics(r).participation!
        XCTAssertEqual(p.didNotSpeak, [])
        XCTAssertEqual(p.notMatched.map(\.label), ["sam@x.com"])
        XCTAssertEqual(p.uninvited, [])
        XCTAssertEqual(p.unmatchedSpeakers, ["them:A"])
        XCTAssertEqual(MeetingFindings.participation(p), "At least 0 of 1 invited person spoke; 1 invited entry is not matched to a person")
    }

    func testAnInvitedFirstNameFindsItsSpeakerWithNoSavedPeople() {
        var r = call([("me:A", 0, 10, "Hi."), ("them:A", 10, 20, "Hi.")])
        r.attendees = ["Sam", "Dana Lee", "Dana Lee"]
        let p = analytics(r).participation!
        XCTAssertEqual(p.invited.map(\.speaker), ["them:A", "me:A"], "and a name invited twice is one person")
        XCTAssertEqual(p.invited.map(\.person), [nil, nil])
        XCTAssertEqual(p.uninvited, [])
        XCTAssertEqual(MeetingFindings.participation(p), "All 2 invited people spoke")
    }

    func testAnInvitedPersonWithNoVoiceIsNotCalledSilentWhileAVoiceHasNoName() {
        var r = call(names: ["me:A": "Dana Lee"], [("me:A", 0, 10, "Hi."), ("them:A", 10, 20, "Hi."), ("them:B", 20, 30, "Hi.")])
        r.attendees = ["Sam Carter", "Jo Park"]
        let people = PersonDirectory([.init(name: "Sam Carter", email: nil)])
        let p = MeetingAnalytics(record: r, owner: "Dana Lee", people: people).participation!
        XCTAssertEqual(p.unnamedVoices, 2)
        XCTAssertEqual(p.withoutVoice.map(\.label), ["Sam Carter"])
        XCTAssertEqual(p.didNotSpeak, [], "Sam can be one of the two voices with no name")
        XCTAssertEqual(p.notMatched.map(\.label), ["Jo Park"], "a name nobody saved and nobody in the call has")
        XCTAssertEqual(p.uninvited, [])
        XCTAssertEqual(MeetingFindings.participation(p), "At least 0 of 2 invited people spoke; 1 invited entry is not matched to a person, and 2 voices have no name yet")
        XCTAssertNil(analytics(call([("me:A", 0, 10, "Hi.")])).participation, "no invite, no part")
    }

    // MARK: Outcomes, coach, screens, cost

    func testActionItemsAreGroupedByTheirOwner() {
        var r = call([("me:A", 0, 10, "Hi."), ("them:A", 10, 20, "Hi.")])
        r.decisions = [Decision(text: "Ship on Friday", at: 5)]
        r.actionItems = [ActionItem(owner: "Riley", task: "Book the room"), ActionItem(owner: nil, task: "Find a date"),
                         ActionItem(owner: "Sam", task: "Send the budget"), ActionItem(owner: "Sam Carter", task: "Call finance"),
                         ActionItem(owner: "Dana Lee", task: "Write the notes")]
        var mine = Commitment(text: "Write the notes", to: nil, callID: "c", callTitle: nil, madeAt: start, due: nil)
        mine.done = start
        var gone = Commitment(text: "Deleted", to: nil, callID: "c", callTitle: nil, madeAt: start, due: nil)
        gone.deleted = true
        let other = Commitment(text: "From another call", to: nil, callID: "x", callTitle: nil, madeAt: start, due: nil)
        let o = MeetingAnalytics(record: r, owner: "Dana Lee", commitments: [mine, gone, other]).outcomes!
        XCTAssertEqual(o.decisions, 1)
        XCTAssertEqual(o.actionItems, 5)
        XCTAssertEqual(o.owners.map(\.name), ["Sam Carter", "Riley", "Dana Lee", nil])
        XCTAssertEqual(o.owners.map(\.speaker), ["them:A", nil, "me:A", nil])
        XCTAssertEqual(o.owners[0].tasks, ["Send the budget", "Call finance"])
        XCTAssertEqual(o.tasks, [.init(id: mine.id, text: "Write the notes", done: true)])
        XCTAssertEqual(MeetingFindings.outcomes(o), "1 decision and 5 action items")
        XCTAssertNil(analytics(call([("me:A", 0, 10, "Hi.")])).outcomes)
    }

    func testAnOwnerWrittenAsAFirstNameKeepsThatNameAndCountsWithItsOneSpeaker() {
        var r = call([("me:A", 0, 10, "Hi."), ("them:A", 10, 20, "Hi.")])
        r.actionItems = [ActionItem(owner: "Sam", task: "Send the budget"), ActionItem(owner: "sam", task: "Call finance")]
        var o = analytics(r).outcomes!
        XCTAssertEqual(o.owners.map(\.name), ["Sam"], "the row says what the items say, so a first name is never a link")
        XCTAssertEqual(o.owners.map(\.speaker), ["them:A"], "but the two items are counted with the one Sam who spoke")
        XCTAssertEqual(o.owners[0].tasks.count, 2)
        // A second Sam was invited: nobody can say whose items they are.
        r.attendees = ["Sam Lee"]
        o = analytics(r).outcomes!
        XCTAssertEqual(o.owners.map(\.speaker), [nil])
        XCTAssertEqual(o.owners.map(\.name), ["Sam"])
    }

    func testTheCoachPartIsTheReviewsValueAndScores() {
        let r = call([("me:A", 0, 10, "Hi.")])
        let card = Scorecard(score: 4, reason: "Clear", dimensions: [.init(name: "Clarity", score: 5)], positives: [], negatives: [])
        let value = MeetingValue(rating: .high, reason: "Decisions were made", action: .keep, suggestion: "Keep it")
        let review = CoachReview(headline: "Good", overview: "", strengths: [], improvements: [], focusProgress: nil, value: value, scorecard: card)
        let coach = MeetingAnalytics(record: r, owner: "Dana Lee", review: review).coach
        XCTAssertEqual(coach, .init(value: value, scorecard: card))
        XCTAssertEqual(MeetingFindings.coach(coach!), "The coach scored the call 4 of 5 and rated the meeting high value")
        XCTAssertNil(analytics(r).coach)
        let bare = CoachReview(headline: "Old", overview: "", strengths: [], improvements: [], focusProgress: nil)
        XCTAssertNil(MeetingAnalytics(record: r, owner: "Dana Lee", review: bare).coach, "an old review has neither")
    }

    func testScreensAreCountedPerPresenter() {
        var r = call([("me:A", 0, 10, "Hi.")])
        r.screens = [
            SharedScreen(offset: 100, file: "a", text: "", presenter: "Sam Carter", session: 0),
            SharedScreen(offset: 400, file: "b", text: "", presenter: "Sam Carter", session: 0),
            SharedScreen(offset: 600, file: "c", text: "", presenter: nil, session: 1),
            SharedScreen(offset: 900, file: "d", text: "", presenter: "Sam Carter", session: 2),
            SharedScreen(offset: 960, file: "e", text: "", presenter: "Sam Carter", session: 2),
        ]
        let s = analytics(r).screens!
        XCTAssertEqual(s.presenters, [
            .init(name: "Sam Carter", sessions: 2, screens: 4, seconds: 360, first: 100),
            .init(name: nil, sessions: 1, screens: 1, seconds: 0, first: 600),
        ])
        XCTAssertEqual(s.screens, 5)
        XCTAssertEqual(MeetingFindings.screens(s), .init("5 screens were shared over 6 min"))
        r.screens = Array(r.screens!.prefix(2))
        XCTAssertEqual(MeetingFindings.screens(analytics(r).screens!), .init(subject: "Sam Carter", "shared 2 screens over 5 min"))
        r.screens = []
        XCTAssertNil(analytics(r).screens)
    }

    func testTheCostIsWhatTheLogHasForTheCall() {
        let r = call(minutes: 60, [("me:A", 0, 10, "Hi.")])
        func event(_ id: String?, _ service: UsageEvent.Service, _ purpose: UsageEvent.Purpose, audio: Double? = nil, input: Int? = nil) -> UsageEvent {
            UsageEvent(date: start, callID: id, service: service, purpose: purpose, model: service == .claude ? "claude-opus-5-5" : "universal-2",
                       audioSeconds: audio, inputTokens: input)
        }
        let usage = [event("c", .assemblyai, .transcription, audio: 7200), event("c", .claude, .summary, input: 100_000),
                     event("c", .claude, .coach, input: 50_000), event("other", .claude, .summary, input: 900_000),
                     event(nil, .claude, .question, input: 900_000)]
        let cost = MeetingAnalytics(record: r, owner: "Dana Lee", usage: usage).cost!
        XCTAssertEqual(cost.transcription, 2 * (0.15 + 0.02), accuracy: 0.0001)
        XCTAssertEqual(cost.ai, 0.4 + 0.2, accuracy: 0.0001)
        XCTAssertEqual(cost.total, 0.94, accuracy: 0.0001)
        XCTAssertEqual(cost.lines.map(\.purpose), [.transcription, .summary, .coach])
        XCTAssertFalse(cost.estimated)
    }

    func testOnlyACallFromBeforeTheLogGetsTheAnalyticsEstimate() {
        let r = call(minutes: 60, [("me:A", 0, 10, "Hi.")])
        let after = r.end.addingTimeInterval(86_400), before = r.start.addingTimeInterval(-86_400)
        let cost = MeetingAnalytics(record: r, owner: "Dana Lee", usageSince: after).cost!
        XCTAssertTrue(cost.estimated)
        let estimate = Pricing.estimates(for: [r], logged: []).map(Pricing.cost).reduce(0, +)
        XCTAssertEqual(cost.total, estimate, accuracy: 0.0001)
        XCTAssertGreaterThan(cost.transcription, 0)
        XCTAssertGreaterThan(cost.ai, 0)
        XCTAssertNil(MeetingAnalytics(record: r, owner: "Dana Lee", usageSince: before).cost, "the log was there and has nothing for the call: models on this Mac")
        XCTAssertNil(analytics(r).cost, "no log at all says nothing about a price")
        let other = UsageEvent(date: before, callID: "other", service: .claude, purpose: .summary, model: "claude-opus-5-5", inputTokens: 1000)
        XCTAssertNil(MeetingAnalytics(record: r, owner: "Dana Lee", usage: [other]).cost, "the whole log as it is: its first event is before the call")
        let local = UsageEvent(date: start, callID: "c", service: .local, purpose: .transcription, model: nil, audioSeconds: 3600)
        XCTAssertNil(MeetingAnalytics(record: r, owner: "Dana Lee", usage: [local]).cost, "a call transcribed on this Mac cost nothing")
    }

    func testTheUsageLogGivesOneCallsEventsAndItsFirstDate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = UsageLog(directory: dir)
        XCTAssertEqual(log.events(forCall: "c").events, [])
        XCTAssertNil(log.events(forCall: "c").since)
        for (id, day) in [("other", 0.0), ("c", 1), ("c2", 2), ("c", 3)] {
            log.record(UsageEvent(date: start.addingTimeInterval(day * 86_400), callID: id, service: .claude, purpose: .summary, model: "m", inputTokens: 10))
        }
        let found = log.events(forCall: "c")
        XCTAssertEqual(found.events.map(\.callID), ["c", "c"], "not the call whose id only begins the same")
        XCTAssertEqual(found.since, start)
    }

    // MARK: Empty, findings, stamp

    func testACallWithNothingHasNoParts() {
        let a = analytics(call(title: nil))
        XCTAssertTrue(a.speakers.isEmpty)
        XCTAssertNil(a.flow)
        XCTAssertNil(a.cost)
        XCTAssertTrue(a.floor.isEmpty)
        XCTAssertTrue(a.isEmpty)
        XCTAssertNil(MeetingFindings.talk(a))
        XCTAssertNil(MeetingFindings.flow(a))
        XCTAssertNil(MeetingFindings.delivery(a))
    }

    func testTheFindingsNameTheirPerson() {
        let a = analytics(call([
            ("them:A", 0, 200, Array(repeating: "word", count: 500).joined(separator: " ")),
            ("me:A", 150, 250, Array(repeating: "word", count: 200).joined(separator: " ")),
        ]))
        XCTAssertEqual(MeetingFindings.talk(a), .init(subject: "them:A", "talked most: 3 min 20 s, 67% of the talk"))
        XCTAssertEqual(MeetingFindings.flow(a), .init(subject: "them:A", "held the longest turn, 3 min 20 s"))
        XCTAssertEqual(MeetingFindings.delivery(a), .init(subject: "them:A", "spoke fastest, at 150 words a minute"))
        XCTAssertEqual(MeetingFindings.span(48), "48 s")
        XCTAssertEqual(MeetingFindings.span(120), "2 min")
        XCTAssertEqual(MeetingFindings.span(3840), "1 h 4 min")
        XCTAssertEqual(MeetingFindings.pause(0.84), "0.8 s")
    }

    func testAThreeHourCallWithWordTimesIsWorkedOutInWellUnderASecond() {
        // 3,600 lines of 12 words each, two people a second apart, every line with word times.
        var r = call(minutes: 180)
        r.utterances = (0..<3600).map { i in
            timed(i.isMultiple(of: 2) ? "me:A" : "them:A", Double(i) * 3, "one two three four five six seven eight nine ten eleven twelve", pace: 0.3)
        }
        let began = Date()
        let a = analytics(r)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1, "the work must grow with the call, not with its square")
        XCTAssertEqual(a.speakers.map(\.words), [21_600, 21_600])
        XCTAssertEqual(a.flow?.overlapCount, 0, "each line ends 0.6 s into the next: a hand-off")
    }

    func testTheStampChangesWithWhatTheTabReads() {
        var r = call([("me:A", 0, 10, "Hi.")])
        let first = MeetingAnalytics.stamp(r)
        XCTAssertEqual(first, MeetingAnalytics.stamp(r))
        r.summary = "The words of the summary are not read."
        XCTAssertEqual(first, MeetingAnalytics.stamp(r))
        var changes: [CallRecord] = []
        var c = r; c.speakerNames["them:A"] = "Riley Chen"; changes.append(c)
        c = r; c.utterances.append(utterance(("me:A", 10, 20, "More."))); changes.append(c)
        c = r; c.attendees = ["Sam Carter"]; changes.append(c)
        c = r; c.actionItems = [ActionItem(owner: nil, task: "One")]; changes.append(c)
        c = r; c.decisions = [Decision(text: "One")]; changes.append(c)
        c = r; c.screens = [SharedScreen(offset: 1, file: "a", text: "")]; changes.append(c)
        c = r; c.customTitle = "New name"; changes.append(c)
        c = r; c.kind = "Standup"; changes.append(c)
        c = r; c.tags = ["Budget"]; changes.append(c)
        c = r; c.plannedEnd = start; changes.append(c)
        c = r; c.summary = nil; changes.append(c)
        c = r; c.calendarTitle = nil; c.generatedTitle = r.title; changes.append(c)
        for (i, changed) in changes.enumerated() {
            XCTAssertNotEqual(first, MeetingAnalytics.stamp(changed), "change \(i)")
            XCTAssertFalse(MeetingAnalytics.sameInputs(r, changed), "change \(i)")
        }
        var same = r
        same.summary = "Other words."
        same.markdownPath = "/tmp/note.md"
        XCTAssertTrue(MeetingAnalytics.sameInputs(r, same), "the page asks this on each tick of the playback, and gets yes")
    }
}
