import XCTest
@testable import MossadCore

/// Dismiss hides one suggestion and teaches nothing; "Dismiss suggestions like this" also lowers its kind.
final class SuggestionDismissTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ n: Int, _ kind: SeriesSuggestion.Kind = .openItem) -> SeriesSuggestion {
        SeriesSuggestion(key: "\(kind.rawValue):c\(n):x", kind: kind, text: "t\(n)", source: .init(label: "l"))
    }

    func testAPlainDismissHidesOnlyThatSuggestionAndLowersNothing() {
        var book = NextTimeBook()
        for n in 0..<3 { book.answer(item(n), .dismiss, at: now) }
        let training = SuggestionTraining(answers: book.answers, asOf: now)
        XCTAssertEqual(training.weight(.openItem), 0)
        XCTAssertTrue(training.shows(.openItem))
        XCTAssertTrue(training.off.isEmpty)
        XCTAssertEqual(training.answered, Set((0..<3).map { item($0).key }))
        XCTAssertTrue(book.answers.allSatisfy { $0.lowers == nil })
    }

    func testDismissSuggestionsLikeThisLowersTheKind() {
        var book = NextTimeBook()
        book.answer(item(0), .dismiss, lowersKind: true, at: now)
        XCTAssertEqual(SuggestionTraining(answers: book.answers, asOf: now).weight(.openItem), -1)
        book.answer(item(1), .dismiss, lowersKind: true, at: now)
        let training = SuggestionTraining(answers: book.answers, asOf: now)
        XCTAssertTrue(training.isLowered(.openItem))
        XCTAssertEqual(training.off, [.openItem])
        XCTAssertTrue(book.answers.allSatisfy { $0.lowers == true })
        // The same window as before: an old trained dismissal no longer counts.
        var old = book
        for i in old.answers.indices { old.answers[i].date = now.addingTimeInterval(-(CoachTraining.weightDays + 1) * 86_400) }
        XCTAssertTrue(SuggestionTraining(answers: old.answers, asOf: now).off.isEmpty)
    }

    func testOnlyADismissCarriesLowers() {
        var book = NextTimeBook()
        book.answer(item(0), .keep, lowersKind: true, at: now)
        book.answer(item(1), .never, lowersKind: true, at: now)
        XCTAssertTrue(book.answers.allSatisfy { $0.lowers == nil })
    }

    func testAnUndoTakesBackExactlyThatDismissal() {
        var book = NextTimeBook()
        book.answer(item(0), .dismiss, lowersKind: true, at: now)
        book.answer(item(1), .dismiss, lowersKind: true, at: now)
        book.takeBack(item(1).key, at: now.addingTimeInterval(1))
        let training = SuggestionTraining(answers: book.answers, asOf: now)
        XCTAssertEqual(training.weight(.openItem), -1)
        XCTAssertEqual(training.answered, [item(0).key])
    }

    func testDismissalsSavedBeforeThisVersionNoLongerLowerTheirKind() throws {
        let json = """
        {"version":1,"points":[],"checked":[],"answers":[
        {"id":"\(UUID().uuidString)","key":"openItem:c0:x","kind":"openItem","verdict":"dismiss","date":\(now.timeIntervalSinceReferenceDate)},
        {"id":"\(UUID().uuidString)","key":"openItem:c1:x","kind":"openItem","verdict":"dismiss","date":\(now.timeIntervalSinceReferenceDate)}]}
        """
        let book = try JSONDecoder().decode(NextTimeBook.self, from: Data(json.utf8))
        let training = SuggestionTraining(answers: book.answers, asOf: now)
        XCTAssertTrue(training.off.isEmpty)
        // Each one still hides its own suggestion.
        XCTAssertEqual(training.answered, ["openItem:c0:x", "openItem:c1:x"])
    }

    func testTheFieldSurvivesTheFileAndAMerge() throws {
        var mac = NextTimeBook()
        mac.answer(item(0), .dismiss, lowersKind: true, at: now)
        let read = try JSONDecoder().decode(NextTimeBook.self, from: JSONEncoder().encode(mac))
        XCTAssertEqual(read.answers.map(\.lowers), [true])
        var phone = NextTimeBook()
        phone.answer(item(0), .dismiss, at: now.addingTimeInterval(-60))
        XCTAssertEqual(mac.merged(with: phone).answers.map(\.lowers), [true])
        XCTAssertEqual(phone.merged(with: mac).answers.map(\.lowers), [true])
        // A plain dismissal writes no field, so the file of an older build reads the same.
        let plain = String(decoding: try JSONEncoder().encode(phone), as: UTF8.self)
        XCTAssertFalse(plain.contains("lowers"))
    }

    func testTurnOnKeepsThePlainDismissals() {
        var book = NextTimeBook()
        book.answer(item(0), .dismiss, at: now)
        book.answer(item(1), .dismiss, lowersKind: true, at: now)
        book.answer(item(2), .dismiss, lowersKind: true, at: now)
        book.allowAgain(.openItem, at: now.addingTimeInterval(1))
        let training = SuggestionTraining(answers: book.answers, asOf: now)
        XCTAssertTrue(training.shows(.openItem))
        XCTAssertEqual(training.answered, [item(0).key])
    }

    /// Why the field and not a new verdict: an older build fails to read the whole book on an unknown verdict.
    func testAnUnknownVerdictBreaksTheBookOfAnOlderBuild() {
        let json = """
        {"version":1,"answers":[{"id":"\(UUID().uuidString)","key":"k","kind":"openItem","verdict":"dismissKind","date":0}]}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(NextTimeBook.self, from: Data(json.utf8)))
    }
}
