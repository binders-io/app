import CryptoKit
import Darwin
import Foundation
import Network
import SwiftData
import BindersKit

/// A phone (or other client) paired with this Mac. Its key is the only way in; revoking the device deletes it.
struct LinkDevice: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var key: Data
    var pairedAt: Date
    var lastSeen: Date?
}

/// Binders as a server for paired phones, over the home network or Tailscale. See `Link` for the protocol.
///
/// Two listeners: the main one accepts only paired devices' keys, and a pairing one opens only while a pairing code is on
/// screen, accepts only that code, and allows nothing but pairing. Once a device has proved which one it is, it gets the
/// same tools as `Binders --mcp`, with writes done here in the app, and `binders/changed` whenever the data changes.
@MainActor
@Observable
final class LinkServer {
    enum Status: Equatable {
        case off
        case listening
        case failed(String)
    }

    struct Address: Equatable, Identifiable {
        var id: String { host }
        let host: String
        let isTailscale: Bool
    }

    private(set) var status: Status = .off
    private(set) var devices: [LinkDevice] = []
    private(set) var pairing: LinkPairing?
    private(set) var connectedDevices: Set<UUID> = []
    private(set) var addresses: [Address] = []

    /// The port the main listener actually got (the requested one, unless that was 0).
    private(set) var boundPort: UInt16?
    private(set) var boundPairingPort: UInt16?

    @ObservationIgnored private weak var controller: DictationController?
    @ObservationIgnored private let requestedPort: UInt16
    @ObservationIgnored private let requestedPairingPort: UInt16
    @ObservationIgnored private let devicesURL: URL
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var pairingListener: NWListener?
    @ObservationIgnored private var pairingExpiry: Task<Void, Never>?
    @ObservationIgnored private var sessions: [ObjectIdentifier: LinkSession] = [:]
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingKinds: Set<String> = []
    @ObservationIgnored private var flushScheduled = false

    static let pairingLifetime: TimeInterval = 10 * 60
    /// Where binders://link/pair leaves the pairing link, for pairing a phone that isn't at the Mac. Gone once pairing closes.
    static var pairingLinkFile: URL { AppPaths.support.appendingPathComponent("link-pairing.txt") }

    init(controller: DictationController, port: UInt16 = Link.port, pairingPort: UInt16 = Link.pairingPort,
         devicesURL: URL = AppPaths.support.appendingPathComponent("link-devices.json")) {
        self.controller = controller
        requestedPort = port
        requestedPairingPort = pairingPort
        self.devicesURL = devicesURL
        devices = Self.loadDevices(from: devicesURL)
    }

    var isRunning: Bool { listener != nil }

    /// Starts listening if it isn't already. The app calls this when the setting is on; the self-test calls it directly.
    func start() {
        guard listener == nil else { return }
        observeChanges()
        restartListener()
    }

    func stop() {
        cancelPairing()
        listener?.cancel()
        listener = nil
        boundPort = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
        connectedDevices.removeAll()
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        status = .off
    }

    // MARK: Pairing

