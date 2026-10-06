import XCTest
@testable import BindersKit

final class KnowledgeCorrectionsTests: XCTestCase {
    func testACorrectionReadsBackFromItsNote() throws {
        let correction = KnowledgeCorrection(wrong: "The launch is on the 21st", right: "The launch is on the 28th",
                                             source: "Launch review", reason: "Maya moved it on Monday")
        let note = correction.markdown
        XCTAssertTrue(note.hasPrefix("# Correction: The launch is on the 28th"))
        XCTAssertTrue(note.contains("Where: [[Launch review]]") && note.hasSuffix("#correction"))
        XCTAssertEqual(KnowledgeCorrection.parse(note), correction)
        XCTAssertNil(KnowledgeCorrection.parse("# Launch\n\nWrong: this isn't tagged\nRight: so it isn't one"))
    }

    func testWhatItMarks() {
        let correction = KnowledgeCorrection(wrong: "the launch is on the 21st", right: "the launch is on the 28th")
        XCTAssertTrue(correction.corrects("Decided: The Launch is on the 21st, with annual pricing."))
        XCTAssertTrue(correction.corrects("the launch is on the  21st!"), "spacing and punctuation don't matter")
        XCTAssertFalse(correction.corrects("The launch is on the 28th."))
        XCTAssertFalse(correction.corrects("Relaunch is on the 21st"), "whole words only")
        XCTAssertFalse(KnowledgeCorrection(wrong: "21st", right: "28th").corrects("Ship by the 21st"), "too short to tell")
        XCTAssertFalse(KnowledgeCorrection(wrong: "21st", right: "28th").isSpecific)
    }

    func testFixingANote() {
        let text = "# Plan\n\nThe launch is on the 21st. Pricing is annual."
        XCTAssertEqual(KnowledgeCorrections.fixing(text, wrong: "the launch is on the 21st", right: "The launch is on the 28th"),
                       "# Plan\n\nThe launch is on the 28th. Pricing is annual.")
        XCTAssertNil(KnowledgeCorrections.fixing(text, wrong: "the launch moves", right: "x"), "not there")
        XCTAssertNil(KnowledgeCorrections.fixing("a b a b", wrong: "a b", right: "c"), "there twice: not sure which")
        XCTAssertEqual(KnowledgeCorrections.occurrences(of: "a b", in: "a b a b"), 2)
    }
}
