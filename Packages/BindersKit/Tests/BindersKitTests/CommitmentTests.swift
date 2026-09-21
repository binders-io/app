import XCTest
@testable import BindersKit

final class CommitmentTests: XCTestCase {
    // Tuesday 15 September 2026, 10:00 local.
    private var now: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 15; components.hour = 10
        return Calendar.current.date(from: components)!
    }

    private func stamp(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy, HH:mm"
        return formatter.string(from: date)
    }

    func testScreenLetsPromisesAndAsksThroughAndSkipsChatter() {
        XCTAssertTrue(CommitmentDetection.mayContainCommitment("Sure, I'll send you the booth graphics by Friday."))
        XCTAssertTrue(CommitmentDetection.mayContainCommitment("Will do, leave it with me"))
        XCTAssertTrue(CommitmentDetection.mayContainCommitment("Can you share the deck before the call?"))
        XCTAssertFalse(CommitmentDetection.mayContainCommitment("Thanks, that looks great!"))
        XCTAssertFalse(CommitmentDetection.mayContainCommitment("The meeting moved to 3."))
    }

    func testParseTakesJSONWithOrWithoutFencesAndSalvagesBrokenReplies() {
        let fenced = "```json\n{\"commitments\":[{\"kind\":\"promise\",\"task\":\"send Noah the booth graphics\",\"to\":\"Noah\",\"due\":\"Friday\",\"quote\":\"I'll send you the booth graphics by Friday.\"}]}\n```"
        let parsed = CommitmentDetection.parse(fenced)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.task, "Send Noah the booth graphics")
        XCTAssertEqual(parsed.first?.due, "Friday")
        XCTAssertTrue(parsed.first?.isPromise ?? false)
        XCTAssertEqual(CommitmentDetection.parse("{\"commitments\":[]}"), [])
        let broken = "{\"commitments\":[{\"kind\":\"ask\",\"task\":\"share the deck\",\"to\":\"Samir\",\"due\":null,\"quote\":\"Can you share the deck?\"},{\"task\":]}"
        let salvaged = CommitmentDetection.parse(broken)
        XCTAssertEqual(salvaged.map(\.task), ["Share the deck"])
        XCTAssertEqual(salvaged.first?.kind, "ask")
        XCTAssertNil(salvaged.first?.due)
    }

    func testPersonalizeNamesTheRecipientInPromisesOnly() {
        let promise = DetectedCommitment(kind: "promise", task: "Send you the booth graphics", to: "Noah Chen")
        XCTAssertEqual(CommitmentDetection.personalize(promise, recipient: nil).task, "Send Noah the booth graphics")
        let draft = DetectedCommitment(kind: "promise", task: "Have a first draft to you and review your notes", to: nil)
        XCTAssertEqual(CommitmentDetection.personalize(draft, recipient: "Samir Haddad").task, "Have a first draft to Samir and review Samir's notes")
        let ask = DetectedCommitment(kind: "ask", task: "Send me your slides", to: "Noah")
        XCTAssertEqual(CommitmentDetection.personalize(ask, recipient: nil).task, "Send me your slides")
        XCTAssertEqual(CommitmentDetection.personalize(promise, recipient: nil).to, "Noah Chen")
    }

    func testRelativeDeadlines() {
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "Friday", relativeTo: now)), "09/18/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "by Friday 3pm", relativeTo: now)), "09/18/2026, 15:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "next Tuesday", relativeTo: now)), "09/22/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "tomorrow morning", relativeTo: now)), "09/16/2026, 10:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "EOD", relativeTo: now)), "09/15/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "end of week", relativeTo: now)), "09/18/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "next week", relativeTo: now)), "09/25/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "in 2 days", relativeTo: now)), "09/17/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "Sept 20", relativeTo: now)), "09/20/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "9/20", relativeTo: now)), "09/20/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "2026-10-01", relativeTo: now)), "10/01/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "the 20th", relativeTo: now)), "09/20/2026, 17:00")
        XCTAssertEqual(stamp(CommitmentDetection.dueDate(from: "3pm", relativeTo: now)), "09/15/2026, 15:00")
        XCTAssertNil(CommitmentDetection.dueDate(from: "when I get a chance", relativeTo: now))
        XCTAssertNil(CommitmentDetection.dueDate(from: nil, relativeTo: now))
    }
}
