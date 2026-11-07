import XCTest
@testable import MossadCore

final class CompanyNameTests: XCTestCase {
    func testUsesTheRegistrableLabel() {
        XCTAssertEqual(CompanyName.from(email: "sam@acme.com"), "Acme")
        XCTAssertEqual(CompanyName.from(email: "dana@mail.acme.co.uk"), "Acme")
        XCTAssertEqual(CompanyName.from(email: "alex@eu.globex.com.au"), "Globex")
        XCTAssertEqual(CompanyName.from(email: "pat@Initech.IO"), "Initech")
    }

    func testPublicMailHasNoCompany() {
        for e in ["x@gmail.com", "x@outlook.com", "x@icloud.com", "x@yahoo.co.uk", "x@hotmail.com", "x@me.com", "x@proton.me", "x@protonmail.com", "x@live.com", "x@aol.com"] {
            XCTAssertNil(CompanyName.from(email: e), e)
        }
    }

    func testNoEmailOrNoDomainHasNoCompany() {
        XCTAssertNil(CompanyName.from(email: nil))
        XCTAssertNil(CompanyName.from(email: "nobody"))
        XCTAssertNil(CompanyName.from(email: "a@localhost"))
    }
}
