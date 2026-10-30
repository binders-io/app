import AppKit
import Foundation
import BindersKit

/// Settings → Team signs in to a hub (HubAccount), in a throwaway folder (BINDERS_DATA_DIR), with a stand-in hub that
/// answers as binders-server does: Sign In opens the hub's /auth/app with a state; a binders://auth link this Mac didn't
/// start, or with another state, keeps nothing; the hand-back keeps the bnp_ token in the Keychain and the GitHub login
/// the hub's /api/me says, which Settings → Team shows; a token the hub no longer takes signs this Mac out; Sign Out
/// revokes the token on the hub (DELETE /api/tokens/<its id>) and deletes it. Draws Settings → Team signed out, waiting
/// and signed in to `dir`, when one is given.
///
/// With BINDERS_TEST_HUB (a hub's address) and BINDERS_TEST_HUB_COOKIE (a binders_session cookie of someone signed in
/// there), it signs in to that hub for real: /auth/app hands the token back, /api/me says who, and after Sign Out the
/// hub refuses the token.
///
///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-hub-signin [dir]
extension SelfTest {
    @MainActor
    static func hubSignInSelfTest(drawingTo directory: URL?) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test saves a hub's address there")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        // The Keychain is this Mac's own: whatever token was there is put back at the end.
        let kept = Keychain.read(HubAccount.tokenKey)
        defer { Keychain.write(kept ?? "", for: HubAccount.tokenKey) }
        Keychain.write("", for: HubAccount.tokenKey)

        let controller = DictationController()
        let account = HubAccount.shared
        var opened: [URL] = []
        account.openPage = { opened.append($0) }

