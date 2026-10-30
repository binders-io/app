import XCTest
@testable import BindersKit

final class HubFilesTests: XCTestCase {
    let picture = "0123456789abcdef01234567.png"

    func testKnowsWhatTheHubTakes() {
        XCTAssertEqual(HubFiles.contentType(of: "Pasted image.PNG"), "image/png")
        XCTAssertEqual(HubFiles.contentType(of: "board.jpeg"), "image/jpeg")
        XCTAssertNil(HubFiles.contentType(of: "photo.heic"), "HEIC is made into a JPEG first")
        XCTAssertNil(HubFiles.contentType(of: "demo.mov"))
    }

    func testReadsTheHubsNames() {
        XCTAssertEqual(HubFiles.hubName(in: "/api/files/\(picture)"), picture)
        XCTAssertNil(HubFiles.hubName(in: "/api/files/../secret.png"))
        XCTAssertNil(HubFiles.hubName(in: "attachments/\(picture)"))
        XCTAssertNil(HubFiles.hubName(in: "/Users/me/photo.png"))
        let text = "# Trip\n![Harbour](/api/files/\(picture))\nSee [it](</api/files/abcdefabcdefabcdefabcdef.jpg>) and ![](/api/files/nope.png)"
        XCTAssertEqual(HubFiles.hubNames(in: text), [picture, "abcdefabcdefabcdefabcdef.jpg"])
    }

    func testFindsTheMacsOwnPictures() {
        let text = "![a](attachments/one.png)\n[minutes](attachments/minutes.pdf)\n![](attachments/clip.mov)\n![[two%20.jpg]]\n![b](/api/files/\(picture))"
        XCTAssertEqual(HubFiles.localPictures(in: text), ["one.png", "two%20.jpg"])
    }

    func testPointsPicturesAtTheHubsCopies() {
        let text = """
        # Trip
        ![Harbour at dusk|300](attachments/Pasted%20image%202026-10-30%20at%2012.00.00.png)
        Inline ![x](attachments/board%20%282%29.png) too.
        ![[board (2).png|Board]]
        ![[board (2).png|480]]
        [minutes](attachments/minutes.pdf)
        ![Not sent](attachments/other.png)
        """
        let sent = ["Pasted image 2026-10-30 at 12.00.00.png": picture, "board (2).png": "abcdefabcdefabcdefabcdef.jpg"]
        XCTAssertEqual(HubFiles.pointing(text, to: sent), """
        # Trip
        ![Harbour at dusk|300](/api/files/\(picture))
        Inline ![x](/api/files/abcdefabcdefabcdefabcdef.jpg) too.
        ![Board](/api/files/abcdefabcdefabcdefabcdef.jpg)
        ![|480](/api/files/abcdefabcdefabcdefabcdef.jpg)
        [minutes](attachments/minutes.pdf)
        ![Not sent](attachments/other.png)
        """)
        XCTAssertEqual(HubFiles.pointing(text, to: [:]), text)
        let line = HubFiles.pointing("![|480](attachments/board.png)", to: ["board.png": picture])
        XCTAssertEqual(MarkdownMedia.embed(inLine: line, at: 0)?.width, 480, "a width stays a width")
        XCTAssertEqual(MarkdownMedia.embed(inLine: line, at: 0)?.source, "/api/files/\(picture)")
    }
}
