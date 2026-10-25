import XCTest
@testable import BindersKit

final class MarkdownDiagramsTests: XCTestCase {
    func testFindsMermaidFences() throws {
        let text = "# Plan\n```mermaid\nflowchart TD\n  A --> B\n```\nAfter\n"
        let blocks = MarkdownDiagrams.mermaidBlocks(in: text)
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(block.source, "flowchart TD\n  A --> B")
        let string = text as NSString
        XCTAssertEqual(string.substring(with: block.range), "```mermaid\nflowchart TD\n  A --> B\n```\n")
        XCTAssertEqual(string.substring(with: block.opening), "```mermaid")
        XCTAssertEqual(string.substring(with: block.closing), "```")
    }

    func testInfoStringVariants() {
        for opening in ["```mermaid", "```Mermaid", "```MERMAID", "~~~mermaid", "```` mermaid", "``` mermaid {.wide}", "  ```mermaid", "```mermaid   "] {
            let closing = opening.contains("~") ? "~~~" : opening.hasPrefix("````") ? "````" : "```"
            let text = "\(opening)\nsequenceDiagram\n  A->>B: hi\n\(closing)"
            XCTAssertEqual(MarkdownDiagrams.mermaidBlocks(in: text).count, 1, opening)
        }
        for opening in ["```mermaidx", "```js mermaid", "```", "```mer`maid", "    ```mermaid", "``mermaid"] {
            let text = "\(opening)\ngraph TD\n```"
            XCTAssertTrue(MarkdownDiagrams.mermaidBlocks(in: text).isEmpty, opening)
        }
        // The text at the end of a note with no line ending after its closing fence.
        let last = MarkdownDiagrams.mermaidBlocks(in: "Intro\n~~~mermaid\npie\n~~~")
        XCTAssertEqual(last.first?.range, NSRange(location: 6, length: 18))
    }

    func testUnclosedAndMismatchedFences() {
        XCTAssertTrue(MarkdownDiagrams.mermaidBlocks(in: "```mermaid\ngraph TD\n  A --> B\n").isEmpty, "a block not yet closed isn't drawn")
        // A tilde fence doesn't close a backtick one, nor a shorter one a longer one; a fence with words after it doesn't close.
        let mixed = "```mermaid\ngraph TD\n~~~\n``` x\n```\nAfter"
        XCTAssertEqual(MarkdownDiagrams.mermaidBlocks(in: mixed).map(\.source), ["graph TD\n~~~\n``` x"])
        let longer = "````mermaid\ngraph TD\n```\n`````  \nAfter"
        XCTAssertEqual(MarkdownDiagrams.mermaidBlocks(in: longer).map(\.source), ["graph TD\n```"], "a longer fence closes, a shorter one doesn't")
    }

    func testFencesInsideOtherFences() {
        // A Markdown example that shows how to write a diagram is the example's text, not a diagram.
        let text = "````markdown\n```mermaid\ngraph TD\n```\n````\n\n```mermaid\npie\n```\n"
        let blocks = MarkdownDiagrams.mermaidBlocks(in: text)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.source, "pie")
        let tildes = "~~~\n```mermaid\ngraph TD\n```\n~~~"
        XCTAssertTrue(MarkdownDiagrams.mermaidBlocks(in: tildes).isEmpty)
    }

    func testIndentedFenceDropsItsIndentFromTheSource() {
        let text = "  ```mermaid\n  graph TD\n    A --> B\n C\n  ```"
        XCTAssertEqual(MarkdownDiagrams.mermaidBlocks(in: text).first?.source, "graph TD\n  A --> B\nC")
    }

    func testSeveralBlocksAndCRLF() {
        let text = "```mermaid\npie\n```\ntext\n```mermaid\ngraph LR\n```\r\n```mermaid\nsequenceDiagram\r\n```\r\n"
        let blocks = MarkdownDiagrams.mermaidBlocks(in: text)
        XCTAssertEqual(blocks.map(\.source), ["pie", "graph LR", "sequenceDiagram"])
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(MarkdownDiagrams.mermaidBlocks(in: "No diagrams here.\n```swift\nlet a = 1\n```").isEmpty)
        XCTAssertFalse(MarkdownDiagrams.mightContainMermaid("```swift\nlet a = 1\n```"))
    }

    func testCacheKeys() {
        XCTAssertEqual(MarkdownDiagrams.widthBucket(655), 640)
        XCTAssertEqual(MarkdownDiagrams.widthBucket(640), 640)
        XCTAssertEqual(MarkdownDiagrams.widthBucket(90), 160)
        XCTAssertEqual(MarkdownDiagrams.widthBucket(.infinity), 160)
        let key = MarkdownDiagrams.cacheKey(source: "pie", theme: "dark", width: 655)
        XCTAssertEqual(key, MarkdownDiagrams.cacheKey(source: "pie", theme: "dark", width: 670), "a few points wider draws nothing again")
        XCTAssertNotEqual(key, MarkdownDiagrams.cacheKey(source: "pie", theme: "neutral", width: 655))
        XCTAssertNotEqual(key, MarkdownDiagrams.cacheKey(source: "pie ", theme: "dark", width: 655))
        XCTAssertNotEqual(key, MarkdownDiagrams.cacheKey(source: "pie", theme: "dark", width: 700))
    }

    func testErrorLine() {
        XCTAssertEqual(MarkdownDiagrams.errorLine("Lexical error on line 3. Unrecognized text.\n...chart TD  A -->\n-----^"),
                       "Mermaid couldn't draw this: Lexical error on line 3. Unrecognized text.")
        XCTAssertEqual(MarkdownDiagrams.errorLine("Parse error on line 2:\n...\nExpecting 'SEMI'"), "Mermaid couldn't draw this: Parse error on line 2")
        XCTAssertEqual(MarkdownDiagrams.errorLine("UnknownDiagramError: No diagram type detected"),
                       "Mermaid couldn't draw this: No diagram type detected")
        XCTAssertEqual(MarkdownDiagrams.errorLine(""), "Mermaid couldn't draw this.")
        XCTAssertLessThanOrEqual(MarkdownDiagrams.errorLine(String(repeating: "x", count: 500)).count, 190)
    }
}
