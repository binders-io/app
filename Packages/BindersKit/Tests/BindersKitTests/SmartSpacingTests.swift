import XCTest
@testable import BindersKit

final class SmartSpacingTests: XCTestCase {
    func testAddsSpaceAfterWord() {
        XCTAssertEqual(SmartSpacing.adjust("Next sentence.", before: "First sentence."), " Next sentence.")
    }

    func testNoSpaceAtStartOrAfterWhitespace() {
        XCTAssertEqual(SmartSpacing.adjust("Hello", before: nil), "Hello")
        XCTAssertEqual(SmartSpacing.adjust("Hello", before: ""), "Hello")
        XCTAssertEqual(SmartSpacing.adjust("Hello", before: "Line\n"), "Hello")
        XCTAssertEqual(SmartSpacing.adjust(" Hello", before: "Hi "), "Hello")
    }

    func testPunctuationAttaches() {
        XCTAssertEqual(SmartSpacing.adjust(", and more", before: "apples"), ", and more")
        XCTAssertEqual(SmartSpacing.adjust("quoted", before: "say \""), "quoted")
    }
}
