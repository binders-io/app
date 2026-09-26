import XCTest
@testable import BindersKit

final class MarkdownTests: XCTestCase {
    private func styles(_ text: String) -> [(String, MarkdownStyle)] {
        MarkdownSyntax.spans(in: text).map { ((text as NSString).substring(with: $0.range), $0.style) }
    }
    private func has(_ text: String, _ piece: String, _ style: MarkdownStyle) -> Bool {
        styles(text).contains { $0.0 == piece && $0.1 == style }
    }

    // MARK: Reading

    func testHeadings() {
        XCTAssertTrue(has("## Launch plan", "## Launch plan", .heading(level: 2)))
        XCTAssertTrue(has("## Launch plan", "## ", .syntax))
        XCTAssertFalse(has("#hashtag", "#hashtag", .heading(level: 1)))
    }

    func testListsAndTasks() {
        let text = "- milk\n3. eggs\n- [ ] call Sam\n- [x] send the deck"
        XCTAssertTrue(has(text, "-", .listMarker))
        XCTAssertTrue(has(text, "3.", .listMarker))
        XCTAssertTrue(has(text, "[ ]", .task(checked: false)))
        XCTAssertTrue(has(text, "[x]", .task(checked: true)))
        XCTAssertTrue(has(text, "send the deck", .checkedText))
    }

    func testInlineStyles() {
        let text = "Ship **today**, *maybe*, ~~never~~, with `make test` and [the plan](https://example.com)."
        XCTAssertTrue(has(text, "**today**", .bold))
        XCTAssertTrue(has(text, "*maybe*", .italic))
        XCTAssertTrue(has(text, "~~never~~", .strikethrough))
        XCTAssertTrue(has(text, "`make test`", .inlineCode))
        XCTAssertTrue(has(text, "the plan", .link))
        XCTAssertTrue(has(text, "https://example.com", .linkURL))
        XCTAssertTrue(has(text, "**", .syntax))
    }

    func testNothingInsideCodeIsStyled() {
        let inline = "Run `**not bold**` now"
        XCTAssertFalse(styles(inline).contains { $0.1 == .bold })
        let block = "```swift\nlet x = **y**\n# not a heading\n```\nafter **bold**"
        XCTAssertTrue(has(block, "```swift", .codeFence))
        XCTAssertTrue(has(block, "let x = **y**", .codeBlock))
        XCTAssertTrue(has(block, "# not a heading", .codeBlock))
        XCTAssertFalse(styles(block).contains { $0.1 == .heading(level: 1) })
        XCTAssertTrue(has(block, "**bold**", .bold))
        XCTAssertEqual(MarkdownSyntax.fenceCount(in: block), 2)
    }

    func testPlainProseStaysPlain() {
        XCTAssertTrue(styles("2 * 3 * 4 is 24, and snake_case_names stay as they are").isEmpty)
        XCTAssertTrue(has("> a quote", "> a quote", .quote))
        XCTAssertTrue(has("---", "---", .rule))
    }

    func testRangesCountUTF16() {
        let text = "Café 🎉 **bold**"
        let span = MarkdownSyntax.spans(in: text).first { $0.style == .bold }
        XCTAssertEqual(span.map { (text as NSString).substring(with: $0.range) }, "**bold**")
    }

    // MARK: Return in a list

