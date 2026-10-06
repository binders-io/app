import XCTest
@testable import BindersKit

final class MarkdownMediaTests: XCTestCase {
    func testPicturesOnTheirOwnLine() throws {
        let embed = try XCTUnwrap(MarkdownMedia.embed(inLine: "![The whiteboard|320](attachments/whiteboard.png)", at: 10))
        XCTAssertEqual(embed.source, "attachments/whiteboard.png")
        XCTAssertEqual(embed.caption, "The whiteboard")
        XCTAssertEqual(embed.width, 320)
        XCTAssertEqual(embed.range, NSRange(location: 10, length: 49))
        XCTAssertEqual(embed.captionRange, NSRange(location: 12, length: 14))

        let video = try XCTUnwrap(MarkdownMedia.embed(inLine: "  ![](attachments/demo%20clip.mov)", at: 0))
        XCTAssertEqual(video.source, "attachments/demo clip.mov")
        XCTAssertNil(video.captionRange)
        XCTAssertEqual(MarkdownMedia.kind(of: video.source), .video)

        let obsidian = try XCTUnwrap(MarkdownMedia.embed(inLine: "![[Pasted image 20261001.png|400]]", at: 0))
        XCTAssertEqual(obsidian.source, "Pasted image 20261001.png")
        XCTAssertEqual(obsidian.width, 400)
        XCTAssertEqual(MarkdownMedia.embed(inLine: "![[photo.jpg|The view]]", at: 0)?.caption, "The view")

        XCTAssertEqual(MarkdownMedia.embed(inLine: "![logo](https://example.com/logo.svg?size=2)", at: 0)?.source, "https://example.com/logo.svg?size=2")
        XCTAssertNil(MarkdownMedia.embed(inLine: "See ![this](attachments/a.png) inline", at: 0), "only a line of its own shows the picture")
        XCTAssertNil(MarkdownMedia.embed(inLine: "![[Launch plan]]", at: 0), "embedding a note isn't a picture")
        XCTAssertNil(MarkdownMedia.embed(inLine: "![notes](attachments/minutes.pdf)", at: 0))
    }

    func testStylingHidesEverythingButTheCaption() {
        let text = "# Trip\n![Harbour at dusk](attachments/harbour.jpg)\nAfter"
        let spans = MarkdownSyntax.spans(in: text)
        let string = text as NSString
        XCTAssertTrue(spans.contains { $0.style == .embed(source: "attachments/harbour.jpg", width: nil) && string.substring(with: $0.range).hasPrefix("![") })
        let hidden = spans.filter { $0.style == .syntax }.map { string.substring(with: $0.range) }
        XCTAssertTrue(hidden.contains("!["))
        XCTAssertTrue(hidden.contains("](attachments/harbour.jpg)"))
        XCTAssertFalse(spans.contains { $0.style == .link }, "the picture's markup isn't a link")
    }

    func testWritingAndResizing() {
        XCTAssertEqual(MarkdownMedia.markdown(forFile: "board photo (2).png", caption: "Board"), "![Board](attachments/board%20photo%20%282%29.png)")
        XCTAssertEqual(MarkdownMedia.markdown(forFile: "minutes.pdf", caption: ""), "[minutes.pdf](attachments/minutes.pdf)")
        XCTAssertEqual(MarkdownMedia.embed(inLine: MarkdownMedia.markdown(forFile: "board photo (2).png", caption: "Board"), at: 0)?.source,
                       "attachments/board photo (2).png")
        XCTAssertEqual(MarkdownMedia.resized("![Board](attachments/b.png)", width: 300), "![Board|300](attachments/b.png)")
        XCTAssertEqual(MarkdownMedia.resized("![Board|300](attachments/b.png)", width: nil), "![Board](attachments/b.png)")
        XCTAssertEqual(MarkdownMedia.resized("![[b.png]]", width: 250), "![[b.png|250]]")
    }

