import AppKit
import Foundation
import BindersKit

/// This Mac signed in to a hub (the Binders server), from Settings → Team. Sign In opens the hub's sign-in in the browser
/// (HubSignIn); the hub hands a person token (bnp_…) back through binders://auth, which URLCommands brings here. The token
/// is kept in the Keychain, the hub's address and who it says the token is in the defaults, so Settings shows who's
/// signed in without asking the hub. Sign Out revokes the token on the hub, when it's reachable, and deletes it here.
/// What links binders to the hub and syncs them builds on `authorized(_:)`.
@MainActor
@Observable
final class HubAccount {
    static let shared = HubAccount()

    static let tokenKey = "hub-token"
    static let addressKey = "hubAddress"
    static let personKey = "hubPerson"

    /// The hub this Mac is signed in to, or was last asked for.
    private(set) var address: URL?
    /// Who the hub says this Mac is signed in as.
    private(set) var person: HubSignIn.Person?
    /// A sign-in waiting for the browser: its state, which the binders://auth link has to carry, and the hub it went to.
    private(set) var pending: (state: String, hub: URL)?
    private(set) var working = false
    /// What went wrong, in words.
    private(set) var problem: String?
    /// Whether the Keychain holds a token for the hub, read once and kept as it changes.
    private(set) var hasToken = false

    /// Opens a page in the browser (the self-tests keep it instead).
    @ObservationIgnored var openPage: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Sends a request to the hub (the self-tests answer it themselves).
    @ObservationIgnored var send: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    init() {
        address = AppDefaults.store.string(forKey: Self.addressKey).flatMap(URL.init(string:))
        person = AppDefaults.store.data(forKey: Self.personKey).flatMap { try? JSONDecoder().decode(HubSignIn.Person.self, from: $0) }
        hasToken = token != nil
    }

    var token: String? { Keychain.read(Self.tokenKey).flatMap { $0.isEmpty ? nil : $0 } }
    var isSignedIn: Bool { address != nil && hasToken }

    /// The app's name as the hub lists it among the person's apps.
    static var appName: String { "Binders for Mac on \(Host.current().localizedName ?? "this Mac")" }

    // MARK: Signing in

    /// Sign In: the browser opens the hub's sign-in, and the hub comes back to binders://auth.
    func signIn(to typed: String) {
        guard let hub = HubSignIn.address(typed) else {
            problem = HubSignIn.addressProblem(typed)
            return
        }
        let state = HubSignIn.newState()
        guard let page = HubSignIn.signInURL(hub: hub, state: state, app: Self.appName) else { return }
        pending = (state, hub)
        problem = nil
        openPage(page)
    }

    func cancelSignIn() {
        pending = nil
    }

    /// A binders://auth link: the token, if it's the hand-back of the sign-in this Mac started; then who it is.
    func finish(_ url: URL) async {
        switch HubSignIn.outcome(of: url, expecting: pending?.state) {
        case .unreadable:
            problem = "That sign-in link has no token in it. Sign in again."
        case .notAsked:
            // Anything on this Mac can open a link: a token this Mac didn't ask for is never kept.
            problem = pending == nil ? "A hub sign-in arrived that this Mac didn't start, so it wasn't kept."
                                     : "That sign-in was for an earlier try. Finish the one in your browser, or sign in again."
        case .signedIn(let token):
            guard let hub = pending?.hub else { return }
            pending = nil
            Keychain.write(token, for: Self.tokenKey)
            hasToken = true
            setAddress(hub)
            problem = nil
            await refresh()
        }
    }

    /// Asks the hub who the token is, and keeps it. A token the hub no longer knows is signed out here.
    func refresh() async {
        guard let request = authorized("api/me") else { return }
        working = true
        defer { working = false }
        do {
            let (data, response) = try await send(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                forget()
                problem = "The hub signed this Mac out. Sign in again."
                return
            }
            guard status == 200, let found = HubSignIn.person(fromMe: data) else {
                problem = "The hub didn't say who you are (\(status)). Try again in a moment."
                return
            }
            setPerson(found)
            problem = nil
        } catch {
            problem = "Couldn't reach \(address?.host ?? "the hub"): \(error.localizedDescription)"
        }
    }

    // MARK: Signing out

    /// Sign Out: the hub stops the token, when it can be reached, and this Mac forgets it either way.
    func signOut() async {
        working = true
        defer { working = false }
        var revoked = false
        if let list = authorized("api/tokens"), let listed = try? await send(list), (listed.1 as? HTTPURLResponse)?.statusCode == 200,
           let id = HubSignIn.currentTokenID(fromTokens: listed.0), var delete = authorized("api/tokens/\(id)") {
            delete.httpMethod = "DELETE"
            if let deleted = try? await send(delete), (deleted.1 as? HTTPURLResponse)?.statusCode == 200 { revoked = true }
        }
        forget()
        problem = revoked ? nil : "Signed out on this Mac. The hub couldn't be reached to stop its token: remove “\(Self.appName)” in the web app's Settings → You."
    }

    /// The token and who it was, gone from this Mac. The hub's address stays, for signing in again.
    private func forget() {
        Keychain.write("", for: Self.tokenKey)
        hasToken = false
        setPerson(nil)
        pending = nil
    }

    // MARK: Asking the hub

    /// A request to the hub with this Mac's token, as /api/* and /api/live take it. Nil while signed out.
    func authorized(_ path: String) -> URLRequest? {
        guard let address, let token else { return nil }
        var request = URLRequest(url: address.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    private func setAddress(_ hub: URL) {
        address = hub
        AppDefaults.store.set(hub.absoluteString, forKey: Self.addressKey)
    }

    private func setPerson(_ found: HubSignIn.Person?) {
        person = found
        if let found, let data = try? JSONEncoder().encode(found) {
            AppDefaults.store.set(data, forKey: Self.personKey)
        } else {
            AppDefaults.store.removeObject(forKey: Self.personKey)
        }
    }
}
