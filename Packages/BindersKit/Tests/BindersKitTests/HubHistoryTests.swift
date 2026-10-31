import XCTest
@testable import BindersKit

final class HubHistoryTests: XCTestCase {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func testReadsTheCommitsAndSkipsWhatItCantRead() throws {
        let data = json(["commits": [
            ["sha": "8f3a2c1d9e0b7a6f5c4d3e2f1a0b9c8d7e6f5a4b", "short": "8f3a2c1", "author": "Binders", "at": "2026-10-30T14:43:37-04:00",
             "subject": "Edit “Plan”"],
            ["sha": "1234abcd", "author": "Binders", "at": "2026-10-30T10:00:00Z", "subject": "Notes as the hub has them"],
            ["sha": "not a sha", "at": "2026-10-30T10:00:00Z"],
            ["sha": "abcd1234", "at": "yesterday"],
        ]])
        let commits = try XCTUnwrap(HubHistory.commits(from: data))
        XCTAssertEqual(commits.map(\.short), ["8f3a2c1", "1234abc"])
        XCTAssertEqual(commits[0].subject, "Edit “Plan”")
        XCTAssertEqual(commits[0].at, ISO8601DateFormatter().date(from: "2026-10-30T18:43:37Z"))
        XCTAssertEqual(HubHistory.commits(from: json(["commits": []])), [])
        XCTAssertNil(HubHistory.commits(from: json(["error": "Notes aren’t kept in Git on this hub"])))
    }

    func testTakesTheFrontMatterOffANotesFile() {
        let file = "---\nid: note-abc\nbinder: p1\nfolder: f1\nwork:\n  - { item: c1, quote: \"x\" }\n---\n# Plan\n\nFirst line.\n"
        XCTAssertEqual(HubHistory.text(fromFile: file), "# Plan\n\nFirst line.")
        // A note whose words begin with a rule keeps it.
        XCTAssertEqual(HubHistory.text(fromFile: "---\nid: n\nbinder: p\n---\n---\n\nAfter a rule.\n"), "---\n\nAfter a rule.")
        XCTAssertEqual(HubHistory.text(fromFile: "No front matter\n"), "No front matter")
        XCTAssertEqual(HubHistory.text(fromFile: "---\nid: n\nbinder: p\n---\n"), "")
    }

    func testPathsTakeOnlyIDsAndCommits() {
        XCTAssertEqual(HubHistory.historyPath(of: "note-mvul2dsn-3"), "api/notes/note-mvul2dsn-3/history")
        XCTAssertEqual(HubHistory.versionPath(of: "0f5e6a1c-2b3d-4e5f-8a9b-0c1d2e3f4a5b", at: "1234abcd"),
                       "api/notes/0f5e6a1c-2b3d-4e5f-8a9b-0c1d2e3f4a5b/at/1234abcd")
        XCTAssertNil(HubHistory.historyPath(of: "../tokens"))
        XCTAssertNil(HubHistory.versionPath(of: "n1", at: "HEAD"))
        XCTAssertNil(HubHistory.versionPath(of: "n1", at: "ABCDEF12"))
    }
}