    func testReturnContinuesLists() {
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "- milk", inCodeBlock: false), .continueWith("- "))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "  * nested", inCodeBlock: false), .continueWith("  * "))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "9. nine", inCodeBlock: false), .continueWith("10. "))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "- [x] done", inCodeBlock: false), .continueWith("- [ ] "))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "> quoted", inCodeBlock: false), .continueWith("> "))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "plain text", inCodeBlock: false), .newline)
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "- ", inCodeBlock: false), .endList(count: 2))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "- [ ] ", inCodeBlock: false), .endList(count: 6))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "  2. ", inCodeBlock: false), .endList(count: 5))
    }

    func testReturnInCodeKeepsIndentation() {
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "    return x", inCodeBlock: true), .continueWith("    "))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "- not a list here", inCodeBlock: true), .newline)
    }

    // MARK: Commands

    func testWrapAndUnwrap() {
        let wrapped = MarkdownEditing.toggleWrap("ship today", selection: NSRange(location: 5, length: 5), marker: "**")
        XCTAssertEqual(wrapped.text, "ship **today**")
        XCTAssertEqual(wrapped.selection, NSRange(location: 7, length: 5))
        let unwrapped = MarkdownEditing.toggleWrap(wrapped.text, selection: wrapped.selection, marker: "**")
        XCTAssertEqual(unwrapped.text, "ship today")
        XCTAssertEqual(unwrapped.selection, NSRange(location: 5, length: 5))
        let empty = MarkdownEditing.toggleWrap("run ", selection: NSRange(location: 4, length: 0), marker: "`")
        XCTAssertEqual(empty.text, "run ``")
        XCTAssertEqual(empty.selection, NSRange(location: 5, length: 0))
    }

    func testLinks() {
        let words = MarkdownEditing.insertLink("see the plan", selection: NSRange(location: 4, length: 8))
        XCTAssertEqual(words.text, "see [the plan]()")
        XCTAssertEqual(words.selection, NSRange(location: 15, length: 0))
        let address = MarkdownEditing.insertLink("https://binders.io", selection: NSRange(location: 0, length: 18))
        XCTAssertEqual(address.text, "[](https://binders.io)")
        XCTAssertEqual(address.selection, NSRange(location: 1, length: 0))
    }

    func testLineStyles() {
        let text = "milk\neggs\n"
        let list = MarkdownEditing.toggle(.bullet, in: text, selection: NSRange(location: 0, length: 9))
        XCTAssertEqual(list.text, "- milk\n- eggs\n")
        XCTAssertEqual(MarkdownEditing.toggle(.bullet, in: list.text, selection: list.selection).text, text)
        XCTAssertEqual(MarkdownEditing.toggle(.numbered, in: list.text, selection: list.selection).text, "1. milk\n2. eggs\n")
        XCTAssertEqual(MarkdownEditing.toggle(.task, in: list.text, selection: list.selection).text, "- [ ] milk\n- [ ] eggs\n")
        let heading = MarkdownEditing.toggle(.heading(2), in: "Plan", selection: NSRange(location: 2, length: 0))
        XCTAssertEqual(heading.text, "## Plan")
        XCTAssertEqual(heading.selection, NSRange(location: 7, length: 0))
        XCTAssertEqual(MarkdownEditing.toggle(.heading(2), in: heading.text, selection: heading.selection).text, "Plan")
        XCTAssertEqual(MarkdownEditing.toggle(.heading(1), in: heading.text, selection: heading.selection).text, "# Plan")
    }

    func testIndentingListItems() {
        let text = "- one\n- two"
        let indented = MarkdownEditing.indent(text, selection: NSRange(location: 8, length: 0), outdent: false)
        XCTAssertEqual(indented?.text, "- one\n  - two")
        XCTAssertEqual(indented?.selection, NSRange(location: 10, length: 0))
        XCTAssertEqual(MarkdownEditing.indent(indented!.text, selection: indented!.selection, outdent: true)?.text, text)
        XCTAssertNil(MarkdownEditing.indent("just prose", selection: NSRange(location: 3, length: 0), outdent: false))
    }

    func testCodeBlocks() {
        let empty = MarkdownEditing.insertCodeBlock("", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(empty.text, "```\n\n```")
        XCTAssertEqual(empty.selection, NSRange(location: 4, length: 0))
        let fenced = MarkdownEditing.insertCodeBlock("intro\nlet x = 1\nlet y = 2\n", selection: NSRange(location: 6, length: 19))
        XCTAssertEqual(fenced.text, "intro\n```\nlet x = 1\nlet y = 2\n```\n")
    }

    func testTickingTasks() {
        let text = "- [ ] call Sam\n- [x] send the deck"
        XCTAssertEqual(MarkdownEditing.toggleTask(text, at: 3)?.text, "- [x] call Sam\n- [x] send the deck")
        XCTAssertEqual(MarkdownEditing.toggleTask(text, at: 18)?.text, "- [ ] call Sam\n- [ ] send the deck")
        XCTAssertNil(MarkdownEditing.toggleTask("plain line", at: 2))
    }
}
