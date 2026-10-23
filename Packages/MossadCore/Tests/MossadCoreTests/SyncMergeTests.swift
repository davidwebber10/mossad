import XCTest
@testable import MossadCore

final class SyncMergeTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)

    func testProfilesCombineMemoriesFromBothDevicesAndKeepRemovalsRemoved() {
        var mac = CoachProfile()
        mac.focus = "Close with owners"
        mac.updateFacts(add: [CoachFact(kind: .role, text: "Head of data")], remove: [])
        mac.updateGuidance(add: ["Skip filler advice"], remove: [], at: early)
        var phone = mac
        phone.focus = "Stale focus"
        phone.updateFacts(add: [CoachFact(kind: .responsibility, text: "Vendor contracts")], remove: [])
        mac.updateGuidance(add: [], remove: ["Skip filler advice"], at: late)

        let onMac = mac.merged(with: phone)
        XCTAssertEqual(onMac.focus, "Close with owners", "the Mac's own coaching fields win on the Mac")
        XCTAssertEqual(Set(onMac.facts.map(\.text)), ["Head of data", "Vendor contracts"])
        XCTAssertTrue(onMac.guidance.isEmpty, "a removal on one device is not undone by the other")

        let onPhone = phone.merged(with: mac, takeCoaching: true)
        XCTAssertEqual(onPhone.focus, "Close with owners", "the phone takes the Mac's coaching fields")
        XCTAssertTrue(onPhone.guidance.isEmpty)
        XCTAssertEqual(Set(onPhone.facts.map(\.text)), ["Head of data", "Vendor contracts"])
    }

    func testAddingBackSomethingRemovedWorks() {
        var p = CoachProfile()
        p.updateGuidance(add: ["A"], remove: [], at: early)
        p.updateGuidance(add: [], remove: ["A"], at: early)
        p.updateGuidance(add: ["A"], remove: [], at: late)
        XCTAssertEqual(p.merged(with: CoachProfile()).guidance.map(\.text), ["A"])
    }

    func testReviewNotesCombineRatingsAndThreads() {
        let base = CoachReview(headline: "H", overview: "O", strengths: [], improvements: [], focusProgress: nil)
        var mac = base, phone = base
        let shared = ChatMessage(role: .user, text: "Hi")
        mac.thread = [shared]
        phone.thread = [shared, ChatMessage(role: .assistant, text: "From the phone")]
        mac.feedback["A"] = CoachFeedback(agree: true, note: nil, date: early)
        phone.feedback["A"] = CoachFeedback(agree: false, note: "No", date: late)
        phone.feedback["B"] = CoachFeedback(agree: true, note: nil, date: early)
        let merged = mac.mergingNotes(from: phone)
        XCTAssertEqual(merged.thread.map(\.text), ["Hi", "From the phone"])
        XCTAssertEqual(merged.feedback["A"]?.agree, false, "the newer rating wins")
        XCTAssertNotNil(merged.feedback["B"])
    }

    func testTheNewerChatWins() {
        var a = Chat(title: "A")
        a.updated = early
        var b = a
        b.messages = [ChatMessage(role: .user, text: "newer")]
        b.updated = late
        XCTAssertEqual(Chat.newer(a, b).messages.count, 1)
        XCTAssertEqual(Chat.newer(b, a).messages.count, 1)
    }

    func testSharedPayloadsOnlyUploadChangesAndDeleteRemovedChats() {
        var state = SyncState()
        let chat = Chat(title: "A")
        let p1 = SharedPayload.chat(chat)
        state.uploaded[p1.key] = p1.hash
        state.uploaded["chat:gone"] = "x"
        var edited = chat
        edited.title = "B"
        let plan = state.planShared([SharedPayload.chat(edited)])
        XCTAssertEqual(plan.upload.map(\.key), [p1.key])
        XCTAssertEqual(plan.delete, ["chat:gone"])
    }
}
