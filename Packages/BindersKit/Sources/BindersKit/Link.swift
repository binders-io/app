import CryptoKit
import Foundation
import Network

/// The phone link: how an iPhone (or any paired client) reaches Binders on a Mac, over the home network or Tailscale.
///
/// The Mac is the server and the only writer. A client pairs once by scanning a QR code, which carries a one-time secret;
/// over a connection keyed by that secret it receives a device key of its own. From then on it connects with TLS 1.2
/// using that pre-shared key (no certificates to manage) and speaks newline-delimited JSON-RPC 2.0, the same framing as
/// `Binders --mcp`, with the same tools plus live change notifications.
public enum Link {
    /// Bonjour service type the Mac advertises on the local network.
    public static let serviceType = "_binders._tcp"
    public static let port: UInt16 = 7447
    /// Open only while a pairing code is on screen.
    public static let pairingPort: UInt16 = 7448
    public static let protocolVersion = 1
    /// Longest single message accepted, in bytes.
    public static let maximumMessageSize = 8 * 1024 * 1024

    /// Network parameters for either end: TLS 1.2 with the given pre-shared keys. A server passes every key it accepts; a
    /// client passes its own. Keys are matched by identity. (No identity hint: setting one breaks the handshake.)
    public static func parameters(keys: [(identity: String, key: SymmetricKey)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for entry in keys {
            let key = entry.key.withUnsafeBytes { Data($0) }
            sec_protocol_options_add_pre_shared_key(options, dispatchData(key) as __DispatchData, dispatchData(Data(entry.identity.utf8)) as __DispatchData)
        }
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        return NWParameters(tls: tls, tcp: tcp)
    }

    /// The key both ends derive from the one-time secret in the QR code.
    public static func pairingKey(secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("binders-link-pairing".utf8),
                               info: Data("v\(protocolVersion)".utf8), outputByteCount: 32)
    }

    /// Proof that a client holds a device's key: an HMAC of the server's challenge.
    public static func proof(challenge: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: challenge, using: key))
    }

    public static func verify(proof: Data, challenge: Data, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: challenge, using: key)
    }

    public static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func dispatchData(_ data: Data) -> DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) }
    }
}

/// What the QR code carries: where the Mac is, and the one-time secret for pairing. Encoded as a binders://pair link, so
/// the iPhone camera opens the app with it.
public struct LinkPairing: Codable, Equatable, Sendable {
    public var version: Int
    /// The Mac's name, shown on the phone.
    public var name: String
    /// "host:port" pairs to try, local network first, then Tailscale.
    public var addresses: [String]
    public var secret: Data
    public var expires: Date

    public init(name: String, addresses: [String], secret: Data, expires: Date, version: Int = Link.protocolVersion) {
        self.version = version
        self.name = name
        self.addresses = addresses
        self.secret = secret
        // Whole seconds, as the QR code carries it.
        self.expires = Date(timeIntervalSince1970: expires.timeIntervalSince1970.rounded(.down))
    }

    public var url: URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(self)) ?? Data()
        var components = URLComponents()
        components.scheme = "binders"
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "d", value: data.base64URLEncoded)]
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == "binders", url.host == "pair",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = Data(base64URLEncoded: value) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let decoded = try? decoder.decode(LinkPairing.self, from: data) else { return nil }
        self = decoded
    }

    public func isExpired(at date: Date = Date()) -> Bool { date >= expires }
}

/// Splits a byte stream into newline-delimited messages.
public struct LineBuffer: Sendable {
    private var pending = Data()
    public private(set) var overflowed = false

    public init() {}

    /// Adds received bytes and returns the complete lines, without their newlines. Empty lines are skipped.
    public mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if pending.count > Link.maximumMessageSize {
            pending.removeAll()
            overflowed = true
        }
        return lines
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
