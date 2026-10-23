import XCTest
@testable import MossadCore

/// Claude refuses a structured output schema with more than 16 nullable or union-typed parameters.
final class SchemaLimitTests: XCTestCase {
    private func unions(_ value: Any) -> Int {
        if let list = value as? [Any] { return list.map(unions).reduce(0, +) }
        guard let dict = value as? [String: Any] else { return 0 }
        let own = dict["anyOf"] != nil || dict["type"] is [Any] ? 1 : 0
        return own + dict.values.map(unions).reduce(0, +)
    }

    func testTheCoachSchemaFitsClaudesUnionLimit() {
        XCTAssertLessThanOrEqual(unions(LLMCoach.schema), 16)
    }

    func testTheCommitmentSchemaFitsClaudesUnionLimit() {
        XCTAssertLessThanOrEqual(unions(CommitmentFinder.schema), 16)
    }
}
