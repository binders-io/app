import XCTest
@testable import BindersKit

/// All sample values below are the standard documentation examples (the test card number, the example SSN,
/// a made-up IBAN and key), not real credentials.
final class RedactorTests: XCTestCase {
    func testStripsLabelledSecretsAndIdentifiersButLeavesProse() {
        let text = """
        Hi Noah, the wifi password: examplevalue and the API key = EXAMPLEKEY00000000000000000000ab
        Card 4111 1111 1111 1111 expires next year; SSN 123-45-6789; IBAN GB00EXMP00000000000000.
        The booth number is 1748 and the flight lands at 22:24, see you Tuesday.
        """
        let result = Redactor.redact(text)
        XCTAssertTrue(result.text.contains("password: [redacted]"))
        XCTAssertTrue(result.text.contains("API key = [redacted]"))
        XCTAssertTrue(result.text.contains("Card [card] expires"))
        XCTAssertTrue(result.text.contains("SSN [ssn]"))
        XCTAssertTrue(result.text.contains("IBAN [iban]"))
        XCTAssertTrue(result.text.contains("booth number is 1748"))
        XCTAssertTrue(result.text.contains("lands at 22:24"))
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(Redactor.redact("nothing sensitive here, meeting at 3").count, 0)
    }

    func testLuhnRejectsRandomDigitRuns() {
        XCTAssertTrue(Redactor.luhn("4111111111111111"))
        XCTAssertFalse(Redactor.luhn("4111111111111112"))
        XCTAssertEqual(Redactor.redact("order 1234567890123 shipped").text, "order 1234567890123 shipped")
    }

    func testOpaqueTokensGoButLongWordsStay() {
        XCTAssertEqual(Redactor.redact("use example0token0AbCdEf0123456789xyz now").text, "use [token] now")
        XCTAssertEqual(Redactor.redact("supercalifragilisticexpialidocious is a word").count, 0)
    }
}