    func testFindingAttachmentsAndNotLinkingThem() {
        let text = "![a](attachments/one.png)\n[minutes](attachments/minutes%20v2.pdf)\n![[two.jpg]] and [[Launch plan]]"
        XCTAssertEqual(MarkdownMedia.attachmentNames(in: text), ["one.png", "minutes v2.pdf", "two.jpg"])
        XCTAssertEqual(WikiLinks.targets(in: text), ["Launch plan"])
    }
}

final class MarkdownEditingMoreTests: XCTestCase {
    func testMovingLines() {
        let text = "one\ntwo\nthree"
        let down = MarkdownEditing.moveLines(text, selection: NSRange(location: 1, length: 0), up: false)
        XCTAssertEqual(down?.text, "two\none\nthree")
        XCTAssertEqual(down?.selection, NSRange(location: 5, length: 0))
        let last = MarkdownEditing.moveLines(text, selection: NSRange(location: 9, length: 0), up: true)
        XCTAssertEqual(last?.text, "one\nthree\ntwo")
        XCTAssertEqual(last?.selection, NSRange(location: 5, length: 0))
        XCTAssertEqual(MarkdownEditing.moveLines("one\ntwo\nthree", selection: NSRange(location: 4, length: 0), up: false)?.text, "one\nthree\ntwo")
        // Two lines selected, the selection ending at the start of the third: those two move.
        let two = MarkdownEditing.moveLines("a\nb\nc\nd", selection: NSRange(location: 2, length: 4), up: true)
        XCTAssertEqual(two?.text, "b\nc\na\nd")
        XCTAssertEqual(two?.selection, NSRange(location: 0, length: 4))
        XCTAssertNil(MarkdownEditing.moveLines(text, selection: NSRange(location: 0, length: 0), up: true))
        XCTAssertNil(MarkdownEditing.moveLines(text, selection: NSRange(location: 10, length: 0), up: false))
    }

    func testCodeBlocksInLists() {
        // A fence typed into an item opens a code block instead of carrying the marker onto every line of code.
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "- [ ] ```swift", inCodeBlock: false), .openCodeBlock(dropping: 6))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "  1. ```", inCodeBlock: false), .openCodeBlock(dropping: 5))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "> ~~~", inCodeBlock: false), .openCodeBlock(dropping: 2))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "- run ```make```", inCodeBlock: false), .continueWith("- "))
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "```swift", inCodeBlock: false), .newline)
        XCTAssertEqual(MarkdownEditing.returnAction(lineBeforeCursor: "# ```", inCodeBlock: false), .newline)
        // The code block button on an item with nothing in it yet takes the item's place.
        let text = "Intro\n- [x] Test\n- [ ] \nEnd"
        let edit = MarkdownEditing.insertCodeBlock(text, selection: NSRange(location: 23, length: 0))
        XCTAssertEqual(edit.text, "Intro\n- [x] Test\n```\n\n```\nEnd")
        XCTAssertEqual(edit.selection, NSRange(location: 21, length: 0))
        // On an item with words in it, the block goes after it as before.
        XCTAssertEqual(MarkdownEditing.insertCodeBlock("- [ ] Upload", selection: NSRange(location: 12, length: 0)).text, "- [ ] Upload\n```\n\n```\n")
    }

    func testWebAddressesAreLinks() {
        let text = "See https://example.com/a_b_c/page?x=1. Or mail mailto:hi@example.com, or [the docs](https://docs.example.com)."
        let string = text as NSString
        let autolinks = MarkdownSyntax.spans(in: text).filter { $0.style == .autolink }.map { string.substring(with: $0.range) }
        XCTAssertEqual(autolinks, ["https://example.com/a_b_c/page?x=1", "mailto:hi@example.com"])
        XCTAssertFalse(MarkdownSyntax.spans(in: text).contains { $0.style == .italic }, "underscores in an address aren't emphasis")
    }
}

final class MarkdownTablesTests: XCTestCase {
    let text = "Before\n| Name | Due |\n| :--- | ---: |\n| **Draft** | Friday |\n|  | `a|b` |\nAfter"

