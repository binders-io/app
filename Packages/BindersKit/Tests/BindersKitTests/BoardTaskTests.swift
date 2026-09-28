import XCTest
@testable import BindersKit

final class BoardTaskTests: XCTestCase {
    // MARK: A rewritten digest keeps its ticks

    func testTicksSurviveARewrite() {
        let old = """
        ## To-dos
        - [x] Be able to delete Notes with Del or Backspace.
        - [ ] Find a way to run it on my phone and sync to Desktop.
        - [x] Find a way to copy from Digest.
        """
        let new = """
        ## To-dos
        - [ ] Id like to be able to delete Notes with Del or Backspace.
        - [ ] Run it on my phone and sync to Desktop.
        - [ ] Find a way to copy from the Digest.
        - [ ] Expand the Obsidian functionality.
        """
        let merged = NotesEditing.carryOverTicks(from: old, into: new)
        XCTAssertEqual(merged, """
        ## To-dos
        - [x] Id like to be able to delete Notes with Del or Backspace.
        - [ ] Run it on my phone and sync to Desktop.
        - [x] Find a way to copy from the Digest.
        - [ ] Expand the Obsidian functionality.
        """)
    }

    func testSimilarButDifferentTasksStayOpen() {
        let merged = NotesEditing.carryOverTicks(from: "- [x] Send Jonas the deck", into: "- [ ] Send Jonas the invoice")
        XCTAssertEqual(merged, "- [ ] Send Jonas the invoice")
        XCTAssertEqual(NotesEditing.carryOverTicks(from: "no tasks here", into: "- [ ] Call Sam"), "- [ ] Call Sam")
    }

    func testOwnersDontGetInTheWay() {
        let merged = NotesEditing.carryOverTicks(from: "- [x] Noah — order the stickers", into: "- [ ] Noah — order stickers for the booth")
        XCTAssertEqual(merged, "- [ ] Noah — order stickers for the booth", "two new words out of four is a different task")
        XCTAssertEqual(NotesEditing.carryOverTicks(from: "- [x] Noah — order the stickers", into: "- [ ] **Noah** — order the stickers"),
                       "- [x] **Noah** — order the stickers")
    }

    // MARK: Finding a task again

    func testFingerprintsIgnoreCaseAndSpacing() {
        XCTAssertEqual(NotesEditing.fingerprint("Call  Sam"), NotesEditing.fingerprint("call sam"))
        XCTAssertNotEqual(NotesEditing.fingerprint("Call Sam"), NotesEditing.fingerprint("Call Samir"))
        XCTAssertEqual(NotesEditing.fingerprint("Call Sam").count, 8)
    }

    func testSettingATaskFindsItWhereverItMoved() {
        let fingerprint = NotesEditing.fingerprint("send the deck")
        let markdown = "# Plan\n\nNew line on top\n- [ ] Call Sam\n- [ ] Maya — send the deck"
        let done = NotesEditing.setTask(fingerprint: fingerprint, done: true, in: markdown)
        XCTAssertEqual(done?.markdown, "# Plan\n\nNew line on top\n- [ ] Call Sam\n- [x] Maya — send the deck")
        XCTAssertEqual(done?.task.owner, "Maya")
        XCTAssertEqual(NotesEditing.setTask(fingerprint: fingerprint, done: true, in: done!.markdown)?.markdown, done?.markdown, "already done")
        XCTAssertEqual(NotesEditing.setTask(fingerprint: fingerprint, done: false, in: done!.markdown)?.markdown, markdown)
        XCTAssertNil(NotesEditing.setTask(fingerprint: fingerprint, done: true, in: "- [ ] something else"))
    }

    func testReferencesRoundTrip() throws {
        let id = UUID()
        let reference = BoardTaskReference(place: .digest, id: id, text: "Copy from the digest")
        let parsed = try XCTUnwrap(BoardTaskReference(reference.string))
        XCTAssertEqual(parsed, reference)
        XCTAssertEqual(parsed.place, .digest)
        XCTAssertNil(BoardTaskReference(id.uuidString), "a promise's id is a plain UUID")
        XCTAssertNil(BoardTaskReference("digest:\(id.uuidString):nothex!"))
        XCTAssertNil(BoardTaskReference("folder:\(id.uuidString):0123abcd"))
    }
}

final class TeammateOwnerTests: XCTestCase {
    func testATeammatesYouIsTheTeammateAndYourNameIsYou() {
        XCTAssertEqual(NotesEditing.owner("You", author: "Maya Okafor", reader: "Dana Reyes"), "Maya")
        XCTAssertEqual(NotesEditing.owner("Dana", author: "Maya Okafor", reader: "Dana Reyes"), "You")
        XCTAssertEqual(NotesEditing.owner("Dana Reyes", author: "Maya Okafor", reader: "Dana Reyes"), "You")
        XCTAssertEqual(NotesEditing.owner("Jonas", author: "Maya Okafor", reader: "Dana Reyes"), "Jonas")
        XCTAssertNil(NotesEditing.owner(nil, author: "Maya Okafor", reader: "Dana Reyes"))
        XCTAssertEqual(NotesEditing.owner("You", author: nil, reader: "Dana Reyes"), "You", "your own items stay as they are")
    }

    func testRenamesOwnersInATeammatesNotesWithoutMovingLines() {
        let summary = """
        ## Action items
        - [ ] You — send Jonas the final launch checklist by Friday
        - [x] **Dana** — confirm the annual discount
        - [ ] Jonas — get support to review the emails
        - [ ] Book the room
        You said the launch stays on the 28th.
        """
        let shown = NotesEditing.renamingOwners(in: summary, author: "Maya Okafor", reader: "Dana Reyes")
        XCTAssertEqual(shown, """
        ## Action items
        - [ ] Maya — send Jonas the final launch checklist by Friday
        - [x] **You** — confirm the annual discount
        - [ ] Jonas — get support to review the emails
        - [ ] Book the room
        You said the launch stays on the 28th.
        """)
        XCTAssertEqual(NotesEditing.renamingOwners(in: summary, author: nil, reader: "Dana Reyes"), summary)
        // The words, and so every to-do's id, are unchanged.
        XCTAssertEqual(NotesEditing.task(from: shown.components(separatedBy: "\n")[1])?.text,
                       NotesEditing.task(from: summary.components(separatedBy: "\n")[1])?.text)
    }
}
