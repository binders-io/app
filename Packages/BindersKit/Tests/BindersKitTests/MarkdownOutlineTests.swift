import XCTest
@testable import BindersKit

final class MarkdownOutlineTests: XCTestCase {
    func testListsHeadingsWithTheirDepthAndPlace() {
        let text = "# Launch plan\n\nIntro\n\n## Goals\n- one\n### **Stretch** goals\n```\n# not a heading\n```\n## Risks"
        let headings = MarkdownOutline.headings(in: text)
        XCTAssertEqual(headings.map(\.title), ["Launch plan", "Goals", "Stretch goals", "Risks"])
        XCTAssertEqual(headings.map(\.level), [1, 2, 3, 2])
        XCTAssertEqual((text as NSString).substring(from: headings[1].location).prefix(8), "## Goals")
        XCTAssertTrue(MarkdownOutline.headings(in: "#hashtag, not a heading").isEmpty)
    }
}
