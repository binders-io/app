import XCTest
@testable import BindersKit

/// Signing in to a hub: the address as typed, the page the browser opens, and the binders://auth link the hub hands the
/// person token back with, as the hub makes them (binders-server's /auth/app). Hubs and people are made up.
final class HubSignInTests: XCTestCase {
    func testAddressAsTyped() {
        XCTAssertEqual(HubSignIn.address("hub.example.com")?.absoluteString, "https://hub.example.com")
        XCTAssertEqual(HubSignIn.address("  https://Hub.Example.com/  ")?.absoluteString, "https://hub.example.com", "trimmed, lower-cased, no slash")
        XCTAssertEqual(HubSignIn.address("https://hub.example.com/binders/board?x=1#y")?.absoluteString, "https://hub.example.com",
                       "a page of the hub's web app is its hub")
        XCTAssertEqual(HubSignIn.address("hub.example.com:8443")?.absoluteString, "https://hub.example.com:8443")
        XCTAssertEqual(HubSignIn.address("http://localhost:8787")?.absoluteString, "http://localhost:8787", "http on this Mac")
        XCTAssertEqual(HubSignIn.address("http://studio.local:8787")?.absoluteString, "http://studio.local:8787", "and on a .local name")
        XCTAssertNil(HubSignIn.address("http://hub.example.com"), "http elsewhere would send the token in the clear")
        XCTAssertNil(HubSignIn.address(""))
        XCTAssertNil(HubSignIn.address("hub example"))
        XCTAssertNil(HubSignIn.address("ftp://hub.example.com"))
        XCTAssertNil(HubSignIn.addressProblem("hub.example.com"))
        XCTAssertEqual(HubSignIn.addressProblem(" "), "Enter your hub's address, such as hub.example.com.")
        XCTAssertEqual(HubSignIn.addressProblem("http://hub.example.com"), "A hub is reached with https://, unless it runs on this Mac.")
    }

    func testStateIsOneTheHubTakes() {
        let state = HubSignIn.newState()
        XCTAssertNotNil(state.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression), state)
        XCTAssertNotEqual(state, HubSignIn.newState())
    }

    func testSignInPage() throws {
        let url = try XCTUnwrap(HubSignIn.signInURL(hub: XCTUnwrap(HubSignIn.address("hub.example.com")), state: "abcDEF123_-xyz",
                                                    app: "Binders for Mac on Robin’s MacBook"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "hub.example.com")
        XCTAssertEqual(parts.path, "/auth/app")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "state" }?.value, "abcDEF123_-xyz")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "app" }?.value, "Binders for Mac on Robin’s MacBook")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "redirect" }?.value, "binders://auth")
    }

    func testHandBack() throws {
        // As the hub builds it: new URL('binders://auth') with token, state and hub set.
        let link = try XCTUnwrap(URL(string: "binders://auth?token=bnp_q1w2e3r4t5y6&state=abcDEF123_-xyz&hub=https%3A%2F%2Fhub.example.com"))
        XCTAssertEqual(HubSignIn.callback(in: link), HubSignIn.Callback(token: "bnp_q1w2e3r4t5y6", state: "abcDEF123_-xyz", hub: URL(string: "https://hub.example.com")))
        XCTAssertEqual(HubSignIn.outcome(of: link, expecting: "abcDEF123_-xyz"), .signedIn(token: "bnp_q1w2e3r4t5y6"))
        XCTAssertEqual(HubSignIn.outcome(of: link, expecting: "another-state-1"), .notAsked, "another sign-in's state")
        XCTAssertEqual(HubSignIn.outcome(of: link, expecting: nil), .notAsked, "no sign-in started on this Mac")
        XCTAssertEqual(HubSignIn.outcome(of: URL(string: "binders://auth?token=bnd_agent&state=abcDEF123_-xyz")!, expecting: "abcDEF123_-xyz"), .unreadable,
                       "an agent's token isn't a person's")
        XCTAssertEqual(HubSignIn.outcome(of: URL(string: "binders://auth?state=abcDEF123_-xyz")!, expecting: "abcDEF123_-xyz"), .unreadable)
        XCTAssertEqual(HubSignIn.outcome(of: URL(string: "binders://todo?token=bnp_x&state=s")!, expecting: "s"), .unreadable)
    }

    func testWhoIsSignedIn() throws {
        let me = Data(#"{"user":{"login":"robin-h","name":"Robin Hale","avatar":"https://avatars.example.com/u/1"},"github":{"token":true},"publicUrl":"https://hub.example.com"}"#.utf8)
        let person = try XCTUnwrap(HubSignIn.person(fromMe: me))
        XCTAssertEqual(person, HubSignIn.Person(login: "robin-h", name: "Robin Hale", avatar: "https://avatars.example.com/u/1"))
        XCTAssertEqual(person.line, "Robin Hale (@robin-h)")
        XCTAssertEqual(HubSignIn.Person(login: "robin-h", name: "Robin-H").line, "@robin-h")
        XCTAssertNil(HubSignIn.person(fromMe: Data(#"{"error":"Sign in first."}"#.utf8)))

        let tokens = Data(#"{"tokens":[{"id":"aaa","app":"Binders for Mac on the studio","at":"2026-10-29T10:00:00Z","current":false},{"id":"bbb","app":"Binders for Mac","at":"2026-10-30T10:00:00Z","current":true}]}"#.utf8)
        XCTAssertEqual(HubSignIn.currentTokenID(fromTokens: tokens), "bbb")
        XCTAssertNil(HubSignIn.currentTokenID(fromTokens: Data(#"{"tokens":[]}"#.utf8)))
    }
}