        // A stand-in hub: who each token is, and which are still live.
        var live: [String: (id: String, login: String, name: String)] = [:]
        var asked: [String] = []
        account.send = { request in
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            asked.append("\(method) \(path)")
            let bearer = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer ", with: "")
            func answer(_ status: Int, _ json: String) -> (Data, URLResponse) {
                (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            guard request.url?.host == "hub.example.com", let person = live[bearer] else {
                return answer(401, #"{"error":"This hub doesn’t know that token. Sign in again."}"#)
            }
            switch (method, path) {
            case ("GET", "/api/me"):
                return answer(200, #"{"user":{"login":"\#(person.login)","name":"\#(person.name)"},"publicUrl":"https://hub.example.com"}"#)
            case ("GET", "/api/tokens"):
                return answer(200, #"{"tokens":[{"id":"other1","app":"Binders for Mac on the studio","at":"2026-10-29T10:00:00Z","current":false},{"id":"\#(person.id)","app":"\#(HubAccount.appName)","at":"2026-10-30T10:00:00Z","current":true}]}"#)
            case ("DELETE", "/api/tokens/\(person.id)"):
                live[bearer] = nil
                return answer(200, #"{"ok":true}"#)
            default:
                return answer(404, #"{"error":"Not here."}"#)
            }
        }
        func page(_ name: String) async -> Set<String> {
            await teamSettingsDrawn(controller: controller, name: name, directory: directory, height: 1100)
        }

        // MARK: Signed out: an address and Sign In, on a fresh Mac.
        check(!account.isSignedIn && account.address == nil && account.person == nil, "a fresh Mac isn't signed in to a hub")
        let out = await page("hub-signed-out")
        check(out.contains("team.hub") && out.contains("field.team.hub") && out.contains("team.hub.signIn") && !out.contains("team.hub.signOut"),
              "Settings → Team asks for a hub's address, with Sign In")
        account.signIn(to: "http://hub.example.com")
        check(opened.isEmpty && account.pending == nil && account.problem == "A hub is reached with https://, unless it runs on this Mac.",
              "an http:// hub elsewhere isn't signed in to: \(account.problem ?? "")")

        // MARK: Sign In opens the hub's sign-in with a state of this Mac's own.
        account.signIn(to: "  Hub.Example.com/board ")
        let state = account.pending?.state ?? ""
        let parts = opened.last.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        check(opened.count == 1 && parts?.scheme == "https" && parts?.host == "hub.example.com" && parts?.path == "/auth/app"
                && parts?.queryItems?.first { $0.name == "state" }?.value == state && state.count >= 32
                && parts?.queryItems?.first { $0.name == "redirect" }?.value == "binders://auth"
                && parts?.queryItems?.first { $0.name == "app" }?.value == HubAccount.appName,
              "Sign In opens https://hub.example.com/auth/app with this Mac's state and name: \(opened.last?.absoluteString ?? "nothing")")
        check(account.problem == nil && !account.isSignedIn, "and waits for the browser")
        let waiting = await page("hub-waiting")
        check(waiting.contains("team.hub.waiting"), "Settings → Team says to finish in the browser")

        // MARK: Links it didn't ask for keep nothing.
        live["bnp_forged0000"] = ("forged", "mallory", "Mallory")
        live["bnp_robin00001"] = ("tok1", "robin-h", "Robin Hale")
        URLCommands.handle(URL(string: "binders://auth?token=bnp_forged0000&state=not-this-macs-state&hub=https%3A%2F%2Fhub.example.com")!, controller: controller)
        try? await Task.sleep(for: .milliseconds(200))
        check(Keychain.read(HubAccount.tokenKey) == nil && !account.isSignedIn && account.pending?.state == state && account.problem != nil,
              "a binders://auth link with another state keeps nothing, and the sign-in still waits: \(account.problem ?? "")")

        // MARK: The hand-back: the token in the Keychain, and who the hub says it is.
        URLCommands.handle(URL(string: "binders://auth?token=bnp_robin00001&state=\(state)&hub=https%3A%2F%2Fhub.example.com")!, controller: controller)
        for _ in 0..<20 where account.person == nil { try? await Task.sleep(for: .milliseconds(100)) }
        check(Keychain.read(HubAccount.tokenKey) == "bnp_robin00001" && account.isSignedIn && account.pending == nil,
              "the hand-back keeps the bnp_ token in the Keychain")
        check(account.address?.absoluteString == "https://hub.example.com" && AppDefaults.store.string(forKey: HubAccount.addressKey) == "https://hub.example.com",
              "and the hub's address")
        check(account.person?.login == "robin-h" && account.person?.line == "Robin Hale (@robin-h)" && asked.last == "GET /api/me",
              "the hub's /api/me says who: \(account.person?.line ?? "no one")")
        check(account.authorized("api/state")?.value(forHTTPHeaderField: "Authorization") == "Bearer bnp_robin00001",
              "requests to the hub carry it as a Bearer token")
        let signedIn = await page("hub-signed-in")
        check(signedIn.contains("team.hub.person") && signedIn.contains("team.hub.signOut") && !signedIn.contains("team.hub.signIn"),
              "Settings → Team shows who's signed in, with Sign Out")
        // The same hand-back again, now nothing waits: kept no more than a forged one.
        URLCommands.handle(URL(string: "binders://auth?token=bnp_forged0000&state=\(state)")!, controller: controller)
        try? await Task.sleep(for: .milliseconds(200))
        check(Keychain.read(HubAccount.tokenKey) == "bnp_robin00001" && account.person?.login == "robin-h",
              "a hand-back replayed after signing in changes nothing")
        check(HubAccount().person?.login == "robin-h" && HubAccount().isSignedIn, "who's signed in is kept across launches")

        // MARK: Sign Out: revoked on the hub, and gone from this Mac.
        await account.signOut()
        check(asked.suffix(2) == ["GET /api/tokens", "DELETE /api/tokens/tok1"] && live["bnp_robin00001"] == nil,
              "Sign Out revokes this Mac's token on the hub, and only it: \(asked.suffix(2))")
        check(Keychain.read(HubAccount.tokenKey) == nil && !account.isSignedIn && account.person == nil && account.problem == nil,
              "and removes it from the Keychain")
        check(account.address?.absoluteString == "https://hub.example.com", "the hub's address stays, to sign in again")
        let after = await page("hub-signed-out-again")
        check(after.contains("team.hub.signIn") && !after.contains("team.hub.person"), "Settings → Team offers Sign In again")

        // MARK: A token the hub stopped (from the web app's Settings → You) signs this Mac out when it next asks.
        account.signIn(to: "hub.example.com")
        URLCommands.handle(URL(string: "binders://auth?token=bnp_robin00001&state=\(account.pending?.state ?? "")")!, controller: controller)
        for _ in 0..<20 where account.person == nil { try? await Task.sleep(for: .milliseconds(100)) }
        live["bnp_robin00001"] = nil
        await account.refresh()
        check(!account.isSignedIn && Keychain.read(HubAccount.tokenKey) == nil && account.problem == "The hub signed this Mac out. Sign in again.",
              "a token the hub no longer takes is signed out here: \(account.problem ?? "")")

        // MARK: Sign Out while the hub can't be reached still forgets it here, and says what's left to do.
        account.signIn(to: "hub.example.com")
        live["bnp_robin00002"] = ("tok2", "robin-h", "Robin Hale")
        URLCommands.handle(URL(string: "binders://auth?token=bnp_robin00002&state=\(account.pending?.state ?? "")")!, controller: controller)
        for _ in 0..<20 where account.person == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let send = account.send
        account.send = { _ in throw URLError(.notConnectedToInternet) }
        await account.signOut()
        check(!account.isSignedIn && Keychain.read(HubAccount.tokenKey) == nil && account.problem?.hasPrefix("Signed out on this Mac.") == true,
              "Sign Out offline forgets the token here and says to remove it on the hub: \(account.problem ?? "")")
        account.send = send

        // MARK: A real hub, when one is given.
        if let hub = ProcessInfo.processInfo.environment["BINDERS_TEST_HUB"], let cookie = ProcessInfo.processInfo.environment["BINDERS_TEST_HUB_COOKIE"] {
            failures += await realHubChecks(hub: hub, cookie: cookie, controller: controller)
        } else {
            print("SKIP: a real hub (set BINDERS_TEST_HUB and BINDERS_TEST_HUB_COOKIE)")
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    /// Signs in to a running hub as the browser would with a session there: /auth/app hands the token back to
    /// binders://auth, which goes through URLCommands as a link would.
    @MainActor
    private static func realHubChecks(hub: String, cookie: String, controller: DictationController) async -> Int {
        var failed = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): real hub: \(label)")
            if !condition { failed += 1 }
        }
        let account = HubAccount.shared
        account.send = { try await URLSession.shared.data(for: $0) }
        var opened: URL?
        account.openPage = { opened = $0 }
        account.signIn(to: hub)
        guard let page = opened else {
            check(false, "Sign In opens the hub's sign-in: \(account.problem ?? "")")
            return failed
        }
        // The browser, signed in at the hub already: /auth/app sends it straight back to the app.
        var request = URLRequest(url: page)
        request.setValue("binders_session=\(cookie)", forHTTPHeaderField: "Cookie")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let location = try? await session.data(for: request).1 as? HTTPURLResponse
        guard let back = (location?.value(forHTTPHeaderField: "Location")).flatMap(URL.init(string:)), back.scheme == "binders" else {
            check(false, "/auth/app hands back a binders:// link (\(location?.statusCode ?? 0))")
            return failed
        }
        check(back.host == "auth", "/auth/app hands back binders://auth")
        URLCommands.handle(back, controller: controller)
        for _ in 0..<50 where account.person == nil { try? await Task.sleep(for: .milliseconds(100)) }
        let token = Keychain.read(HubAccount.tokenKey) ?? ""
        check(token.hasPrefix("bnp_") && account.isSignedIn, "a bnp_ token is in the Keychain")
        check(account.person != nil, "the hub says who: \(account.person?.line ?? account.problem ?? "no one")")
        await account.signOut()
        check(Keychain.read(HubAccount.tokenKey) == nil && account.problem == nil, "Sign Out revokes it on the hub and removes it: \(account.problem ?? "")")
        var me = URLRequest(url: URL(string: hub)!.appendingPathComponent("api/me"))
        me.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let refused = (try? await URLSession.shared.data(for: me).1 as? HTTPURLResponse)?.statusCode
        check(refused == 401, "the hub refuses the token after Sign Out: \(refused ?? 0)")
        return failed
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
