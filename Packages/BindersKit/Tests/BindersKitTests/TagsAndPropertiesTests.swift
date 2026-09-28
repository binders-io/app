import XCTest
@testable import BindersKit

final class TagsAndPropertiesTests: XCTestCase {
    func testFindsTagsButNotHeadingsNumbersOrAddresses() {
        let text = "# Heading\nPlan for #Pricing and #q4/launch, issue #12, see https://example.com/#anchor and `#code`.\n```\n#fenced\n```\n#pricing again"
        XCTAssertEqual(NoteTags.tags(in: text), ["pricing", "q4/launch"])
    }

    func testTheEditorSeesTags() {
        let spans = MarkdownSyntax.spans(in: "Ship it #launch")
        XCTAssertTrue(spans.contains(MarkdownSpan(NSRange(location: 8, length: 7), .tag)))
    }

    func testPropertiesTravelInFrontMatter() {
        let due = TeamFiles.day(from: "2026-10-02")!
        let note = TeamNote(id: "A", body: "# Pricing\n\nText", properties: NoteProperties(status: "Draft", owner: "Sam", due: due))
        let markdown = TeamFiles.noteMarkdown(note)
        XCTAssertTrue(markdown.contains("status: \"Draft\"") && markdown.contains("owner: \"Sam\"") && markdown.contains("due: \"2026-10-02\""), markdown)
        let parsed = TeamFiles.parseNote(markdown)
        XCTAssertEqual(parsed.properties, note.properties)
        XCTAssertTrue(parsed.extraFrontmatter.isEmpty, "they aren't kept twice")
    }

    func testANoteWithoutPropertiesHashesAsBefore() {
        let body = "# Pricing\n\nText"
        XCTAssertEqual(TeamFiles.noteHash(body), TeamFiles.sha256(Data(body.utf8)), "unchanged for every existing note")
        XCTAssertEqual(TeamFiles.noteHash(body, NoteProperties()), TeamFiles.noteHash(body))
        XCTAssertNotEqual(TeamFiles.noteHash(body, NoteProperties(status: "Done")), TeamFiles.noteHash(body), "a property change syncs")
        XCTAssertTrue(NoteProperties(status: "  ", owner: "").isEmpty)
    }
}