    /// Opens pairing for ten minutes and returns what the QR code shows. The code works once.
    func beginPairing() async -> LinkPairing? {
        cancelPairing()
        let secret = Link.randomBytes(16)
        let keys = [(identity: "pair", key: Link.pairingKey(secret: secret))]
        let pairingListener: NWListener
        do {
            pairingListener = try NWListener(using: Link.parameters(keys: keys), on: NWEndpoint.Port(rawValue: requestedPairingPort) ?? .any)
        } catch {
            status = .failed("Couldn't open pairing: \(error.localizedDescription)")
            return nil
        }
        pairingListener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection, pairing: true) }
        }
        self.pairingListener = pairingListener
        // The QR code needs the port, which is known once the listener is ready.
        let ready: Bool = await withCheckedContinuation { continuation in
            var resumed = false
            pairingListener.stateUpdateHandler = { state in
                switch state {
                case .ready where !resumed: resumed = true; continuation.resume(returning: true)
                case .failed where !resumed, .cancelled where !resumed: resumed = true; continuation.resume(returning: false)
                default: break
                }
            }
            pairingListener.start(queue: .main)
        }
        guard ready, pairingListener === self.pairingListener, let port = pairingListener.port?.rawValue else {
            if self.pairingListener === pairingListener { cancelPairing() }
            return nil
        }
        boundPairingPort = port
        addresses = Self.currentAddresses()
        var hosts = addresses.map(\.host)
        if hosts.isEmpty { hosts = ["127.0.0.1"] }
        let pairing = LinkPairing(name: Host.current().localizedName ?? "Mac", addresses: hosts.map { "\($0):\(port)" }, secret: secret,
                                  expires: Date().addingTimeInterval(Self.pairingLifetime))
        self.pairing = pairing
        pairingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingLifetime))
            guard !Task.isCancelled else { return }
            self?.cancelPairing()
        }
        return pairing
    }

    func cancelPairing() {
        try? FileManager.default.removeItem(at: Self.pairingLinkFile)
        pairingExpiry?.cancel()
        pairingExpiry = nil
        pairingListener?.cancel()
        pairingListener = nil
        boundPairingPort = nil
        pairing = nil
        for (id, session) in sessions where session.isPairing {
            session.close()
            sessions.removeValue(forKey: id)
        }
    }

    /// Called by a pairing session: creates the device and its key, then closes pairing.
    fileprivate func completePairing(name: String) -> LinkDevice {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = LinkDevice(id: UUID(), name: cleaned.isEmpty ? "iPhone" : String(cleaned.prefix(60)),
                                key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, pairedAt: Date())
        devices.append(device)
        saveDevices()
        restartListener()
        // Let the reply go out before the pairing listener and its session are closed.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.cancelPairing()
        }
        return device
    }

    // MARK: Devices

    func revoke(_ id: UUID) {
        devices.removeAll { $0.id == id }
        saveDevices()
        for (key, session) in sessions where session.device == id {
            session.close()
            sessions.removeValue(forKey: key)
        }
        connectedDevices.remove(id)
        restartListener()
    }

    fileprivate func device(_ id: UUID) -> LinkDevice? { devices.first { $0.id == id } }

    fileprivate func deviceSaidHello(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].lastSeen = Date()
        saveDevices()
        refreshConnected()
    }

    private func refreshConnected() {
        connectedDevices = Set(sessions.values.compactMap(\.device))
    }

    // MARK: Listening

    private func restartListener() {
        listener?.cancel()
        listener = nil
        // With no device paired yet, a throwaway key keeps the listener valid; nothing can match it.
        var keys = devices.map { (identity: $0.id.uuidString, key: SymmetricKey(data: $0.key)) }
        if keys.isEmpty { keys = [(identity: "none", key: SymmetricKey(size: .bits256))] }
        do {
            // A restart (a device paired or removed) keeps the port the phones already know.
            let parameters = Link.parameters(keys: keys)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: boundPort ?? requestedPort) ?? .any)
            listener.service = NWListener.Service(name: Host.current().localizedName, type: Link.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection, pairing: false) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, listener === self.listener else { return }
                    switch state {
                    case .ready:
                        self.boundPort = listener.port?.rawValue
                        self.addresses = Self.currentAddresses()
                        self.status = .listening
                    case .failed(let error):
                        self.status = .failed(Self.describe(error, port: self.requestedPort))
                        self.listener = nil
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch let error as NWError {
            status = .failed(Self.describe(error, port: requestedPort))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func accept(_ connection: NWConnection, pairing: Bool) {
        let session = LinkSession(connection: connection, isPairing: pairing, server: self)
        let key = ObjectIdentifier(session)
        sessions[key] = session
        session.onClose = { [weak self] in
            self?.sessions.removeValue(forKey: key)
            self?.refreshConnected()
        }
        session.start()
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use by another app."
        }
        return error.localizedDescription
    }

    // MARK: Changes

    /// Every save of the app's database becomes a `binders/changed` notification, grouped over a quarter second.
    private func observeChanges() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] notification in
            let kinds = Self.kinds(in: notification.userInfo)
            MainActor.assumeIsolated { self?.changed(kinds) }
        }
    }

    func changed(_ kinds: Set<String>) {
        guard !kinds.isEmpty else { return }
        pendingKinds.formUnion(kinds)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        let kinds = pendingKinds.sorted()
        pendingKinds.removeAll()
        guard !kinds.isEmpty else { return }
        for session in sessions.values where session.isSubscribed {
            session.send(["jsonrpc": "2.0", "method": "binders/changed", "params": ["kinds": kinds]])
        }
    }

    /// What kind of thing changed, in the words the phone uses. Checklists live in notes and meetings, so those also
    /// change the board.
    nonisolated static func kinds(in userInfo: [AnyHashable: Any]?) -> Set<String> {
        var entities = Set<String>()
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            for identifier in userInfo?[key.rawValue] as? [PersistentIdentifier] ?? [] {
                entities.insert(identifier.entityName)
            }
        }
        guard !entities.isEmpty else { return userInfo == nil ? [] : ["all"] }
        var kinds = Set<String>()
        for entity in entities {
            switch entity {
            case "NoteItem": kinds.formUnion(["notes", "todos"])
            case "MeetingRecord": kinds.formUnion(["meetings", "todos"])
            case "CommitmentRecord": kinds.insert("todos")
            case "BinderRecord": kinds.insert("binders")
            case "TranscriptRecord": kinds.insert("dictations")
            case "TaskCard", "TaskEvent": kinds.insert("tasks")
            default: kinds.insert("other")
            }
        }
        return kinds
    }

    // MARK: Tools

    /// A phone's dictation, formatted as the Mac formats its own.
    fileprivate func formatDictation(_ text: String) async -> PipelineResult {
        await TextFormatter.format(raw: text, context: AppContext(appName: "Binders on iPhone"))
    }

    fileprivate func runTool(_ message: [String: Any]) async -> [String: Any]? {
        guard let controller else { return MCPCore.failure(id: message["id"], code: -32603, message: "Binders is shutting down") }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return await MCPCore.handle(message, serverName: "binders", serverVersion: version, instructions: MCPServer.instructions,
                                    tools: MCPServer.tools, call: { name, arguments in
            // On the phone, it's you.
            try await MCPServer.call(name, arguments, knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller), actor: .you)
        })
    }

    // MARK: Addresses and storage

    /// This Mac's IPv4 addresses a phone can use: the local network first, then Tailscale (100.64.0.0/10).
    nonisolated static func currentAddresses() -> [Address] {
        var result: [Address] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            let parts = text.split(separator: ".").compactMap { Int($0) }
            let isTailscale = parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
            let name = String(cString: entry.ifa_name)
            guard isTailscale || name.hasPrefix("en") else { continue }
            if !result.contains(where: { $0.host == text }) { result.append(Address(host: text, isTailscale: isTailscale)) }
        }
        // Other VPNs (Cloudflare WARP, for one) use the same 100.64.0.0/10 range. When Tailscale can say which address is
        // its own, keep only that one; a phone can't reach the others.
        if let own = tailscaleAddress() {
            result.removeAll { $0.isTailscale && $0.host != own }
        }
        return result.sorted { !$0.isTailscale && $1.isTailscale }
    }

    /// This Mac's Tailscale IPv4 address, from Tailscale's own command-line tool, or nil if it isn't installed or running.
    nonisolated static func tailscaleAddress() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["ip", "-4"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        if finished.wait(timeout: .now() + 1.5) == .timedOut {
            process.terminate()
            return nil
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 ? text : nil
    }

    private static func loadDevices(from url: URL) -> [LinkDevice] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LinkDevice].self, from: data)) ?? []
    }

    private func saveDevices() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: devicesURL, options: [.atomic])
        // The keys are the only way in: readable by this user only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesURL.path)
    }
}