    func testReadingATable() throws {
        let string = text as NSString
        let table = try XCTUnwrap(MarkdownTables.table(around: string.range(of: "Draft").location, in: string))
        XCTAssertEqual(table.alignments, [.left, .right])
        XCTAssertEqual(table.rows.count, 4)
        XCTAssertEqual(string.substring(with: table.range), "| Name | Due |\n| :--- | ---: |\n| **Draft** | Friday |\n|  | `a|b` |\n")
        XCTAssertEqual(table.rows[2].cells.map { string.substring(with: $0) }, ["**Draft**", "Friday"])
        XCTAssertEqual(table.rows[3].cells.map { string.substring(with: $0) }, ["", "`a|b`"], "a pipe in code is part of the cell")
        XCTAssertTrue(table.rows[0].isHeader)
        XCTAssertTrue(table.rows[1].isDelimiter)
        XCTAssertNil(MarkdownTables.table(around: 0, in: string))
        XCTAssertNil(MarkdownTables.table(around: 0, in: "| just | pipes |\n| no | dashes |" as NSString))
    }

    func testStylingARow() {
        let string = text as NSString
        let spans = MarkdownSyntax.spans(in: text)
        let row = string.lineRange(for: string.range(of: "Draft"))
        let inRow = spans.filter { NSIntersectionRange($0.range, row).length > 0 }
        XCTAssertEqual(inRow.filter { $0.style == .tableTab }.count, 2, "the first two pipes move on a column")
        XCTAssertTrue(inRow.contains { $0.style == .bold }, "words in cells are styled as usual")
        XCTAssertTrue(spans.contains { if case .tableRow(_, _, true) = $0.style { return string.substring(with: $0.range) == "| :--- | ---: |" } else { return false } })
        // Some lines styled alone give what styling the whole note gives for them.
        XCTAssertEqual(MarkdownSyntax.spans(in: text, lines: row), spans.filter { NSIntersectionRange($0.range, row).length > 0 })
    }
}

final class CodeHighlighterTests: XCTestCase {
    private func tokens(_ line: String, _ language: String) -> [String] {
        CodeHighlighter.spans(in: line, language: language).map { "\($0.token):\((line as NSString).substring(with: $0.range))" }
    }

    func testColouringALine() {
        XCTAssertEqual(tokens(#"let count = Items.filter { $0.done }.count // "done" ones"#, "swift"),
                       ["keyword:let", "type:Items", "comment:// \"done\" ones"])
        XCTAssertEqual(tokens(#"curl -s "https://example.com/#top" # fetch it"#, "bash"),
                       ["string:\"https://example.com/#top\"", "comment:# fetch it"])
        XCTAssertEqual(tokens("SELECT name FROM users WHERE age > 30 -- adults", "sql"),
                       ["keyword:SELECT", "keyword:FROM", "keyword:WHERE", "number:30", "comment:-- adults"])
        XCTAssertEqual(tokens("#include <stdio.h>", "c"), [], "a C include isn't a comment")
        XCTAssertEqual(tokens("x = 0x1F + 2.5e3", "python"), ["number:0x1F", "number:2.5e3"])
        XCTAssertEqual(tokens("make import-test ROWS=50000 && open reports/import.html", "bash"), ["number:50000"], "words in commands and paths aren't keywords")
        XCTAssertEqual(tokens("for f in *.md; do echo $f; done", "zsh"), ["keyword:for", "keyword:in", "keyword:do", "keyword:done"])
    }

    func testCodeLinesKnowTheirLanguage() {
        let text = "```swift\nlet a = 1\n```\n~~~\nplain\n~~~"
        let languages = MarkdownSyntax.spans(in: text).compactMap { span -> String? in
            if case .codeLine(let language) = span.style { return language } else { return nil }
        }
        XCTAssertEqual(languages, ["swift", ""])
        let second = (text as NSString).range(of: "let a")
        XCTAssertTrue(MarkdownSyntax.spans(in: text, lines: second).contains { $0.style == .codeLine(language: "swift") })
    }
}
