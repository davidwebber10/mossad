import Foundation
@testable import MossadCore

/// The books of the move tests, with fixed ids and dates, so each encodes to the same bytes every run.
enum MoveBooksFixtures {
    static let x = "20261101-100000", y = "20261102-090000", w = "20261025-090000"
    static let t0 = Date(timeIntervalSince1970: 1_793_520_000)

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    static func commitments() -> CommitmentBook {
        var book = CommitmentBook()
        var a = Commitment(text: "Send the zebra budget", to: "Sam Carter", callID: x, callTitle: "Zebra budget", madeAt: t0, at: 12,
                           quote: "I will send the zebra budget", due: t0 + 3600, created: t0)
        a.id = id(1)
        a.toID = "p-sam"
        var b = Commitment(text: "Book the zebra room", to: "Sam Carter", callID: x, callTitle: "Zebra budget", madeAt: t0, due: nil, created: t0)
        b.id = id(2)
        var c = Commitment(text: "Call the bank", to: nil, callID: y, callTitle: "Bank", madeAt: t0, due: nil, created: t0)
        c.id = id(3)
        book.items = [a, b, c]
        book.checked = [x, y]
        return book
    }

    static func points() -> NextTimeBook {
        var book = NextTimeBook()
        var p1 = NextTimePoint(text: "Ask about the zebra budget", personID: "p-sam", personName: "Sam Carter", rank: 1, created: t0)
        p1.id = id(11)
        p1.done = .init(callID: x, at: 30, quote: "the zebra budget is fine", date: t0, byOwner: false)
        var p2 = NextTimePoint(text: "Hiring", personID: "p-sam", personName: "Sam Carter", rank: 2, created: t0)
        p2.id = id(12)
        p2.carried = [w, x]
        var p3 = NextTimePoint(text: "Office move", personID: "p-sam", personName: "Sam Carter", rank: 3, created: t0)
        p3.id = id(13)
        p3.mentions = [.init(callID: x, at: 40, quote: "the zebra office", date: t0), .init(callID: y, at: 50, quote: "the move", date: t0 + 60)]
        var p4 = NextTimePoint(text: "Budget", personID: "p-sam", personName: "Sam Carter", rank: 4, created: t0)
        p4.id = id(14)
        p4.reopened = [x]
        book.points = [p1, p2, p3, p4]
        book.checked = [x, y]
        return book
    }

    static func coach() -> CoachProfile {
        var p = CoachProfile()
        for (n, (call, title)) in [(x, "Zebra budget"), (y, "Bank")].enumerated() {
            p.rated.append(RatedPoint(callID: call, callTitle: title, title: "Pace", principle: "Slow down", agree: true, note: nil, date: t0))
            var q = CoachQuestion(statement: "Sam leads \(title)", kind: .role, evidence: "said so", callID: call, at: 10, asked: t0)
            q.id = id(21 + n)
            q.status = .confirmed
            p.questions.append(q)
            let card = CoachFinding(id: "card-\(call)", callID: call, date: t0, kind: .didWell, text: "Clear ask in \(title)", skill: "asks")
            p.answers.append(FindingAnswer(card, verdict: .never, date: t0))
            p.observations.append(CoachObservation(callID: call, date: t0, pattern: "Pace", result: .did, note: "Good pace in \(title)"))
            p.history.append(CoachHistoryEntry(callID: call, title: title, date: t0, headline: "About \(title)"))
        }
        return p
    }
}
