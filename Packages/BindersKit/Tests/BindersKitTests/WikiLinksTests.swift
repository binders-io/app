import XCTest
@testable import BindersKit

final class WikiLinksTests: XCTestCase {
    func testReadsLinksWithAndWithoutWhatToShow() {
        let links = WikiLinks.links(in: "See [[Launch readiness review]] and [[Maya Okafor|Maya]]. Not [this](https://example.com).")
        XCTAssertEqual(links.map(\.target), ["Launch readiness review", "Maya Okafor"])
        XCTAssertEqual(links.map(\.label), ["Launch readiness review", "Maya"])
        XCTAssertTrue(WikiLinks.text("Ask [[maya  okafor]] first", linksTo: "Maya Okafor"), "case and spaces don't matter")
        XCTAssertFalse(WikiLinks.text("Ask Maya Okafor first", linksTo: "Maya Okafor"))
    }

    func testFindsPlainMentionsAsWholePhrasesOutsideLinks() {
        XCTAssertNotNil(WikiLinks.plainMention(of: "Pricing page", in: "The pricing page needs a second pass."))
        XCTAssertNil(WikiLinks.plainMention(of: "Pricing page", in: "The pricing pages are done."), "whole words only")
        XCTAssertNil(WikiLinks.plainMention(of: "Pricing page", in: "See [[Pricing page]]."), "already a link")
        XCTAssertNil(WikiLinks.plainMention(of: "Al", in: "Al said so"), "too short to mean anything")
    }

    func testLinksTheFirstPlainMention() {
        XCTAssertEqual(WikiLinks.linkingFirstMention(of: "Pricing page", in: "Fix the Pricing page, then the pricing page copy."),
                       "Fix the [[Pricing page]], then the pricing page copy.")
        XCTAssertEqual(WikiLinks.linkingFirstMention(of: "Pricing page", in: "the pricing page"), "the [[Pricing page|pricing page]]")
        XCTAssertNil(WikiLinks.linkingFirstMention(of: "Pricing page", in: "nothing here"))
    }

    func testKnowsWhenTheCursorIsInAnUnfinishedLink() {
        let text = "Notes from [[Laun"
        XCTAssertEqual(WikiLinks.partialLink(before: (text as NSString).length, in: text), NSRange(location: 13, length: 4))
        XCTAssertEqual(WikiLinks.partialLink(before: 13, in: text), NSRange(location: 13, length: 0), "right after [[")
        XCTAssertNil(WikiLinks.partialLink(before: 10, in: text))
        let done = "[[Launch]] and more"
        XCTAssertNil(WikiLinks.partialLink(before: (done as NSString).length, in: done))
        let alias = "[[Launch|the la"
        XCTAssertNil(WikiLinks.partialLink(before: (alias as NSString).length, in: alias))
    }

    func testTheEditorSeesLinks() {
        let spans = MarkdownSyntax.spans(in: "See [[Maya Okafor|Maya]] today")
        XCTAssertTrue(spans.contains(MarkdownSpan(NSRange(location: 18, length: 4), .wikiLink(target: "Maya Okafor"))))
        XCTAssertEqual(spans.filter { $0.style == .syntax }.count, 3, "[[, the title and |, and ]]")
    }
}
