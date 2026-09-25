import XCTest
@testable import BindersKit

final class InboxTests: XCTestCase {
    func testRequestsAndResultsRoundTrip() throws {
        let request = InboxRequest(action: "add_note", fields: ["text": "Call Sam\n\nabout the deck", "binder": "Work"])
        let decoded = try JSONDecoder().decode(InboxRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)

        let result = InboxResult(ok: true, id: "ABC", message: "Note added")
        XCTAssertEqual(try JSONDecoder().decode(InboxResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertEqual(InboxResult.failure("nope").error, "nope")
        XCTAssertFalse(InboxResult.failure("nope").ok)
    }

    func testOnlyUUIDNamesAreAccepted() {
        let name = UUID().uuidString
        XCTAssertTrue(Inbox.isValidName(name))
        XCTAssertEqual(Inbox.requestFile(name), name + ".request.json")
        XCTAssertEqual(Inbox.resultFile(name), name + ".result.json")
        XCTAssertFalse(Inbox.isValidName("../../etc/passwd"))
        XCTAssertFalse(Inbox.isValidName("note"))
        XCTAssertFalse(Inbox.isValidName(""))
    }
}
