import XCTest
@testable import MossadCore

/// The trend sentence against chance: steady histories of many shapes, each run a few hundred times with seeded
/// numbers, may read as a change in fewer than 5% of the runs; a real change must still be found.
final class CommunicationTrendsChanceTests: XCTestCase {
    private typealias T = CommunicationTrends

    private let start = Date(timeIntervalSince1970: 1_790_035_200)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private var period: DateInterval { DateInterval(start: start, duration: 90 * 86_400) }
    /// The most runs in a hundred that may read as a change when nothing changed.
    private let limit = 0.05

    /// Numbers that are the same on each run, so a test of chance does not fail by chance.
    private struct Draws {
        var state: UInt64

        init(_ seed: Int) { state = 0x2545_F491_4F6C_DD1D &+ UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 }

        mutating func unit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }

        mutating func normal(_ mean: Double, _ spread: Double) -> Double {
            mean + spread * (-2 * log(max(unit(), 1e-12))).squareRoot() * cos(2 * .pi * unit())
        }

        mutating func poisson(_ mean: Double) -> Int {
            let floor = exp(-mean)
            var k = 0, p = unit()
            while p > floor { p *= unit(); k += 1 }
            return k
        }

        mutating func pick<E>(_ items: [E]) -> E { items[min(items.count - 1, Int(unit() * Double(items.count)))] }
    }

    /// One meeting `at` days into the period, with the owner's numbers.
    private func meeting(_ id: String, at day: Double, voices: Int = 3, series: String? = nil, kind: String? = nil,
                         share: Double? = nil, questions: Double? = nil, cutIns: Double? = nil, pace: Double? = nil) -> MeetingFacts {
        var values: [PersonMetric: Double] = [:]
        values[.talkShare] = share.map { min(1, max(0, $0)) }
        values[.questionsPerHour] = questions
        values[.cutInsPerHour] = cutIns
        values[.wordsPerMinute] = pace
        let people = [MeetingFacts.Person(name: "Dana Lee", isOwner: true, values: values)]
            + (1..<voices).map { MeetingFacts.Person(name: "Person \($0)", isOwner: false, values: [:]) }
        return MeetingFacts(id: id, stamp: 0, start: start.addingTimeInterval(day * 86_400), title: series ?? "Meeting", series: series, kind: kind,
                            tags: [], voices: voices, people: people, values: [:])
    }

    /// `perThird` meetings in each third of the period, at even times with a little noise.
    private func days(_ perThird: Int, _ draws: inout Draws) -> [Double] {
        (0..<perThird * 3).map { i in 90 * (Double(i) + draws.unit()) / Double(perThird * 3) }
    }

    /// A count an hour as `MeetingFacts` makes it: a count of a call of some minutes, over at least a quarter hour.
    private func perHour(_ rate: Double, _ draws: inout Draws, none: Double = 0) -> Double {
        let hours = max((draws.pick([25.0, 30, 30, 45, 55]) + draws.normal(0, 3)) / 60, 0.05)
        let count = draws.unit() < none ? 0 : draws.poisson(rate * hours)
        return Double(count) / max(hours, 0.25)
    }

    private func claims(runs: Int = 300, _ make: (inout Draws) -> [MeetingFacts], _ read: (T) -> T.Series?) -> Double {
        var moved = 0
        for run in 0..<runs {
            var draws = Draws(run)
            if let s = read(T(facts: make(&draws), interval: period, calendar: calendar)), s.change.moved { moved += 1 }
        }
        return Double(moved) / Double(runs)
    }

    private func talk(_ split: T.Split = .all) -> (T) -> T.Series? { { $0.series(.talkShare, split) } }

    // MARK: Steady histories

    func testNormalNoiseIsNotATrend() {
        let rate = claims({ d in days(15, &d).enumerated().map { meeting("m\($0)", at: $1, share: d.normal(0.5, 0.15)) } }, talk())
        XCTAssertLessThan(rate, limit, "normal noise read as a trend in \(rate * 100)% of runs")
    }

    func testTwoKindsOfMeetingInOneSizeAreNotATrend() {
        // The owner leads half of the meetings (65%) and listens in the others (25%); nothing tells the two apart.
        for perThird in [15, 25, 40] {
            let rate = claims({ d in
                days(perThird, &d).enumerated().map { meeting("m\($0)", at: $1, share: d.normal(d.unit() < 0.5 ? 0.65 : 0.25, 0.06)) }
            }, talk())
            XCTAssertLessThan(rate, limit, "\(perThird) a third: two kinds of meeting read as a trend in \(rate * 100)% of runs")
        }
    }

    func testAChangeInTheMixOfKindsIsNotATrend() {
        // Planning meetings (the owner leads, 65%) go from 70% of the meetings to 30%; all-hands (25%) take their
        // place. Each kind is as it was.
        let rate = claims({ d in
            days(25, &d).enumerated().map { i, day in
                let planning = d.unit() < 0.7 - 0.4 * day / 90
                return meeting("m\(i)", at: day, kind: planning ? "Planning" : "All-hands", share: d.normal(planning ? 0.65 : 0.25, 0.06))
            }
        }, talk())
        XCTAssertLessThan(rate, limit, "a change of the mix of kinds read as a trend in \(rate * 100)% of runs")
    }

    func testAChangeInTheMixOfSeriesIsNotATrend() {
        // The same with no kind: the weekly series a meeting belongs to tells them apart.
        let rate = claims({ d in
            days(25, &d).enumerated().map { i, day in
                let planning = d.unit() < 0.7 - 0.4 * day / 90
                return meeting("m\(i)", at: day, series: planning ? "planning" : "all hands", share: d.normal(planning ? 0.65 : 0.25, 0.06))
            }
        }, talk())
        XCTAssertLessThan(rate, limit, "a change of the mix of series read as a trend in \(rate * 100)% of runs")
    }

    func testAChangeInTheMixOfGroupSizesIsNotATrend() {
        // 35% in groups of 3 to 4 and 8% in groups of 9 or more; the small groups go from 70% of the groups to 30%.
        for perThird in [15, 25] {
            let make: (inout Draws) -> [MeetingFacts] = { d in
                self.days(perThird, &d).enumerated().map { i, day in
                    let small = d.unit() < 0.7 - 0.4 * day / 90
                    return self.meeting("g\(i)", at: day, voices: small ? 3 : 10, share: small ? d.normal(0.35, 0.08) : d.normal(0.08, 0.04))
                }
            }
            for split in [T.Split.all, .group] {
                let rate = claims(make, talk(split))
                XCTAssertLessThan(rate, limit, "\(perThird) a third, \(split): a change of group sizes read as a trend in \(rate * 100)% of runs")
            }
        }
    }

    func testASteadyMixOfGroupSizesIsNotATrend() {
        let rate = claims({ d in
            days(25, &d).enumerated().map { i, day in
                let small = d.unit() < 0.5
                return meeting("g\(i)", at: day, voices: small ? 3 : 10, share: small ? d.normal(0.35, 0.08) : d.normal(0.08, 0.04))
            }
        }, talk(.group))
        XCTAssertLessThan(rate, limit, "a steady mix of group sizes read as a trend in \(rate * 100)% of runs")
    }

    func testCutInsWithManyZerosAreNotATrend() {
        // Half of the meetings have no cut-in and the others about 8 an hour, steady.
        for perThird in [15, 40] {
            let rate = claims({ d in
                days(perThird, &d).enumerated().map { meeting("m\($0)", at: $1, cutIns: perHour(8, &d, none: 0.5)) }
            }) { $0.series(.cutInsPerHour, .all) }
            XCTAssertLessThan(rate, limit, "\(perThird) a third: cut-ins with many zeros read as a trend in \(rate * 100)% of runs")
        }
    }

    func testQuestionsWithSomeZerosAreNotATrend() {
        for perThird in [10, 25] {
            for rate in [4.0, 8.0] {
                let found = claims({ d in
                    days(perThird, &d).enumerated().map { meeting("m\($0)", at: $1, questions: perHour(rate, &d, none: 0.3)) }
                }) { $0.series(.questionsPerHour, .all) }
                XCTAssertLessThan(found, limit, "\(perThird) a third, \(rate) an hour: questions read as a trend in \(found * 100)% of runs")
            }
        }
    }

    func testOverDispersedCountsAreNotATrend() {
        // Some calls are heated and some calm: the rate of each call varies by itself.
        let rate = claims({ d in
            days(25, &d).enumerated().map { i, day in
                meeting("m\(i)", at: day, cutIns: perHour(-log(max(d.unit(), 1e-9)) * 4, &d, none: 0.3))
            }
        }) { $0.series(.cutInsPerHour, .all) }
        XCTAssertLessThan(rate, limit, "over-dispersed cut-ins read as a trend in \(rate * 100)% of runs")
    }

    func testMoreOneOnOnesAreNotMoreQuestions() {
        // Questions are counted per hour of the call, and the owner talks more in a 1:1: 8 an hour there, 4 in a
        // group. The 1:1s go from a quarter of the meetings to three quarters.
        let rate = claims({ d in
            days(20, &d).enumerated().map { i, day in
                let one = d.unit() < 0.25 + 0.5 * day / 90
                return meeting("m\(i)", at: day, voices: one ? 2 : 6, questions: perHour(one ? 8 : 4, &d))
            }
        }) { $0.series(.questionsPerHour, .all) }
        XCTAssertLessThan(rate, limit, "more 1:1s read as more questions in \(rate * 100)% of runs")
    }

    func testWeeklySeriesWithTheirOwnLevelsAreNotATrend() {
        // Eight weekly series, each with its own level, a meeting that is now and then left out, and weeks that
        // move every meeting a little (a busy week, a hard topic).
        let rate = claims({ d in
            let levels = (0..<8).map { _ in min(0.9, max(0.1, d.normal(0.5, 0.15))) }
            var out: [MeetingFacts] = []
            for week in 0..<13 {
                let shift = d.normal(0, 0.05)
                for (s, level) in levels.enumerated() where d.unit() > 0.15 {
                    out.append(meeting("w\(week)s\(s)", at: Double(week * 7 + s % 5) + 0.4, series: "series \(s)", share: d.normal(level + shift, 0.06)))
                }
            }
            return out
        }, talk())
        XCTAssertLessThan(rate, limit, "weekly series read as a trend in \(rate * 100)% of runs")
    }

    // MARK: Real changes

    func testAFallInEveryKindIsFoundThroughAChangeOfMix() {
        // Both group sizes fall by 12 points while the small groups give way to the large ones.
        let rate = claims(runs: 100, { d in
            days(25, &d).enumerated().map { i, day in
                let small = d.unit() < 0.7 - 0.4 * day / 90
                let fall = 0.12 * day / 90 * 1.5
                return meeting("g\(i)", at: day, voices: small ? 3 : 10, share: small ? d.normal(0.40 - fall, 0.05) : d.normal(0.22 - fall, 0.05))
            }
        }, talk(.group))
        XCTAssertGreaterThanOrEqual(rate, 0.9, "a real fall was found in \(rate * 100)% of runs")
    }

    func testAFallInTwoKindsOfMeetingIsFound() {
        // The owner leads half of the meetings and listens in the others, and talks less in both. With the kind
        // named, each kind is compared with itself and the fall is plain.
        func make(named: Bool) -> (inout Draws) -> [MeetingFacts] {
            { d in
                self.days(25, &d).enumerated().map { i, day in
                    let leads = d.unit() < 0.5
                    return self.meeting("m\(i)", at: day, kind: named ? (leads ? "Planning" : "Review") : nil,
                                        share: d.normal((leads ? 0.65 : 0.30) - 0.15 * day / 90 * 1.5, 0.05))
                }
            }
        }
        let named = claims(runs: 100, make(named: true), talk())
        XCTAssertGreaterThanOrEqual(named, 0.9, "a real fall in two named kinds was found in \(named * 100)% of runs")
        // With nothing to tell the kinds apart, which kind a meeting is hides much of the fall from any test: it
        // is found less often, never made up.
        let unnamed = claims(runs: 100, make(named: false), talk())
        XCTAssertGreaterThanOrEqual(unnamed, 0.5, "a real fall in two unnamed kinds was found in \(unnamed * 100)% of runs")
    }

    func testFewerCutInsAreFound() {
        let rate = claims(runs: 100, { d in
            days(25, &d).enumerated().map { i, day in meeting("m\(i)", at: day, cutIns: perHour(day < 30 ? 8 : day < 60 ? 5 : 2, &d, none: 0.2)) }
        }) { $0.series(.cutInsPerHour, .all) }
        XCTAssertGreaterThanOrEqual(rate, 0.9, "a fall from 8 to 2 cut-ins an hour was found in \(rate * 100)% of runs")
    }

    // MARK: The line and the sentence

    func testTheLineHoldsTheMixSteady() {
        // Each group size as it was, the small groups giving way: the line, like the sentence, stays flat.
        let facts = (0..<75).map { i -> MeetingFacts in
            let day = Double(i) * 1.2
            let small = Double(i % 10) < 7 - 4 * day / 90
            return meeting("g\(i)", at: day, voices: small ? 3 : 10, share: small ? 0.35 : 0.08)
        }
        let s = T(facts: facts, interval: period, calendar: calendar).series(.talkShare, .group)!
        XCTAssertEqual(s.change, .steady)
        XCTAssertTrue(s.held, "the line says that it holds the mix")
        XCTAssertGreaterThan(s.line.count, 2)
        XCTAssertEqual(Set(s.line.map { ($0.value * 1000).rounded() }).count, 1, "\(s.line.map(\.value))")
    }

    func testTheSentenceQuotesTheLinesLevels() {
        // Each group size falls by 12 points through a change of mix: the numbers of the sentence are those of
        // the line, with the mix held, not the raw medians that the mix moves by more.
        let facts = (0..<90).map { i -> MeetingFacts in
            let day = Double(i)
            let small = Double(i % 10) < 7 - 4 * day / 90
            let fall = day < 30 ? 0 : day < 60 ? 0.06 : 0.12
            return meeting("g\(i)", at: day, voices: small ? 3 : 10, share: (small ? 0.40 : 0.20) - fall)
        }
        let s = T(facts: facts, interval: period, calendar: calendar).series(.talkShare, .group)!
        guard case .moved(let from, let to) = s.change else { return XCTFail("\(s.change)") }
        XCTAssertEqual(from - to, 0.12, accuracy: 0.001)
        XCTAssertEqual(s.line.first!.value, from, accuracy: 0.001)
        XCTAssertEqual(s.line.last!.value, to, accuracy: 0.001)
    }

    func testOneKindOfMeetingIsDrawnAsItIs() {
        let facts = (0..<60).map { meeting("m\($0)", at: Double($0) * 1.5, share: 0.3 + Double($0 % 5) * 0.05) }
        let s = T(facts: facts, interval: period, calendar: calendar).series(.talkShare, .all)!
        XCTAssertFalse(s.held)
        XCTAssertEqual(s.line, T.line(s.points, interval: period, calendar: calendar).steps)
    }
}
