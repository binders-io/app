import BindersKit
import Foundation
import Security
import UIKit

/// The hub this iPhone uses as its brain, when it does: where it is, what it calls itself, and who signed in. Signed in
/// as the Mac signs in (HubSignIn): the hub hands a person token back on a binders://auth link, kept in this iPhone's
/// Keychain and sent on every request and on the link.
struct HubPlace: Codable, Equatable {
    var address: URL
    /// The hub's name, as it says at hello.
    var name: String?
    var person: HubSignIn.Person?

    /// How the hub is named in words: its name, else its host.
    var title: String { name.flatMap { $0.isEmpty ? nil : $0 } ?? address.host() ?? "your hub" }
}

enum HubBrain {
    static let stoppedWords = "Your hub signed this iPhone out. Sign in again."
    private static let placeKey = "hubPlace"
    private static let deviceKey = "hubDevice"
    /// The address last typed, kept for signing in again.
    static let typedKey = "hubAddressTyped"

    static func load() -> HubPlace? {
        guard let data = UserDefaults.standard.data(forKey: placeKey) else { return nil }
        return try? JSONDecoder().decode(HubPlace.self, from: data)
    }

    static func save(_ place: HubPlace?) {
        if let place, let data = try? JSONEncoder().encode(place) {
            UserDefaults.standard.set(data, forKey: placeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: placeKey)
        }
    }

    /// This iPhone, as the hub knows it from one hello to the next.
    static var device: UUID {
        if let kept = UserDefaults.standard.string(forKey: deviceKey).flatMap(UUID.init(uuidString:)) { return kept }
        let made = UUID()
        UserDefaults.standard.set(made.uuidString, forKey: deviceKey)
        return made
    }

    /// The hub's link: /api/app/link, over wss (ws for a hub on http, such as one on this network for development).
    static func linkURL(for address: URL) -> URL? {
        guard var parts = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.path = "/api/app/link"
        parts.query = nil
        return parts.url
    }

    /// One request to the hub's API with the iPhone's token, outside the link: who signed in, and stopping the token.
    static func call(_ method: String, _ path: String, address: URL, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: address.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func person(address: URL, token: String) async -> HubSignIn.Person? {
        guard let (data, status) = try? await call("GET", "api/me", address: address, token: token), status == 200 else { return nil }
        return HubSignIn.person(fromMe: data)
    }

    /// Stops the token on the hub, as Sign Out does; nothing said when the hub can't be reached.
    static func revoke(address: URL, token: String) async {
        guard let (data, status) = try? await call("GET", "api/tokens", address: address, token: token), status == 200,
              let id = HubSignIn.currentTokenID(fromTokens: data) else { return }
        _ = try? await call("DELETE", "api/tokens/\(id)", address: address, token: token)
    }
}

/// The hub's person token, kept in this iPhone's Keychain only.
enum HubKeychain {
    private static let service = "io.binders.hub"
    private static let account = "hub-token"

    static func save(_ token: String) {
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                   kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
