import XCTest
@testable import BindersKit

final class WritingCleanupTests: XCTestCase {
    func testSignatureAfterSignOffIsDropped() {
        let mail = "Okay, I will look into it.\n\nThanks,\n\nMaya Okafor\nCoFounder & CEO\nexample.com\n(201) 555 0100"
        XCTAssertEqual(WritingCleanup.stripSignature(mail, userName: "Maya Okafor"), "Okay, I will look into it.")
    }

    func testNameLineAloneEndsTheBody() {
        let mail = "Sending the deck over now, let me know what you think.\nMaya\nExample Co"
        XCTAssertEqual(WritingCleanup.stripSignature(mail, userName: "Maya Okafor"), "Sending the deck over now, let me know what you think.")
    }

    func testShortChatMessagesAreLeftAlone() {
        XCTAssertEqual(WritingCleanup.stripSignature("Thanks, will do", userName: "Maya Okafor"), "Thanks, will do")
        XCTAssertEqual(WritingCleanup.stripSignature("thanks\nsee you at 3", userName: "Maya Okafor"), "thanks\nsee you at 3")
        let body = "Best\nis what I'd call this quarter, honestly, given the numbers"
        XCTAssertEqual(WritingCleanup.stripSignature(body, userName: nil), body)
    }

    func testNamesLoseTagsAndInvisibleCharacters() {
        XCTAssertEqual(WritingCleanup.cleanName("Maya Okafor (You)"), "Maya Okafor")
        XCTAssertEqual(WritingCleanup.cleanName("\u{FFFC}"), nil)
        XCTAssertEqual(WritingCleanup.cleanName("\u{2060}Noah Chen\u{200B};"), "Noah Chen")
        XCTAssertEqual(WritingCleanup.cleanName("  noah@example.com "), "noah@example.com")
    }
}
