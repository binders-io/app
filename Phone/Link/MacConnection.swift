import BindersKit
import CryptoKit
import Foundation
import Network
import Observation
import Security
import UIKit

/// What the phone remembers about its Mac: who it is and where it was found. The device key lives in the Keychain.
struct PairedMac: Codable, Equatable {
    var device: UUID
    var name: String
    var hosts: [String]
    var port: UInt16
    var lastHost: String?
}

/// The phone's side of the link: pairing, staying connected (Bonjour at home, then the addresses from pairing, which
/// include Tailscale), calling the Mac's tools, and turning the Mac's change notifications into refreshes.
@MainActor
@Observable
final class MacConnection {
    enum State: Equatable {
        case unpaired
        case connecting
        case connected
        case offline(String)
    }

    private(set) var state: State = .unpaired
    private(set) var mac: PairedMac?
    private(set) var pairingError: String?
    /// Bumped per kind ("todos", "notes", "meetings"…) when the Mac says something changed; screens reload on it.
    private(set) var revisions: [String: Int] = [:]
    /// Notes and to-dos saved while the Mac was out of reach, sent when it's back.
    private(set) var outbox: [PendingSave] = Outbox.load()

    @ObservationIgnored private var client: LinkClient?
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private let browser = MacBrowser()
    @ObservationIgnored var isActive = true

    init() {
        mac = Self.loadMac()
        state = mac == nil ? .unpaired : .offline("Not connected yet")
    }

    var isConnected: Bool { state == .connected }

    /// A screen's reload key: changes when its kind of data, or everything, changed.
    func revision(_ kind: String) -> Int { revisions[kind, default: 0] + revisions["all", default: 0] }

    // MARK: Pairing

    func pair(with url: URL) async {
        guard let pairing = LinkPairing(url: url) else {
            pairingError = "That isn't a Binders pairing link."
            return
        }
        pairingError = nil
        disconnect()
        state = .connecting
        do {
            let result = try await LinkClient.pair(pairing, deviceName: UIDevice.current.name)
            try Keychain.save(result.key.withUnsafeBytes { Data($0) }, account: result.device.uuidString)
            if let old = mac, old.device != result.device { Keychain.delete(account: old.device.uuidString) }
            let paired = PairedMac(device: result.device, name: pairing.name,
                                   hosts: pairing.addresses.compactMap { LinkClient.split($0)?.host }, port: result.port, lastHost: result.host)
            Self.saveMac(paired)
            mac = paired
            Cache.clear()
            await connect()
        } catch {
            pairingError = error.localizedDescription
            state = mac == nil ? .unpaired : .offline(error.localizedDescription)
        }
    }

    func unpair() {
        disconnect()
        if let mac { Keychain.delete(account: mac.device.uuidString) }
        Self.saveMac(nil)
        mac = nil
        state = .unpaired
        Cache.clear()
    }

    // MARK: Staying connected

    func connect() async {
        guard let mac, client == nil, !connecting else { return }
        guard let keyData = Keychain.load(account: mac.device.uuidString) else {
            state = .offline("This iPhone's key is missing. Pair again.")
            return
        }
        connecting = true
        defer { connecting = false }
        retry?.cancel()
        state = .connecting
        let key = SymmetricKey(data: keyData)
        let identity = mac.device.uuidString

        // Bonjour on the local network first (it follows the Mac to a new address), then the address that worked last,
        // then the rest, Tailscale among them.
        var candidates: [(client: LinkClient, host: String?)] = []
        if let endpoint = browser.endpoint(named: mac.name) {
            candidates.append((LinkClient(endpoint: endpoint, identity: identity, key: key), nil))
        }
        var hosts = mac.hosts
        if let last = mac.lastHost {
            hosts.removeAll { $0 == last }
            hosts.insert(last, at: 0)
        }
        candidates += hosts.map { (LinkClient(host: $0, port: mac.port, identity: identity, key: key), $0) }

        var reason = "Can't reach \(mac.name)"
        for candidate in candidates {
            do {
                try await candidate.client.connect(timeout: 4)
                try await candidate.client.hello(device: mac.device, key: key, name: UIDevice.current.name)
                let link = candidate.client
                link.onNotification { [weak self] message in
                    let kinds = ((message["params"] as? [String: Any])?["kinds"] as? [String]) ?? ["all"]
                    Task { @MainActor in self?.changed(kinds) }
                }
                link.onClose { [weak self] in
                    Task { @MainActor in self?.closed(link) }
                }
                _ = try await link.request("binders/subscribe")
                client = link
                failures = 0
                state = .connected
                if let host = candidate.host, host != mac.lastHost {
                    self.mac?.lastHost = host
                    Self.saveMac(self.mac)
                }
                changed(["all"])
                await sendOutbox()
                return
            } catch LinkClient.Failure.rejected(let message) {
                candidate.client.close()
                reason = message
            } catch {
                candidate.client.close()
            }
        }
        state = .offline(reason)
        scheduleRetry()
    }

    func disconnect() {
        retry?.cancel()
        retry = nil
        client?.close()
        client = nil
    }

    /// Foreground: connect and refresh. Background: let go; iOS would suspend the connection anyway.
    func sceneChanged(active: Bool) {
        isActive = active
        if active {
            Task { await connect() }
        } else {
            disconnect()
            if mac != nil { state = .offline("Paused in the background") }
        }
    }

