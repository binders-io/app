import Foundation

// Signing in to a hub (the Binders server) from the Mac. The hub signs people in with GitHub and a cookie, which an app
// can't easily keep, so the Mac opens the hub's /auth/app in the browser with a state of its own; once the person is
// signed in there, the hub hands back a person token (bnp_…) through a binders://auth link with that state. The Mac
// keeps the token in its Keychain and sends it as a Bearer token on /api/* and /api/live. Here: what can be checked
// without a browser or the Keychain.

/// The words and links of signing in to a hub.
public enum HubSignIn {
    /// Where the hub hands the token back to.
    public static let callback = "binders://auth"

    /// The hub's address as typed: "hub.example.com" is https://hub.example.com; http only for this Mac or a ".local"
    /// name; no path, query or trailing slash. Nil when it isn't one.
    public static func address(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty else { return nil }
        guard scheme == "https" || (scheme == "http" && isThisMacOrNearby(host)) else { return nil }
        parts.scheme = scheme
        parts.host = host.lowercased()
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    /// Why what was typed isn't a hub's address, for Settings to say.
    public static func addressProblem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter your hub's address, such as hub.example.com." }
        if address(trimmed) != nil { return nil }
        if trimmed.lowercased().hasPrefix("http://") { return "A hub is reached with https://, unless it runs on this Mac." }
        return "That isn't a hub's address. It looks like hub.example.com."
    }

    private static func isThisMacOrNearby(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".local")
    }

    /// A state for one sign-in: 32 random bytes, base64url, which the hub accepts (8 to 128 of A–Z, a–z, 0–9, _ and -).
    public static func newState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The page the browser opens: the hub's /auth/app with this sign-in's state and the app's name, which the hub
    /// shows among the person's signed-in apps.
    public static func signInURL(hub: URL, state: String, app: String) -> URL? {
        guard var parts = URLComponents(url: hub.appendingPathComponent("auth/app"), resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "app", value: app),
            URLQueryItem(name: "redirect", value: callback),
        ]
        return parts.url
    }

    /// What a binders://auth link says.
    public struct Callback: Equatable, Sendable {
        public let token: String
        public let state: String
        /// The hub's own public address, as it says it.
        public let hub: URL?
    }

    /// The hand-back in a binders://auth link, if it is one and carries a person token and a state.
    public static func callback(in url: URL) -> Callback? {
        guard url.scheme?.lowercased() == "binders", url.host?.lowercased() == "auth",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let token = value("token"), token.hasPrefix("bnp_"), let state = value("state") else { return nil }
        return Callback(token: token, state: state, hub: value("hub").flatMap(URL.init(string:)))
    }

    /// What comes of a binders://auth link, against the sign-in this Mac started (its state), if it started one.
    public enum Outcome: Equatable, Sendable {
        case signedIn(token: String)
        /// Not a sign-in this Mac asked for: a link anything on this Mac could open, or one from an earlier try.
        case notAsked
        /// Not a hand-back at all.
        case unreadable
    }

    public static func outcome(of url: URL, expecting state: String?) -> Outcome {
        guard let callback = callback(in: url) else { return .unreadable }
        guard let state, callback.state == state else { return .notAsked }
        return .signedIn(token: callback.token)
    }

    /// The person the hub says a token is, from GET /api/me.
    public struct Person: Codable, Equatable, Sendable {
        /// Their GitHub login.
        public let login: String
        public let name: String
        public let avatar: String?

        public init(login: String, name: String, avatar: String? = nil) {
            self.login = login
            self.name = name
            self.avatar = avatar
        }

        /// "Ana Lima (@ana)", or "@ana" when the name is the login.
        public var line: String {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || name.caseInsensitiveCompare(login) == .orderedSame ? "@\(login)" : "\(name) (@\(login))"
        }
    }

    public static func person(fromMe data: Data) -> Person? {
        struct Me: Decodable { let user: Person }
        return try? JSONDecoder().decode(Me.self, from: data).user
    }

    /// The id of the token a request came with, from GET /api/tokens (the one marked current), to revoke on Sign Out.
    public static func currentTokenID(fromTokens data: Data) -> String? {
        struct Tokens: Decodable {
            struct Token: Decodable { let id: String; let current: Bool? }
            let tokens: [Token]
        }
        return (try? JSONDecoder().decode(Tokens.self, from: data))?.tokens.first { $0.current == true }?.id
    }
}
