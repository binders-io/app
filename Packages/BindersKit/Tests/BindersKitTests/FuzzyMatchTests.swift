import XCTest
@testable import BindersKit

final class FuzzyMatchTests: XCTestCase {
    private func best(_ query: String, _ titles: [String]) -> String? {
        titles.compactMap { title in FuzzyMatch.score(query, in: title).map { (title, $0) } }.max { $0.1 < $1.1 }?.0
    }

    func testFindsLettersInOrderAndNothingElse() {
        XCTAssertNotNil(FuzzyMatch.score("lrr", in: "Launch readiness review"))
        XCTAssertNil(FuzzyMatch.score("rrl", in: "Launch readiness review"))
        XCTAssertNil(FuzzyMatch.score("xyz", in: "Launch readiness review"))
        XCTAssertEqual(FuzzyMatch.score("", in: "Anything"), 0)
    }

    func testIgnoresCaseAndAccents() {
        XCTAssertNotNil(FuzzyMatch.score("tomas", in: "Tomás Ferreira"))
        XCTAssertNotNil(FuzzyMatch.score("PRICING", in: "Pricing page walkthrough"))
    }

    func testRanksTheWayPeopleExpect() {
        let titles = ["Draft the changelog post", "Launch readiness review", "Pricing page walkthrough", "Harbor launch"]
        XCTAssertEqual(best("launch", titles), "Launch readiness review", "a title that starts with it beats one that only contains it")
        XCTAssertEqual(best("hl", titles), "Harbor launch", "word starts")
        XCTAssertEqual(best("pric", titles), "Pricing page walkthrough")
        XCTAssertEqual(best("launch rev", titles), "Launch readiness review", "spaces are fine")
        XCTAssertEqual(best("chg", ["Change the logo", "Draft the changelog post"]), "Change the logo", "earlier and together")
    }
}