/// One connected client: framing, the hello handshake, and dispatch.
@MainActor
private final class LinkSession {
    let connection: NWConnection
    let isPairing: Bool
    private(set) var device: UUID?
    private(set) var isSubscribed = false
    var onClose: (() -> Void)?
    private weak var server: LinkServer?
    private var buffer = LineBuffer()
    private var challenge: Data?
    private var closed = false

    init(connection: NWConnection, isPairing: Bool, server: LinkServer) {
        self.connection = connection
        self.isPairing = isPairing
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    func send(_ message: [String: Any]) {
        guard !closed, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data {
                    for line in self.buffer.append(data) {
                        Task { await self.handle(line) }
                    }
                }
                if isComplete || error != nil || self.buffer.overflowed {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func handle(_ line: Data) async {
        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            send(MCPCore.parseError())
            return
        }
        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]
        guard let server else { return close() }

        if isPairing {
            guard method == "binders/pair" else {
                return reply(MCPCore.failure(id: id, code: -32001, message: "This connection can only pair"))
            }
            let device = server.completePairing(name: params["name"] as? String ?? "")
            return reply(MCPCore.success(id: id, result: ["device": device.id.uuidString, "key": device.key.base64EncodedString(),
                                                          "name": Host.current().localizedName ?? "Mac",
                                                          "port": Int(server.boundPort ?? Link.port), "protocol": Link.protocolVersion]))
        }

        switch method {
        case "binders/challenge":
            let nonce = Link.randomBytes(32)
            challenge = nonce
            reply(MCPCore.success(id: id, result: ["challenge": nonce.base64EncodedString()]))
        case "binders/hello":
            guard let nonce = challenge,
                  let deviceID = (params["device"] as? String).flatMap(UUID.init(uuidString:)),
                  let known = server.device(deviceID),
                  let proof = (params["proof"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  Link.verify(proof: proof, challenge: nonce, key: SymmetricKey(data: known.key)) else {
                reply(MCPCore.failure(id: id, code: -32001, message: "This device isn't paired with this Mac"))
                return close()
            }
            challenge = nil
            device = deviceID
            server.deviceSaidHello(deviceID)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            reply(MCPCore.success(id: id, result: ["name": Host.current().localizedName ?? "Mac", "version": version,
                                                   "protocol": Link.protocolVersion]))
        default:
            guard device != nil else {
                return reply(MCPCore.failure(id: id, code: -32001, message: "Say hello first"))
            }
            if method == "binders/subscribe" {
                isSubscribed = true
                return reply(MCPCore.success(id: id, result: [String: Any]()))
            }
            if method == "binders/format" {
                // What the phone heard, cleaned up here the way dictation on this Mac is: its model, dictionary and snippets.
                let result = await server.formatDictation(params["text"] as? String ?? "")
                return reply(MCPCore.success(id: id, result: ["text": result.text, "used_model": result.usedLLM,
                                                              "model": result.usedLLM ? AppSettings.shared.llmModelName : ""]))
            }
            reply(await server.runTool(message))
        }
    }

    private func reply(_ message: [String: Any]?) {
        if let message { send(message) }
    }
}
