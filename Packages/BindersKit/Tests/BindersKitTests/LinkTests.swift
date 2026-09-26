import CryptoKit
import XCTest
@testable import BindersKit

final class LinkTests: XCTestCase {
    func testPairingLinksRoundTrip() throws {
        let pairing = LinkPairing(name: "Maya's MacBook Pro", addresses: ["192.168.1.20:7448", "100.101.102.103:7448"],
                                  secret: Link.randomBytes(16), expires: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(pairing.url.scheme, "binders")
        XCTAssertEqual(pairing.url.host, "pair")
        XCTAssertFalse(pairing.url.absoluteString.contains("+"), "URL-safe base64")
        XCTAssertEqual(LinkPairing(url: pairing.url), pairing)
        XCTAssertNil(LinkPairing(url: URL(string: "binders://pair?d=nonsense")!))
        XCTAssertNil(LinkPairing(url: URL(string: "https://binders.io")!))
        XCTAssertTrue(pairing.isExpired(at: Date(timeIntervalSince1970: 1_790_000_001)))
    }

    func testBothEndsDeriveTheSamePairingKey() {
        let secret = Link.randomBytes(16)
        let a = Link.pairingKey(secret: secret).withUnsafeBytes { Data($0) }
        let b = Link.pairingKey(secret: secret).withUnsafeBytes { Data($0) }
        let other = Link.pairingKey(secret: Link.randomBytes(16)).withUnsafeBytes { Data($0) }
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, other)
        XCTAssertEqual(a.count, 32)
    }

    func testProofsOnlyVerifyWithTheRightKey() {
        let key = SymmetricKey(size: .bits256), challenge = Link.randomBytes(32)
        let proof = Link.proof(challenge: challenge, key: key)
        XCTAssertTrue(Link.verify(proof: proof, challenge: challenge, key: key))
        XCTAssertFalse(Link.verify(proof: proof, challenge: Link.randomBytes(32), key: key))
        XCTAssertFalse(Link.verify(proof: proof, challenge: challenge, key: SymmetricKey(size: .bits256)))
    }

    func testLinesSplitAcrossPackets() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)), [Data("{\"a\":1}".utf8)])
        XCTAssertEqual(buffer.append(Data(":2}\n\n{\"c\":3}\n".utf8)), [Data("{\"b\":2}".utf8), Data("{\"c\":3}".utf8)])
        XCTAssertEqual(buffer.append(Data()), [])
    }

    func testOversizedMessagesAreDropped() {
        var buffer = LineBuffer()
        _ = buffer.append(Data(repeating: 0x41, count: Link.maximumMessageSize + 1))
        XCTAssertTrue(buffer.overflowed)
    }

    func testAddresses() {
        XCTAssertEqual(LinkClient.split("192.168.1.20:7447")?.host, "192.168.1.20")
        XCTAssertEqual(LinkClient.split("192.168.1.20:7447")?.port, 7447)
        XCTAssertEqual(LinkClient.split("[fd7a:115c::1]:7448")?.host, "fd7a:115c::1")
        XCTAssertEqual(LinkClient.split("macbook.tail1234.ts.net:7447")?.host, "macbook.tail1234.ts.net")
        XCTAssertNil(LinkClient.split("no-port"))
    }
}