    private func closed(_ link: LinkClient) {
        guard link === client else { return }
        client = nil
        state = .offline("Lost the connection to \(mac?.name ?? "the Mac")")
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard isActive, mac != nil else { return }
        let delays: [Double] = [1, 2, 5, 10, 30]
        let delay = delays[min(failures, delays.count - 1)]
        failures += 1
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func changed(_ kinds: [String]) {
        for kind in kinds { revisions[kind, default: 0] += 1 }
    }

    // MARK: Dictation

    /// The Mac's cleanup of what was dictated here: its model, dictionary and snippets. Nil when the Mac can't be reached,
    /// or is too old to know how.
    func format(_ text: String) async -> (text: String, model: String)? {
        guard await ready(), let client, let result = try? await client.request("binders/format", ["text": text], timeout: 45) as? [String: Any],
              let cleaned = result["text"] as? String else { return nil }
        return (cleaned, result["model"] as? String ?? "")
    }

    /// Saves a note ("add_note") or a to-do ("add_todo") on the Mac, or keeps it here until the Mac is back. True when it
    /// went straight to the Mac.
    @discardableResult
    func save(_ tool: String, text: String, binder: String?) async -> Bool {
        var arguments: [String: Any] = ["text": text]
        if let binder { arguments["binder"] = binder }
        if await ready(), (try? await call(tool, arguments)) != nil { return true }
        outbox.append(PendingSave(id: UUID(), tool: tool, text: text, binder: binder, created: Date()))
        Outbox.save(outbox)
        return false
    }

    /// Connected, or soon: waits a few seconds for a connection that's on its way, as when the app has just opened.
    private func ready() async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while client == nil, mac != nil, isActive, connecting || state == .connecting || state == .offline("Not connected yet"),
              Date() < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        return client != nil
    }

    private func sendOutbox() async {
        for item in outbox {
            var arguments: [String: Any] = ["text": item.text]
            if let binder = item.binder { arguments["binder"] = binder }
            guard (try? await call(item.tool, arguments)) != nil else { break }
            outbox.removeAll { $0.id == item.id }
            Outbox.save(outbox)
        }
    }

    // MARK: Calling the Mac

    func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> String {
        guard let client else { throw LinkClient.Failure.closed }
        return try await client.callTool(tool, arguments)
    }

    /// Fresh from the Mac when connected, otherwise the copy from last time. `fresh` says which.
    func fetch<T: Decodable>(_ tool: String, _ arguments: [String: Any] = [:], cache key: String, as type: T.Type) async -> (value: T?, fresh: Bool) {
        if client != nil, let text = try? await call(tool, arguments), let value = try? Self.decode(T.self, from: text) {
            Cache.store(text, for: key)
            return (value, true)
        }
        if let text = Cache.load(key), let value = try? Self.decode(T.self, from: text) { return (value, false) }
        return (nil, false)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: Data(text.utf8))
    }

    // MARK: Storage

    private static let macKey = "pairedMac"

    private static func loadMac() -> PairedMac? {
        UserDefaults.standard.data(forKey: macKey).flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
    }

    private static func saveMac(_ mac: PairedMac?) {
        if let mac, let data = try? JSONEncoder().encode(mac) {
            UserDefaults.standard.set(data, forKey: macKey)
        } else {
            UserDefaults.standard.removeObject(forKey: macKey)
        }
    }
}

/// Watches the local network for Macs running Binders with the phone link on.
final class MacBrowser: @unchecked Sendable {
    private let browser = NWBrowser(for: .bonjour(type: Link.serviceType, domain: nil), using: .tcp)
    private let lock = NSLock()
    private var found: [String: NWEndpoint] = [:]

    init() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var endpoints: [String: NWEndpoint] = [:]
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint { endpoints[name] = result.endpoint }
            }
            self?.lock.withLock { self?.found = endpoints }
        }
        browser.start(queue: .global(qos: .utility))
    }

    func endpoint(named name: String) -> NWEndpoint? {
        lock.withLock { found[name] }
    }
}

/// The device key, kept in the Keychain and never backed up to other devices.
enum Keychain {
    private static let service = "io.binders.link"

    static func save(_ key: Data, account: String) throws {
        delete(account: account)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: key,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw LinkClient.Failure.rejected("Couldn't save the key (\(status))") }
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? result as? Data : nil
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// The last answer to each question the screens ask, so they have something to show while the Mac is out of reach.
enum Cache {
    private static var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(_ key: String) -> URL {
        folder.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".json")
    }

    static func store(_ text: String, for key: String) { try? Data(text.utf8).write(to: file(key), options: .atomic) }
    static func load(_ key: String) -> String? { (try? Data(contentsOf: file(key))).map { String(decoding: $0, as: UTF8.self) } }
    static func clear() { try? FileManager.default.removeItem(at: folder) }
}

/// A note or to-do waiting for the Mac.
struct PendingSave: Codable, Identifiable, Equatable {
    let id: UUID
    let tool: String
    let text: String
    let binder: String?
    let created: Date
}

/// The outbox, kept in a file so it survives the app being closed.
enum Outbox {
    private static var file: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("outbox.json")
    }

    static func load() -> [PendingSave] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([PendingSave].self, from: $0) } ?? []
    }

    static func save(_ items: [PendingSave]) {
        try? JSONEncoder().encode(items).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
