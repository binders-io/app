import CryptoKit
import Foundation
import Network

/// A connection to Binders on a Mac: JSON-RPC requests with their replies, and the Mac's notifications as they arrive.
/// The iPhone app talks to the Mac through this, and the Mac's own self-test uses it to play the phone.
public final class LinkClient: @unchecked Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case unreachable(String)
        case closed
        case rejected(String)
        case timedOut

        public var errorDescription: String? {
            switch self {
            case .unreachable(let reason): "Couldn't reach the Mac: \(reason)"
            case .closed: "The connection to the Mac closed"
            case .rejected(let message): message
            case .timedOut: "The Mac didn't answer in time"
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.binders.link.client")
    private var buffer = LineBuffer()
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<Any, Error>] = [:]
    private var ready: CheckedContinuation<Void, Error>?
    private var notificationHandler: (@Sendable ([String: Any]) -> Void)?
    private var closeHandler: (@Sendable () -> Void)?
    private var closed = false

    public init(host: String, port: UInt16, identity: String, key: SymmetricKey) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                  using: Link.parameters(keys: [(identity, key)]))
    }

    /// Connects to an endpoint found by Bonjour.
    public init(endpoint: NWEndpoint, identity: String, key: SymmetricKey) {
        connection = NWConnection(to: endpoint, using: Link.parameters(keys: [(identity, key)]))
    }

    /// Opens the connection; fails if the Mac can't be reached or refuses the key.
    public func connect(timeout: TimeInterval = 8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                ready = continuation
                connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let pending = ready else { return }
                    ready = nil
                    pending.resume(throwing: Failure.timedOut)
                    connection.cancel()
                }
            }
        }
        receive()
    }

    /// Called once when the connection ends, for whatever reason, on a background queue.
    public func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async {
            if self.closed { handler() } else { self.closeHandler = handler }
        }
    }

    /// Called for each notification the Mac sends, on a background queue.
    public func onNotification(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        queue.async { self.notificationHandler = handler }
    }

    /// Sends a request and returns its result, or throws the Mac's error.
    public func request(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 60) async throws -> Any {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            queue.async { [self] in
                guard !closed else { return continuation.resume(throwing: Failure.closed) }
                let id = nextID
                nextID += 1
                waiting[id] = continuation
                send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.waiting.removeValue(forKey: id)?.resume(throwing: Failure.timedOut)
                }
            }
        }
    }

    public func close() {
        queue.async { [self] in
            connection.cancel()
            finish()
        }
    }

    // MARK: The Binders conversation

    /// Proves which paired device this is: the Mac sends a challenge, the client signs it with its device key.
    @discardableResult
    public func hello(device: UUID, key: SymmetricKey, name: String) async throws -> [String: Any] {
        let challenge = try await request("binders/challenge") as? [String: Any]
        guard let nonce = (challenge?["challenge"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw Failure.rejected("The Mac sent no challenge")
        }
        let proof = Link.proof(challenge: nonce, key: key).base64EncodedString()
        let reply = try await request("binders/hello", ["device": device.uuidString, "proof": proof, "name": name,
                                                        "protocol": Link.protocolVersion])
        return reply as? [String: Any] ?? [:]
    }

    /// Calls one of the tools the MCP server offers and returns its text, or throws the tool's error.
    public func callTool(_ name: String, _ arguments: [String: Any] = [:]) async throws -> String {
        let reply = try await request("tools/call", ["name": name, "arguments": arguments]) as? [String: Any] ?? [:]
        let text = ((reply["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        if reply["isError"] as? Bool == true { throw Failure.rejected(text) }
        return text
    }

    /// Pairs with the Mac in a QR code: tries each of its addresses, then asks for a device key.
    public static func pair(_ pairing: LinkPairing, deviceName: String) async throws -> (device: UUID, key: SymmetricKey, host: String, port: UInt16) {
        guard !pairing.isExpired() else { throw Failure.rejected("This pairing code has expired. Show a new one on the Mac.") }
        var lastError: Error = Failure.unreachable("no address")
        for address in pairing.addresses {
            guard let (host, port) = split(address) else { continue }
            let client = LinkClient(host: host, port: port, identity: "pair", key: Link.pairingKey(secret: pairing.secret))
            do {
                try await client.connect(timeout: 4)
                defer { client.close() }
                let reply = try await client.request("binders/pair", ["name": deviceName, "protocol": Link.protocolVersion]) as? [String: Any]
                guard let id = (reply?["device"] as? String).flatMap(UUID.init(uuidString:)),
                      let key = (reply?["key"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                    throw Failure.rejected("The Mac's answer was incomplete")
                }
                // The main port, where every later connection goes.
                let mainPort = (reply?["port"] as? Int).flatMap(UInt16.init(exactly:)) ?? Link.port
                return (id, SymmetricKey(data: key), host, mainPort)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// "host:port" → parts. IPv6 hosts come in brackets: "[fd7a::1]:7447".
    public static func split(_ address: String) -> (host: String, port: UInt16)? {
        guard let colon = address.lastIndex(of: ":"), let port = UInt16(address[address.index(after: colon)...]) else { return nil }
        var host = String(address[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    // MARK: Plumbing (on `queue`)

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready?.resume()
            ready = nil
        case .failed(let error), .waiting(let error):
            if let pending = ready {
                ready = nil
                pending.resume(throwing: Failure.unreachable(error.localizedDescription))
            }
            connection.cancel()
            finish()
        case .cancelled:
            finish()
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                for line in buffer.append(data) { handle(line) }
            }
            if isComplete || error != nil || buffer.overflowed {
                connection.cancel()
                finish()
            } else {
                receive()
            }
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let id = message["id"] as? Int, let continuation = waiting.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: Failure.rejected(error["message"] as? String ?? "The Mac refused the request"))
            } else {
                continuation.resume(returning: message["result"] ?? [String: Any]())
            }
        } else if message["method"] != nil, message["id"] == nil {
            notificationHandler?(message)
        }
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        for continuation in waiting.values { continuation.resume(throwing: Failure.closed) }
        waiting.removeAll()
        closeHandler?()
        closeHandler = nil
    }
}
