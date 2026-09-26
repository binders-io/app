import XCTest
@testable import BindersKit

final class SelfCorrectionTests: XCTestCase {
    private func resolved(_ text: String) -> String { SelfCorrection.resolve(text) }

    func testDaysAndTimes() {
        XCTAssertEqual(resolved("I'll send you the checklist by Friday, actually make that Thursday afternoon."),
                       "I'll send you the checklist by Thursday afternoon.")
        XCTAssertEqual(resolved("let's meet at two actually three"), "let's meet at three")
        XCTAssertEqual(resolved("The call is at 5pm, no wait, 6pm"), "The call is at 6pm")
        XCTAssertEqual(resolved("on Tuesday, I mean Wednesday, we ship"), "on Wednesday, we ship")
        XCTAssertEqual(resolved("Friday afternoon, sorry, I meant Friday morning works"), "Friday morning works")
        XCTAssertEqual(resolved("tomorrow, no, today"), "today")
    }

    func testNumbersAndMonths() {
        XCTAssertEqual(resolved("a table for four, make that five"), "a table for five")
        XCTAssertEqual(resolved("we launch in March, or rather April"), "we launch in April")
        XCTAssertEqual(resolved("on March 3rd, I mean March 5th"), "on March 5th")
        XCTAssertEqual(resolved("it costs 40, actually 45 dollars"), "it costs 45 dollars")
    }

    func testTwoCorrectionsInOneSentence() {
        XCTAssertEqual(resolved("Monday at 2, actually 3, no wait, Tuesday at 3"), "Tuesday at 3")
    }

    func testLeavesOrdinaryWordsAlone() {
        for text in [
            "I actually think Friday works",
            "Meet at 5. Actually, 6 people are coming.",
            "the blue one, actually make that the red one",
            "I have two kids, actually",
            "It's 2 actually.",
            "No, Thursday is fine",
            "Hey Jonas, um, quick update on the launch.",
            "one of them, I mean the tall one",
            "we may, actually, need more time",
        ] {
            XCTAssertEqual(resolved(text), text, text)
        }
    }

    func testTheDictationPipelineAppliesItWithoutAModel() async {
        let result = await DictationPipeline.process(raw: "um send it by Friday, actually make that Thursday", context: AppContext(),
                                                     config: PipelineConfig(aiFormatting: false), llm: nil)
        XCTAssertEqual(result.text, "send it by Thursday")
    }
}
