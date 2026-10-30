import CryptoKit
import Darwin
import Foundation
import Network
import SwiftData
import BindersKit

/// A phone (or other client) paired with this Mac. Its key is the only way in, and it lives in the Keychain, where only
/// Binders writes: link-devices.json says which devices are paired, and when, never their keys. Revoking the device
/// deletes it.
struct LinkDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var key: Data
    var pairedAt: Date
    var lastSeen: Date?
}

/// A device as link-devices.json keeps it. Files from before 0.8.1 also held its key, which moves to the Keychain the first
/// time this build reads them, and is left out after.
private struct StoredLinkDevice: Codable {
    let id: UUID
    var name: String
    var key: Data?
    var pairedAt: Date
    var lastSeen: Date?
}

/// Binders as a server for paired phones, over the home network or a VPN. See `Link` for the protocol.
///
/// Two listeners: the main one accepts only paired devices' keys, and a pairing one opens only while a pairing code is on
/// screen, accepts only that code, and allows nothing but pairing. Once a device has proved which one it is, it gets the
/// same tools as `Binders --mcp`, with writes done here in the app, and `binders/changed` whenever the data changes.
@MainActor
@Observable
final class LinkServer {
    /// The name the iPhone shows for this Mac. A made-up one for demo data, so screenshots never carry the real name.
    nonisolated static var macName: String {
        if let name = AppPaths.demoUserName { return "\(name)'s MacBook Pro" }
        return Host.current().localizedName ?? "Mac"
    }

    enum Status: Equatable {
        case off
        case listening
        case failed(String)
    }

    private(set) var status: Status = .off
    private(set) var devices: [LinkDevice] = []
    private(set) var pairing: LinkPairing?
    /// A pairing code is on its way: the Mac reads its addresses first.
    private(set) var makingPairingCode = false
    private(set) var connectedDevices: Set<UUID> = []
    /// The Mac's addresses for phones as Settings lists them: what's offered and what's left out, in order.
    private(set) var addresses: [LinkAddresses.Entry] = []
    /// False until the interfaces have been read once since the link started: nothing is announced until then, so an Add
    /// made before the first read never sends phones a list of added addresses only.
    private(set) var addressesRead = false
    /// Addresses you added (as typed, cleaned up, in the order added), and the hosts of detected ones you left out. In
    /// this Mac's preferences, so a throwaway folder keeps its own.
    private(set) var addedAddresses: [String] = AppDefaults.store.stringArray(forKey: LinkServer.addedKey) ?? []
    private(set) var leftOutAddresses: [String] = AppDefaults.store.stringArray(forKey: LinkServer.leftOutKey) ?? []
    static let addedKey = "phoneLinkAddedAddresses"
    static let leftOutKey = "phoneLinkLeftOutAddresses"

    /// The port the main listener actually got (the requested one, unless that was 0).
    private(set) var boundPort: UInt16?
    private(set) var boundPairingPort: UInt16?

    @ObservationIgnored private weak var controller: DictationController?
    /// An agent's sessions, for the phone's Agents screen (lane AC2).
    @ObservationIgnored let phoneSessions = PhoneSessions()
    @ObservationIgnored private let requestedPort: UInt16
    @ObservationIgnored private let requestedPairingPort: UInt16
    @ObservationIgnored private let devicesURL: URL
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var pairingListener: NWListener?
    @ObservationIgnored private var pairingExpiry: Task<Void, Never>?
    @ObservationIgnored private var sessions: [ObjectIdentifier: LinkSession] = [:]
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var approvalObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingKinds: Set<String> = []
    @ObservationIgnored private var flushScheduled = false
    /// The last read of this Mac's interfaces, and when it was made.
    @ObservationIgnored private var interfaces: [LinkInterface] = []
    @ObservationIgnored private var interfacesReadAt: Date?
    /// Tailscale's word, while it's installed: the last answer, the last good one (which stands in for five minutes
    /// while the tool fails, only relabelling), and when it was last asked.
    @ObservationIgnored private var tailscaleStatus: LinkVPNStatus?
    @ObservationIgnored private var tailscaleGood: (status: LinkVPNStatus, at: Date)?
    @ObservationIgnored private var tailscaleAskedAt: Date?
    @ObservationIgnored private var firstReadStarted = false
    @ObservationIgnored private var routeWatch: LinkRouteWatch?
    @ObservationIgnored private var rereads: Task<Void, Never>?
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private var askLater: Task<Void, Never>?
    /// Devices in the file whose key isn't in the Keychain (it couldn't be read, or this data folder came from another
    /// Mac): kept in the file as they are, and never let in. Settings lists them to pair again or remove.
    private var keyless: [StoredLinkDevice] = []
    /// Devices whose key the Keychain didn't take when it moved there: it stays in the file until it does.
    @ObservationIgnored private var keysInFile: Set<UUID> = []

    static let pairingLifetime: TimeInterval = 10 * 60
    /// Where binders://link/pair leaves the pairing link, for pairing a phone that isn't at the Mac. Gone once pairing closes.
    static var pairingLinkFile: URL { AppPaths.support.appendingPathComponent("link-pairing.txt") }

    init(controller: DictationController, port: UInt16 = Link.port, pairingPort: UInt16 = Link.pairingPort,
         devicesURL: URL = AppPaths.support.appendingPathComponent("link-devices.json")) {
        self.controller = controller
        requestedPort = port
        requestedPairingPort = pairingPort
        self.devicesURL = devicesURL
        loadDevices()
    }

    var isRunning: Bool { listener != nil }

    /// Starts listening if it isn't already. The app calls this when the setting is on; the self-test calls it directly.
    func start() {
        guard listener == nil else { return }
        observeChanges()
        restartListener()
        watchNetwork()
    }

    func stop() {
        cancelPairing()
        routeWatch?.cancel()
        routeWatch = nil
        for task in [rereads, settling, askLater] { task?.cancel() }
        rereads = nil
        settling = nil
        askLater = nil
        firstReadStarted = false
        addressesRead = false
        // In a throwaway folder the run ends here: its devices' keys leave the Keychain with it.
        if AppPaths.isDemo { forgetKeysOfThrowawayRun() }
        listener?.cancel()
        listener = nil
        boundPort = nil
        for session in sessions.values { session.close() }
        sessions.removeAll()
        connectedDevices.removeAll()
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        saveObserver = nil
        if let approvalObserver { NotificationCenter.default.removeObserver(approvalObserver) }
        approvalObserver = nil
        status = .off
    }

    // MARK: Pairing

    /// Opens pairing for ten minutes and returns what the QR code shows. The code works once. The Mac's addresses are
    /// read first, Tailscale's word included, so the code carries the likeliest few as they are now.
    func beginPairing() async -> LinkPairing? {
        cancelPairing()
        makingPairingCode = true
        defer { makingPairingCode = false }
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
        await read(asking: .yes)
        // Cancelled, or opened again, while the addresses were read.
        guard pairingListener === self.pairingListener else { return nil }
        var hosts = LinkAddresses.pairingAddresses(LinkAddresses.offered(addresses), port: port)
        // Nowhere else (every address left out, or none yet): this Mac itself, for the Simulator.
        if hosts.isEmpty { hosts = ["127.0.0.1:\(port)"] }
        let pairing = LinkPairing(name: LinkServer.macName, addresses: hosts, secret: secret,
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

    /// Called by a pairing session: creates the device and its key, keeps the key in the Keychain, then closes pairing.
    /// Nil when the Keychain doesn't take the key: the device isn't paired, as its key would otherwise have to go in the
    /// data folder.
    fileprivate func completePairing(name: String) -> LinkDevice? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = LinkDevice(id: UUID(), name: cleaned.isEmpty ? "iPhone" : String(cleaned.prefix(60)),
                                key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, pairedAt: Date())
        guard Self.keep(device.key, for: device.id) else {
            Log.app.error("Link: the Keychain didn't take a new device's key, so it wasn't paired")
            return nil
        }
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
        keyless.removeAll { $0.id == id }
        keysInFile.remove(id)
        Keychain.write("", for: Self.keyName(id))
        saveDevices()
        for (key, session) in sessions where session.device == id {
            session.close()
            sessions.removeValue(forKey: key)
        }
        connectedDevices.remove(id)
        // Unpaired, it no longer hands anything over in Auto, nor when it's paired again, until it's allowed again.
        AutoPhones.forget(id)
        restartListener()
    }

    fileprivate func device(_ id: UUID) -> LinkDevice? { devices.first { $0.id == id } }

    /// A device in link-devices.json that can't connect, as its key isn't in this Mac's Keychain.
    struct DeviceToPairAgain: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    /// The devices that can't connect until they pair again, for Settings to list with Remove.
    var devicesToPairAgain: [DeviceToPairAgain] { keyless.map { DeviceToPairAgain(id: $0.id, name: $0.name) } }

    /// Hellos from paired devices since the link started: each is a connection made, which the self-tests count.
    @ObservationIgnored private(set) var hellos = 0

    fileprivate func deviceSaidHello(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        hellos += 1
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
            listener.service = NWListener.Service(name: LinkServer.macName, type: Link.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection, pairing: false) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, let listener, listener === self.listener else { return }
                    switch state {
                    case .ready:
                        self.boundPort = listener.port?.rawValue
                        self.status = .listening
                        // The first read since the link started, Tailscale's word included.
                        if !self.firstReadStarted {
                            self.firstReadStarted = true
                            Task { await self.read(asking: .yes) }
                        }
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
        // Every connection gets a session before TLS: only so many may wait to say who they are.
        guard sessions.values.filter({ $0.device == nil }).count < Self.waitingLimit else { return connection.cancel() }
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

    /// Every save of the app's database becomes a `binders/changed` notification, grouped over a quarter second. An agent
    /// asking your approval is told at once, to phones that read it.
    private func observeChanges() {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] notification in
            let kinds = Self.kinds(in: notification.userInfo)
            MainActor.assumeIsolated { self?.changed(kinds) }
        }
        approvalObserver = NotificationCenter.default.addObserver(forName: BoardService.approvalAsked, object: nil, queue: .main) { [weak self] notification in
            let card = notification.userInfo?["card"] as? UUID, approval = notification.userInfo?["approval"] as? UUID
            MainActor.assumeIsolated {
                guard let card, let approval else { return }
                self?.approvalAsked(card: card, approval: approval)
            }
        }
    }

    /// An agent asks your approval: phones that read it hear who asks and what, in Lock Screen words, never who it goes to or
    /// what it says, which the card shows in the app.
    private func approvalAsked(card id: UUID, approval: UUID) {
        guard let board = controller?.board, let card = board.card(id), let waiting = card.waitingApproval(events: board.timeline(id)),
              waiting.event.id == approval else { return }
        let notice = AgentApproval.Notice(card: id.uuidString, approval: approval.uuidString, agent: waiting.event.author,
                                          headline: waiting.approval.headline(by: waiting.event.author), title: card.title,
                                          asked: AutomationPayload.iso(waiting.event.createdAt))
        notify(LinkFeatures.approvalMethod, notice.params)
    }

    /// Your decision on an approval, from a phone: as on this Mac, with the phone's name on the receipt.
    fileprivate func decide(_ params: [String: Any], device: UUID?) throws -> String {
        guard let board = controller?.board else { throw MCPCore.ToolFailure("Binders is shutting down") }
        guard let decision = AgentApproval.Decision(params: params), let id = UUID(uuidString: decision.card) else {
            throw MCPCore.ToolFailure("Say which card and request, and approve or decline")
        }
        guard let card = board.card(id) else { throw MCPCore.ToolFailure("That card isn't on the board any more.") }
        do {
            return try board.decide(card, approval: UUID(uuidString: decision.approval), approve: decision.approve, reason: decision.reason, by: .you,
                                    on: device.flatMap { self.device($0)?.name } ?? "your iPhone")
        } catch {
            throw MCPCore.ToolFailure(error.localizedDescription)
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
        notify(LinkFeatures.changed, ["kinds": kinds])
    }

    /// A notification to every subscribed phone that reads it: one that doesn't (iPhone 2.0, for anything new) would take
    /// it as "everything changed".
    func notify(_ method: String, _ params: [String: Any]) {
        for session in sessions.values where session.isSubscribed && session.reads.contains(LinkFeatures.notification(method)) {
            session.send(["jsonrpc": "2.0", "method": method, "params": params])
        }
    }

    /// For the self-tests, in a throwaway folder only: read what phones say and answer nothing, as a Mac gone to sleep.
    @ObservationIgnored var stalls = false
    /// For the self-tests, in a throwaway folder only: the next session to send anything answers nothing for its life;
    /// the next `binders/hello` gets no answer, isn't counted, and its session answers nothing more.
    @ObservationIgnored var stallsNextSession = false
    @ObservationIgnored var stallsNextHello = false

    fileprivate func claimStalledSession() -> Bool {
        guard stallsNextSession, AppPaths.isDemo else { return false }
        stallsNextSession = false
        return true
    }

    fileprivate func claimStalledHello() -> Bool {
        guard stallsNextHello, AppPaths.isDemo else { return false }
        stallsNextHello = false
        return true
    }

    /// A session that hasn't said hello (or paired) by then is closed, and at most this many wait at once. The deadline
    /// can be shortened in a throwaway folder only, for the self-test.
    static let waitingLimit = 64
    @ObservationIgnored var helloDeadline: TimeInterval = 20
    fileprivate var helloDeadlineNow: TimeInterval { AppPaths.isDemo ? helloDeadline : 20 }

    // MARK: Without the library

    /// What a phone hears at hello while the library didn't open. It stays offline and keeps what it saves (notes, to-dos,
    /// dictations, captures, moments, answers) in its outbox until a later hello is answered: every iPhone build does, where
    /// an error on a dictation, a capture or an answer would have it let that go instead.
    static let unavailableForPhone = "Binders on your Mac couldn't open its library. Quit and reopen Binders there; until then this iPhone keeps what you save."
    /// The code that refusal, and a refused write, carry: apart from -32001 (not paired). Phones show the message either way.
    static let unavailableCode = -32002

    /// For the self-tests, in a throwaway folder only: a phone let past hello while the library didn't open, to check what
    /// each thing it sends gets.
    @ObservationIgnored var admitsWhileUnavailable = false

    /// What a phone past hello gets for a write while the library didn't open; hello turns phones away first, so this is
    /// the backstop.
    enum Refusal: Equatable {
        /// The link closes without an answer: the phone keeps the item and sends it again later, where an error would have it
        /// let go of it.
        case close
        /// An answer the phone shows, for something you tapped.
        case error(String)
    }

    /// The tools an answer from the phone's outbox goes through: get_task (is its question still waiting?), then
    /// comment_task. An error on either has the phone let the answer go, so they close the link instead.
    static let answerTools: Set<String> = ["get_task", "comment_task"]

    /// Nil when the method goes ahead. `tool` is the tool a tools/call names. Other tools are refused where they run, with
    /// the error the phone keeps a note or a to-do on: InboxCommands for writes, MCPServer for reads.
    static func refusal(for method: String, tool: String? = nil) -> Refusal? {
        guard !Store.shared.canSave else { return nil }
        switch method {
        case "binders/dictation", ConversationPayload.method, MomentPayload.method: return .close
        // What you asked the Manager waits on the phone and comes again (lane MG1); a tap on Undo or Accept is said no to.
        case LinkFeatures.managerMethod, LinkFeatures.chatSendMethod, LinkFeatures.sessionSendMethod: return .close
        case CaptureOutcome.actMethod, ConversationSuggestion.actMethod, LinkFeatures.managerActMethod, LinkFeatures.sessionActMethod: return .error(Store.refusedMessage)
        case "tools/call" where tool.map(answerTools.contains) == true: return .close
        default: return nil
        }
    }

    /// What the connected phones read, for the self-tests.
    var phoneFeatures: [Set<String>] { sessions.values.filter { $0.device != nil }.map(\.reads) }

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
            // A folder made, renamed, moved or deleted changes what a binder's notes show: nothing new on the wire.
            case "FolderRecord": kinds.insert("notes")
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

    /// A dictation made on the phone, kept with this Mac's own: in its history, in recent_dictations and in search. One
    /// sent again (its answer was lost on the way) is kept once.
    fileprivate func keepDictation(_ params: [String: Any]) {
        let text = (params["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = (params["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let known = (try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.id == id }))) ?? []
        guard known.isEmpty else { return }
        let model = (params["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let record = TranscriptRecord(id: id, createdAt: (params["date"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(),
                                      mode: "dictation", rawText: params["raw"] as? String ?? text, finalText: text,
                                      appName: params["app"] as? String ?? "iPhone", bundleID: nil, category: nil,
                                      duration: params["duration"] as? Double ?? 0, asrMillis: 0, llmMillis: 0, engine: "iPhone",
                                      llmModel: model, usedLLM: model != nil, fallbackReason: nil, audioFileName: nil, status: "inserted")
        Store.shared.insert(record)
    }

    /// The phone heard someone start talking: the model loads now, for the write-up.
    fileprivate func warmModel() { controller?.warmForPhone() }

    /// What this Mac takes besides the tools, for `binders/hello`: a phone holds back what its Mac doesn't list.
    static let features = [ConversationPayload.feature, ConversationSuggestion.feature, LinkFeatures.warm, CaptureOutcome.feature, MomentPayload.feature,
                           LinkFeatures.dedupe, LinkFeatures.askProgress, LinkFeatures.approvals, MomentPayload.addsFeature, LinkFeatures.giveTo,
                           LinkFeatures.addresses, MomentPayload.agreedFeature, LinkFeatures.commentWakes, MomentPayload.autoFeature,
                           ConversationPayload.soloFeature, LinkFeatures.folders, LinkFeatures.distill, LinkFeatures.teamAgents, LinkFeatures.manager, LinkFeatures.chats,
                           LinkFeatures.sessions]

    /// What became of what the phone sent, for the ids it asks after (at most 50); ones this Mac doesn't know are left out.
    fileprivate func outcomes(_ ids: [String]) -> [[String: Any]] {
        guard let controller else { return [] }
        return ids.prefix(50).compactMap(UUID.init(uuidString:)).compactMap {
            (controller.moments.outcome($0) ?? controller.conversations.outcome($0))?.jsonObject
        }
    }

    /// Something you said to yourself near the phone: acted on or offered, and its outcome in the reply when it's ready
    /// within 20 seconds (a model call can take longer: the phone asks again with binders/outcomes). `device`: the paired
    /// phone it came from, for whether Auto from it may hand over.
    /// `soloAuto`: the phone's hello listed `ConversationPayload.soloFeature`, so its `fromTranscript` and `uncued` are read.
    fileprivate func keepMoment(_ params: [String: Any], from device: UUID? = nil, soloAuto: Bool = false) async throws -> [String: Any] {
        guard let controller else { throw MCPCore.ToolFailure("Binders is shutting down") }
        var payload: MomentPayload
        do {
            payload = try MomentPayload(jsonObject: params)
        } catch {
            throw MCPCore.ToolFailure("That isn't a moment Binders can read: \(error.localizedDescription)")
        }
        // Lane Y2's fields only from a phone that said it sends them.
        if !soloAuto {
            payload.fromTranscript = nil
            payload.uncued = nil
        }
        guard !payload.text.trimmed.isEmpty else { throw MCPCore.ToolFailure("That moment has no words in it") }
        let moments = controller.moments
        let decided = Task { await moments.receive(payload, from: device, soloAuto: soloAuto) }
        // Whichever comes first: the outcome, or 15 seconds, inside the 20 a phone gives Siri's request. A later outcome
        // is kept, and the phone asks after it (binders/outcomes).
        let outcome = await MomentRace.first(decided, within: .seconds(15))
        var reply: [String: Any] = ["id": payload.id.uuidString]
        if let outcome { reply["outcome"] = outcome.jsonObject }
        return reply
    }

    /// Add, Not Now, Undo or Assign on what the phone sent.
    /// Lane Y2: on a capture's id, from a phone that lists soloAuto (`soloAuto`), Stop All, Not Only Me and its mode.
    fileprivate func actOnOutcome(_ params: [String: Any], soloAuto: Bool = false) async throws -> String {
        guard let controller else { throw MCPCore.ToolFailure("Binders is shutting down") }
        guard let id = (params["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw MCPCore.ToolFailure("No id") }
        let action = params["action"] as? String ?? ""
        var answered = controller.moments.act(on: id, action: action, agent: params["agent"] as? String)
        if answered == nil, soloAuto {
            answered = await controller.conversations.act(on: id, action: action, mode: params["mode"] as? String)
        }
        guard let result = answered else {
            throw MCPCore.ToolFailure("Binders on this Mac doesn't know that one")
        }
        guard result.ok else { throw MCPCore.ToolFailure(result.message) }
        return result.message
    }

    /// A conversation the phone heard, transcribed there: kept at once, written up and filed after. One sent again is kept once.
    /// `device` and `soloAuto` (lane Y2): the paired phone it came from, and whether its hello listed soloAuto, so the
    /// capture's vouch is read; any other caller's is dropped.
    fileprivate func keepConversation(_ params: [String: Any], from device: UUID? = nil, soloAuto: Bool = false) throws -> UUID {
        guard let controller else { throw MCPCore.ToolFailure("Binders is shutting down") }
        let payload: ConversationPayload
        do {
            payload = try ConversationPayload(jsonObject: params)
        } catch {
            throw MCPCore.ToolFailure("That isn't a capture Binders can read: \(error.localizedDescription)")
        }
        switch controller.conversations.receive(payload, from: device, overLink: true, soloAuto: soloAuto) {
        case .kept(let id), .known(let id): return id
        case .refused: throw MCPCore.ToolFailure(Store.refusedMessage)
        }
    }

    /// Suggestions on the conversations the phone heard, for it to show and notify.
    /// The suggestions for a phone, of the kinds it reads: iPhone 2.0 loses the whole list over one kind it doesn't know.
    fileprivate func suggestions(for reads: Set<String>) -> [[String: Any]] {
        guard let controller else { return [] }
        return controller.conversations.suggestionsForPhone().filter { reads.contains(LinkFeatures.suggestion($0.kind)) }.compactMap { suggestion in
            (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(suggestion))) as? [String: Any]
        }
    }

    /// Yes or no to a suggestion, from the phone, or Give to: the card or idea given to the agent it names.
    fileprivate func act(on suggestion: String, action: String, agent: String) -> (ok: Bool, message: String) {
        guard let controller else { return (false, "Binders is shutting down") }
        switch action {
        case "accept": return controller.conversations.accept(suggestion)
        case "give":
            guard !agent.trimmingCharacters(in: .whitespaces).isEmpty else { return (false, "Say which agent to give it to.") }
            return controller.conversations.give(suggestion, to: agent)
        default:
            controller.conversations.dismiss(suggestion)
            return (true, "")
        }
    }

    /// A tool call from the phone. `askProgress`: ask_knowledge as it goes, for the phone that asked.
    /// `doing`: whether the phone is told what runs say they're doing (`LinkFeatures.workStreamsDoing`).
    /// `momentAgreed`: whether the phone sends its yes with what you say (`MomentPayload.agreedFeature`), for list_agents.
    /// `asksFirst`: whether the phone asks before a comment goes to an agent (`LinkFeatures.commentsAskFirst`): its comment
    /// wakes only the agent it names in `to` (none, when it names none), and one from a phone that doesn't ask wakes no one.
    /// `momentAuto`: whether it has Auto (`MomentPayload.autoFeature`): list_agents then says what Auto can hand over now,
    /// from the router's own decision model, and to which agents.
    fileprivate func runTool(_ message: [String: Any], askProgress: MCPServer.AskProgressSink? = nil, doing: Bool, momentAgreed: Bool = false,
                             asksFirst: Bool = false, momentAuto: Bool = false, soloAuto: Bool = false) async -> [String: Any]? {
        guard let controller else { return MCPCore.failure(id: message["id"], code: -32603, message: "Binders is shutting down") }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return await MCPCore.handle(message, serverName: "binders", serverVersion: version, instructions: MCPServer.instructions,
                                    tools: MCPServer.hostTools, call: { name, arguments in
            let to = (arguments["to"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // On the phone, it's you.
            return try await MCPServer.call(name, arguments, knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller, arguments: arguments),
                                            actor: .you, askProgress: askProgress, doing: doing, momentAgreed: momentAgreed, momentAuto: momentAuto,
                                            soloAuto: soloAuto,
                                            decisionModels: controller.router.models, commentWake: asksFirst ? .only(to) : .none)
        })
    }

    // MARK: Addresses

    /// For the self-tests and drawings, in a throwaway folder only: a fixed scan in place of this Mac's network, so a
    /// test never sees the network come and go and a drawing never shows a real address. Nil reads the real one.
    @ObservationIgnored var networkForTests: LinkAddressScan? = AppPaths.isDemo ? .demo : nil
    private var scanForTests: LinkAddressScan? { AppPaths.isDemo ? networkForTests : nil }
    /// For the self-tests, in a throwaway folder only: where a stand-in for Tailscale's tool is installed. While set, it's
    /// looked for and asked as the real tool is (gone once its file is), and its word counts in place of the fixed scan's.
    @ObservationIgnored var tailscaleStandIn: URL?
    /// A hello reads the interfaces first when the last read is this old. Shorter in a throwaway folder only.
    @ObservationIgnored var helloRereadAfter: TimeInterval = 5

    /// Where Tailscale's tool is now: never looked for in a throwaway folder, apart from a self-test's stand-in.
    private var tailscaleTool: URL? {
        guard AppPaths.isDemo else { return LinkAddressScanner.tailscaleTool }
        return tailscaleStandIn.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    /// A VPN tool's word, as the classifier takes it: Tailscale's last answer, or in a throwaway folder the fixed scan's.
    private var vpnStatuses: [LinkVPNStatus] {
        if let scan = scanForTests, tailscaleStandIn == nil { return scan.vpns }
        return tailscaleStatus.map { [$0] } ?? []
    }

    /// When Tailscale's tool is asked, besides never in a throwaway folder or when it isn't installed.
    private enum TailscaleAsk {
        case no, yes
        /// When the last ask is at least this old.
        case ifOlder(TimeInterval)
        /// When the addresses kept from the interfaces changed, and the last ask is at least this old.
        case ifChanged(TimeInterval)
    }

    /// Reads this Mac's network again: when Settings › iPhone opens, and for the self-tests. Tailscale is asked when its
    /// last answer is 15 s old, or at once with `force`.
    func refreshAddresses(force: Bool = false) async {
        await read(asking: force ? .yes : .ifOlder(15))
    }

    /// What a hello carries, read first when the last read is 5 s old or there's none yet: so the list is never older
    /// than that, whether the Mac has just woken, Binders started before the VPN, or a change went unseen.
    func addressesForHello() async -> [LinkAddress] {
        let limit = AppPaths.isDemo ? helloRereadAfter : 5
        if !addressesRead || interfacesReadAt.map({ Date().timeIntervalSince($0) >= limit }) ?? true {
            await read(asking: .no)
        }
        return helloAddresses()
    }

    /// What's offered, with the link's port filled in where it's the link's, at most a hello's worth.
    func helloAddresses() -> [LinkAddress] {
        LinkAddresses.offered(addresses).prefix(LinkAddresses.helloLimit).map { address in
            var filled = address
            filled.port = address.port ?? linkPort
            return filled
        }
    }

    /// The port phones connect to.
    private var linkPort: UInt16 { boundPort ?? (requestedPort == 0 ? Link.port : requestedPort) }

    /// Reads the interfaces off the main thread (a fixed scan in a throwaway folder), asks Tailscale when `ask` says,
    /// and applies what it found.
    private func read(asking ask: TailscaleAsk) async {
        let readAt = Date()
        let fixed = scanForTests
        let fresh: [LinkInterface]
        if let fixed {
            fresh = fixed.interfaces
        } else {
            fresh = await LinkAddressScanner.readInterfaces()
        }
        var answer: LinkVPNStatus??
        if let tool = tailscaleTool {
            if shouldAsk(ask, fresh: fresh) {
                tailscaleAskedAt = Date()
                answer = .some(await LinkAddressScanner.askTailscale(tool: tool))
            }
        } else if tailscaleStatus != nil {
            // The tool is gone (uninstalled, or moved by an update): as when an ask fails, its last answer only relabels,
            // and only for a while, so what it named that no interface has stops being offered now.
            answer = .some(nil)
        }
        apply(fresh, readAt: readAt, tailscale: answer)
    }

    private func shouldAsk(_ ask: TailscaleAsk, fresh: [LinkInterface]) -> Bool {
        let age = tailscaleAskedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        switch ask {
        case .no: return false
        case .yes: return true
        case .ifOlder(let limit): return age >= limit
        case .ifChanged(let limit):
            guard Self.kept(fresh) != Self.kept(interfaces) else { return false }
            if age >= limit { return true }
            // Changed, but asked a moment ago: ask once that moment is past.
            if askLater == nil {
                askLater = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(limit - age))
                    guard !Task.isCancelled, let self else { return }
                    self.askLater = nil
                    await self.read(asking: .ifOlder(limit))
                }
            }
            return false
        }
    }

    /// The addresses the interfaces alone offer, to tell a real change from Apple's own links coming and going.
    private static func kept(_ interfaces: [LinkInterface]) -> Set<String> {
        Set(LinkAddresses.classify(interfaces: interfaces).map(\.address.host))
    }

    /// Takes a read: its interfaces unless a newer read has already been applied (a slow read that asked Tailscale never
    /// puts back an older picture), and Tailscale's answer when it was asked.
    private func apply(_ fresh: [LinkInterface], readAt: Date, tailscale answer: LinkVPNStatus??) {
        if interfacesReadAt.map({ readAt >= $0 }) ?? true {
            interfaces = fresh
            interfacesReadAt = readAt
        }
        if let answer {
            if let status = answer {
                tailscaleStatus = status
                tailscaleGood = (status, Date())
            } else if let good = tailscaleGood, Date().timeIntervalSince(good.at) < 5 * 60 {
                // The tool failed or took too long: its last good answer stands in, and only relabels.
                var cached = good.status
                cached.fromCache = true
                tailscaleStatus = cached
            } else {
                tailscaleStatus = nil
            }
        }
        addressesRead = true
        applyAddresses()
    }

    /// Classifies the last read with your additions and what you left out, then brings every subscribed phone that reads
    /// the notice up to date, each only when what it was last given differs.
    private func applyAddresses() {
        let entries = LinkAddresses.classify(interfaces: interfaces, vpns: vpnStatuses, added: addedAddresses, leftOut: Set(leftOutAddresses),
                                             port: linkPort)
        if entries != addresses { addresses = entries }
        guard addressesRead else { return }
        let list = helloAddresses()
        for session in sessions.values where session.isSubscribed && session.readsAddressNotices && session.sentAddresses != list {
            session.sendAddresses(list)
        }
    }

    /// The routing socket, and a read every 30 s as the backstop, while the link is on. Neither in a throwaway folder.
    private func watchNetwork() {
        guard scanForTests == nil else { return }
        if routeWatch == nil {
            routeWatch = LinkRouteWatch(queue: .global(qos: .utility)) { [weak self] in
                Task { @MainActor in self?.routeChanged() }
            }
        }
        rereads?.cancel()
        rereads = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                await self.read(asking: .ifOlder(5 * 60))
            }
        }
    }

    /// An address or an interface changed: read again once it has settled for a second (a VPN coming up sends a burst).
    private func routeChanged() {
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.settling = nil
            await self.read(asking: .ifChanged(15))
        }
    }

    /// Nil when it's added; otherwise why not, for Settings to show. The link's own port is dropped. Only a duplicate of
    /// another one you added, or more than eight, is refused: a detected address you add becomes yours, and is offered
    /// from then on even while its interface is down, which is how to keep a VPN's fixed address in every hello.
    func addAddress(_ text: String) -> String? {
        let port = linkPort
        let typed: LinkAddresses.Typed
        switch LinkAddresses.parse(text) {
        case .failure(let problem): return problem.words(port: port)
        case .success(let read): typed = read.dropping(port: port)
        }
        let key = typed.key(defaultPort: port)
        if addedAddresses.contains(where: { Self.key(ofAdded: $0, port: port) == key }) { return LinkAddresses.Problem.duplicate.words(port: port) }
        guard addedAddresses.count < LinkAddresses.addedLimit else { return LinkAddresses.Problem.tooMany.words(port: port) }
        addedAddresses.append(typed.text)
        leftOutAddresses.removeAll { $0 == typed.host }
        saveAddressChoices()
        applyAddresses()
        return nil
    }

    /// Remove, on one you added: by what you typed, or as the list writes it.
    func removeAddress(_ text: String) {
        let port = linkPort
        guard let key = Self.key(ofAdded: text, port: port) else { return }
        addedAddresses.removeAll { Self.key(ofAdded: $0, port: port) == key }
        saveAddressChoices()
        applyAddresses()
    }

    /// Leave Out, or Include, on a detected address.
    func leaveOut(_ host: String, _ out: Bool) {
        guard let host = LinkAddresses.canonicalHost(host) else { return }
        leftOutAddresses.removeAll { LinkAddresses.canonicalHost($0) == host }
        if out { leftOutAddresses.append(host) }
        saveAddressChoices()
        applyAddresses()
    }

    private static func key(ofAdded text: String, port: UInt16) -> String? {
        guard case .success(let typed) = LinkAddresses.parse(text) else { return nil }
        return typed.dropping(port: port).key(defaultPort: port)
    }

    private func saveAddressChoices() {
        AppDefaults.store.set(addedAddresses, forKey: Self.addedKey)
        AppDefaults.store.set(leftOutAddresses, forKey: Self.leftOutKey)
    }

    /// Which address a connected device came in on, for Paired devices: "100.64.0.2 (VPN)", "the local network", as this
    /// Mac found it (one you added included). Nil when it isn't connected.
    func connectedOver(_ device: UUID) -> String? {
        guard let session = sessions.values.filter({ $0.device == device && $0.localHost != nil }).max(by: { $0.serial < $1.serial }),
              let host = session.localHost else { return nil }
        return LinkAddresses.connectedOver(host, interfaces: interfaces, vpns: vpnStatuses, entries: addresses, port: linkPort)
    }

    /// For the self-tests: every open session, with or without a hello.
    var sessionCount: Int { sessions.count }

    // MARK: Storage

    /// The paired devices, from link-devices.json, with their keys from the Keychain. A file from before 0.8.1 holds the
    /// keys itself: the first time this build reads one, each key moves to the Keychain (checked by reading it back) and
    /// the file is written again without it, so nobody has to pair again. After that, a key found in the file is never
    /// taken, as only Binders writes the Keychain while anything that runs as you can write the file: a device put in the
    /// file can't get in. One whose key the Keychain doesn't have stays in the file but isn't let in. The move counts as
    /// done when the mark says so or when the Keychain already holds the key of any device in the file, so a mark that
    /// can't be read at launch doesn't bring the file's keys back.
    private func loadDevices() {
        devices = []
        keyless = []
        keysInFile = []
        let marked = Keychain.read(movedName) == "1"
        guard let data = try? Data(contentsOf: devicesURL), let stored = try? JSONDecoder().decode([StoredLinkDevice].self, from: data) else {
            // Nothing from before to move: from now on, a key put in the file doesn't count. A throwaway folder starts
            // with no file, and a mark for it would only be left behind.
            if !marked, !AppPaths.isDemo { Keychain.write("1", for: movedName) }
            return
        }
        let moved = marked || stored.contains { Self.storedKey(for: $0.id) != nil }
        var rewrite = false
        for record in stored {
            var key = Self.storedKey(for: record.id)
            if let inFile = record.key, !inFile.isEmpty {
                rewrite = true
                if !moved, key != inFile {
                    if Self.keep(inFile, for: record.id) {
                        key = inFile
                    } else {
                        // The Keychain didn't take it: it stays in the file, and in use, until a later launch moves it.
                        Log.app.error("Link: the Keychain didn't take a paired device's key; it stays in link-devices.json for now")
                        key = inFile
                        keysInFile.insert(record.id)
                    }
                }
            }
            guard let key else {
                var kept = record
                kept.key = nil
                keyless.append(kept)
                continue
            }
            devices.append(LinkDevice(id: record.id, name: record.name, key: key, pairedAt: record.pairedAt, lastSeen: record.lastSeen))
        }
        // Moved, every one: from now on the file's keys don't count.
        if !marked, keysInFile.isEmpty {
            Keychain.write("1", for: movedName)
        }
        if rewrite { saveDevices() }
    }

    private func saveDevices() {
        let stored = devices.map { device in
            StoredLinkDevice(id: device.id, name: device.name, key: keysInFile.contains(device.id) ? device.key : nil, pairedAt: device.pairedAt,
                             lastSeen: device.lastSeen)
        } + keyless
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: devicesURL, options: [.atomic])
        // Who's paired, and when: readable by this user only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: devicesURL.path)
    }

    /// The Keychain item holding a device's key, apart from yours in a throwaway folder, as AgentRegistry keeps its own.
    private static func keyName(_ id: UUID) -> String {
        (AppPaths.isDemo ? "selftest-" : "") + "link-device-key-\(id.uuidString)"
    }

    /// Set once every key in link-devices.json has moved to the Keychain, after which the file's keys don't count. In a
    /// throwaway folder, one for each devices file, so the self-tests stay apart.
    var movedName: String {
        guard AppPaths.isDemo else { return "link-device-keys-moved" }
        let file = SHA256.hash(data: Data(devicesURL.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "selftest-link-device-keys-moved-\(file)"
    }

    /// A device's key as the Keychain holds it, or nil.
    static func storedKey(for id: UUID) -> Data? {
        Keychain.read(keyName(id)).flatMap { Data(base64Encoded: $0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Keeps a device's key in the Keychain, and says whether it's there now, read back.
    private static func keep(_ key: Data, for id: UUID) -> Bool {
        let text = key.base64EncodedString()
        Keychain.write(text, for: keyName(id))
        return Keychain.read(keyName(id)) == text
    }

    /// In a throwaway folder (the self-tests, the demo Mac for the iPhone's UI tests), the folder goes once the run ends:
    /// the keys of its devices, and its own "moved" mark, go from the Keychain with it.
    private func forgetKeysOfThrowawayRun() {
        guard AppPaths.isDemo else { return }
        for device in devices { Keychain.write("", for: Self.keyName(device.id)) }
        Keychain.write("", for: movedName)
    }
}

/// One connected client: framing, the hello handshake, and dispatch.
/// A moment's outcome if it comes in time, else nil, returning the moment either does: a task group would wait for both,
/// as awaiting a task's value can't be cancelled.
private final class MomentRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CaptureOutcome?, Never>?

    private init(_ continuation: CheckedContinuation<CaptureOutcome?, Never>) {
        self.continuation = continuation
    }

    private func finish(_ outcome: CaptureOutcome?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: outcome)
    }

    static func first(_ decided: Task<CaptureOutcome, Never>, within limit: Duration) async -> CaptureOutcome? {
        await withCheckedContinuation { continuation in
            let race = MomentRace(continuation)
            let timer = Task {
                try? await Task.sleep(for: limit)
                race.finish(nil)
            }
            Task {
                race.finish(await decided.value)
                timer.cancel()
            }
        }
    }
}

@MainActor
private final class LinkSession {
    private static var count = 0

    let connection: NWConnection
    let isPairing: Bool
    /// Newer sessions have higher numbers.
    let serial: Int
    private(set) var device: UUID?
    private(set) var isSubscribed = false
    /// What the phone reads (LinkFeatures), from its hello.
    private(set) var reads = LinkFeatures.firstPhone
    /// The address of this Mac the phone came in on, as LinkAddresses writes it.
    private(set) var localHost: String?
    /// The Mac's addresses as this phone was last given them, at hello or by notice.
    private(set) var sentAddresses: [LinkAddress]?
    var onClose: (() -> Void)?
    private weak var server: LinkServer?
    private var buffer = LineBuffer()
    private var challenge: Data?
    private var closed = false
    /// Said hello, or paired: past the deadline for saying who it is.
    private var settled = false
    /// For the self-tests: this session answers nothing.
    private var stalling = false
    private var heardAnything = false

    init(connection: NWConnection, isPairing: Bool, server: LinkServer) {
        self.connection = connection
        self.isPairing = isPairing
        self.server = server
        Self.count += 1
        serial = Self.count
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.noteLocalAddress()
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
        // One that hasn't said who it is in time goes: today's phones take well under a second.
        let deadline = server?.helloDeadlineNow ?? 20
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline))
            guard let self, !self.closed, !self.settled else { return }
            self.close()
        }
    }

    private func noteLocalAddress() {
        guard case .hostPort(let host, _)? = connection.currentPath?.localEndpoint else { return }
        localHost = LinkAddresses.hostText(host)
    }

    /// Whether this phone reads `binders/addresses`, from its hello.
    var readsAddressNotices: Bool { reads.contains(LinkFeatures.notification(LinkFeatures.addressesMethod)) }

    /// The Mac's whole new list, to this phone.
    func sendAddresses(_ list: [LinkAddress]) {
        sentAddresses = list
        send(["jsonrpc": "2.0", "method": LinkFeatures.addressesMethod, "params": ["addresses": list.map(\.jsonObject)]])
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
        if server.stalls, AppPaths.isDemo { return }
        if !heardAnything {
            heardAnything = true
            if !isPairing, server.claimStalledSession() { stalling = true }
        }
        if stalling { return }

        if isPairing {
            guard method == "binders/pair" else {
                return reply(MCPCore.failure(id: id, code: -32001, message: "This connection can only pair"))
            }
            guard let device = server.completePairing(name: params["name"] as? String ?? "") else {
                return reply(MCPCore.failure(id: id, code: -32603, message: "Binders couldn't keep this device's key in your Mac's Keychain, so it isn't paired. Try again."))
            }
            settled = true
            return reply(MCPCore.success(id: id, result: ["device": device.id.uuidString, "key": device.key.base64EncodedString(),
                                                          "name": LinkServer.macName,
                                                          "port": Int(server.boundPort ?? Link.port), "protocol": Link.protocolVersion]))
        }

        switch method {
        case "binders/challenge":
            let nonce = Link.randomBytes(32)
            challenge = nonce
            reply(MCPCore.success(id: id, result: ["challenge": nonce.base64EncodedString()]))
        case "binders/hello":
            if server.claimStalledHello() {
                stalling = true
                return
            }
            guard let nonce = challenge,
                  let deviceID = (params["device"] as? String).flatMap(UUID.init(uuidString:)),
                  let known = server.device(deviceID),
                  let proof = (params["proof"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  Link.verify(proof: proof, challenge: nonce, key: SymmetricKey(data: known.key)) else {
                return replyThenClose(MCPCore.failure(id: id, code: -32001, message: "This device isn't paired with this Mac"))
            }
            challenge = nil
            // The library didn't open: turned away with why, so the phone stays offline and keeps what it saves for later.
            // The link closes once the answer is out.
            if !Store.shared.canSave, !(server.admitsWhileUnavailable && AppPaths.isDemo) {
                reply(MCPCore.failure(id: id, code: LinkServer.unavailableCode, message: LinkServer.unavailableForPhone))
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.close()
                }
                return
            }
            device = deviceID
            reads = LinkFeatures.phone(params["features"] as? [String])
            settled = true
            server.deviceSaidHello(deviceID)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            var result: [String: Any] = ["name": LinkServer.macName, "version": version, "protocol": Link.protocolVersion,
                                         "features": LinkServer.features]
            // Where else it can reach this Mac, read fresh for it: only to a phone that reads it, and only after the
            // phone proved its key, so only a paired device ever sees this Mac's VPN addresses.
            if reads.contains(LinkFeatures.addresses) {
                let list = await server.addressesForHello()
                guard !closed else { return }
                result["addresses"] = list.map(\.jsonObject)
                sentAddresses = list
            }
            reply(MCPCore.success(id: id, result: result))
        default:
            guard device != nil else {
                return reply(MCPCore.failure(id: id, code: -32001, message: "Say hello first"))
            }
            switch LinkServer.refusal(for: method, tool: params["name"] as? String) {
            case .close?: return close()
            case .error(let message)?: return reply(MCPCore.failure(id: id, code: LinkServer.unavailableCode, message: message))
            case nil: break
            }
            if method == "binders/subscribe" {
                isSubscribed = true
                // A phone whose hello came before a change hears the new list first, on the same stream.
                if readsAddressNotices, server.addressesRead {
                    let list = server.helloAddresses()
                    if sentAddresses != list { sendAddresses(list) }
                }
                return reply(MCPCore.success(id: id, result: [String: Any]()))
            }
            if method == "binders/format" {
                // What the phone heard, cleaned up here the way dictation on this Mac is: its model, dictionary and snippets.
                let result = await server.formatDictation(params["text"] as? String ?? "")
                return reply(MCPCore.success(id: id, result: ["text": result.text, "used_model": result.usedLLM,
                                                              "model": result.usedLLM ? AppSettings.shared.llmModelName : ""]))
            }
            if method == "binders/dictation" {
                server.keepDictation(params)
                return reply(MCPCore.success(id: id, result: [String: Any]()))
            }
            if method == LinkFeatures.warmMethod {
                server.warmModel()
                return reply(MCPCore.success(id: id, result: [String: Any]()))
            }
            if method == CaptureOutcome.listMethod {
                return reply(MCPCore.success(id: id, result: ["outcomes": server.outcomes(params["ids"] as? [String] ?? [])]))
            }
            if method == CaptureOutcome.actMethod {
                do {
                    return reply(MCPCore.success(id: id, result: ["message": try await server.actOnOutcome(params, soloAuto: readsSoloAuto)]))
                } catch {
                    return reply(MCPCore.failure(id: id, code: -32602, message: (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription))
                }
            }
            if method == MomentPayload.method {
                do {
                    return reply(MCPCore.success(id: id, result: try await server.keepMoment(params, from: device, soloAuto: readsSoloAuto)))
                } catch {
                    return reply(MCPCore.failure(id: id, code: -32602, message: (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription))
                }
            }
            if method == ConversationSuggestion.listMethod {
                return reply(MCPCore.success(id: id, result: ["suggestions": server.suggestions(for: reads)]))
            }
            if method == ConversationSuggestion.actMethod {
                let result = server.act(on: params["id"] as? String ?? "", action: params["action"] as? String ?? "", agent: params["agent"] as? String ?? "")
                return reply(result.ok ? MCPCore.success(id: id, result: ["message": result.message])
                             : MCPCore.failure(id: id, code: -32602, message: result.message))
            }
            if method == LinkFeatures.decisionMethod {
                do {
                    return reply(MCPCore.success(id: id, result: ["message": try server.decide(params, device: device)]))
                } catch {
                    return reply(MCPCore.failure(id: id, code: -32602, message: (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription))
                }
            }
            if method == ConversationPayload.method {
                do {
                    let kept = try server.keepConversation(params, from: device, soloAuto: readsSoloAuto)
                    return reply(MCPCore.success(id: id, result: ["id": kept.uuidString]))
                } catch {
                    return reply(MCPCore.failure(id: id, code: -32602, message: (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription))
                }
            }
            // Chats with your agents (lane AC1).
            if [LinkFeatures.chatListMethod, LinkFeatures.chatMethod, LinkFeatures.chatSendMethod, LinkFeatures.chatActMethod].contains(method) {
                do {
                    return reply(MCPCore.success(id: id, result: try server.chats(method, params)))
                } catch {
                    return reply(MCPCore.failure(id: id, code: -32602, message: (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription))
                }
            }
            // An agent's sessions, as the Mac's Agents page shows them (lane AC2).
            if [LinkFeatures.sessionListMethod, LinkFeatures.sessionMethod, LinkFeatures.sessionSendMethod, LinkFeatures.sessionActMethod].contains(method) {
                do {
                    return reply(MCPCore.success(id: id, result: try await server.sessions(method, params)))
                } catch {
                    return reply(MCPCore.failure(id: id, code: -32602, message: (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription))
                }
            }
            // The Manager (lane MG1): what you ask it, what it said and changed, and your Undo, Stop, Accept and Dismiss.
            if method == LinkFeatures.managerMethod || method == LinkFeatures.managerActMethod {
                do {
                    let result = method == LinkFeatures.managerMethod ? try server.askManager(params) : ["message": try server.actOnManager(params)]
                    return reply(MCPCore.success(id: id, result: result))
                } catch {
                    return reply(MCPCore.failure(id: id, code: -32602, message: (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription))
                }
            }
            if method == LinkFeatures.managerListMethod {
                return reply(MCPCore.success(id: id, result: server.managerRequests(params)))
            }
            // Ask as it goes, for a phone that reads it and asked for it: before the reply, what's found and the answer so
            // far. Nothing more is sent once the reply is on its way.
            let progress = AskProgressRelay(message, to: self)
            let result = await server.runTool(message, askProgress: progress.map { relay in { relay.send($0, sources: $1, text: $2) } },
                                              doing: readsDoing, momentAgreed: readsMomentAgreed, asksFirst: readsCommentsAskFirst, momentAuto: readsMomentAuto,
                                              soloAuto: readsSoloAuto)
            progress?.finish()
            reply(result)
        }
    }

    /// Whether this phone reads `binders/ask-progress`, from its hello.
    var readsAskProgress: Bool { reads.contains(LinkFeatures.notification(LinkFeatures.askProgressMethod)) }

    /// Whether this phone is told what runs say they're doing in work_streams, from its hello. One that doesn't list it
    /// would keep their words in its saved copy of the reply without showing them.
    var readsDoing: Bool { reads.contains(LinkFeatures.workStreamsDoing) }

    /// Whether this phone sends its yes with a "Binders, …" said in your voice (MomentAgreement), from its hello: list_agents
    /// then says which agents start on their own, and fingerprints them with "starts".
    var readsMomentAgreed: Bool { reads.contains(MomentPayload.agreedFeature) }

    /// Whether this phone asks first before a comment goes to an agent, and names that agent in `to`, from its hello
    /// (`LinkFeatures.commentsAskFirst`). A comment from one that doesn't wakes no agent.
    var readsCommentsAskFirst: Bool { reads.contains(LinkFeatures.commentsAskFirst) }
    /// Whether this phone has Auto (MomentPayload.autoFeature), from its hello: list_agents then says what Auto can do, and
    /// fingerprints an agent with the Mac's yes for Auto with Auto's part.
    var readsMomentAuto: Bool { reads.contains(MomentPayload.autoFeature) }
    /// Whether this phone vouches for a capture in which it heard only you (ConversationPayload.soloFeature, lane Y2), from
    /// its hello: its captures' vouch and its moments' `fromTranscript` and `uncued` are read, it may act on a capture, and
    /// list_agents gives it `solo_start`, `solo` and `auto_fingerprint`.
    var readsSoloAuto: Bool { reads.contains(ConversationPayload.soloFeature) }

    private func reply(_ message: [String: Any]?) {
        if let message { send(message) }
    }

    /// The answer, then the connection closed once it has gone out: closed straight away, the answer could be lost, and
    /// the phone would only see the link go.
    private func replyThenClose(_ message: [String: Any]?) {
        guard !closed, let message, var data = try? JSONSerialization.data(withJSONObject: message) else { return close() }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }
}

/// ask_knowledge as it goes, for the phone that asked (`binders/ask-progress`, LinkAskProgress): a new stage at once, the
/// answer so far at most every quarter second, and nothing once the reply is on its way. Only a phone that reads it and
/// sent a token gets any: iPhone 2.0 sends none.
@MainActor
private final class AskProgressRelay {
    static let interval: Duration = .milliseconds(250)

    private weak var session: LinkSession?
    private let token: String
    private var seq = 0
    private var lastText = ContinuousClock.now - .seconds(1)
    /// The newest text, while it waits for its quarter second.
    private var waiting: String?
    private var timer: Task<Void, Never>?
    private var done = false

    /// Nil unless the message is ask_knowledge with a progress token, from a phone that reads the notification.
    init?(_ message: [String: Any], to session: LinkSession) {
        guard session.readsAskProgress, message["method"] as? String == "tools/call",
              let params = message["params"] as? [String: Any], params["name"] as? String == "ask_knowledge",
              let token = LinkAskProgress.token(in: params["arguments"] as? [String: Any] ?? [:]) else { return nil }
        self.session = session
        self.token = token
    }

    func send(_ stage: AskStage, sources: [[String: Any]]?, text: String) {
        guard !done else { return }
        guard stage == .writing else {
            post(stage, sources: sources, text: nil)
            return
        }
        waiting = text
        let due = lastText + Self.interval
        if ContinuousClock.now >= due {
            flush()
        } else if timer == nil {
            timer = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                self?.flush()
            }
        }
    }

    /// The reply is going: anything still waiting isn't sent, as the reply has all of it.
    func finish() {
        done = true
        timer?.cancel()
        timer = nil
    }

    private func flush() {
        timer = nil
        guard !done, let text = waiting else { return }
        waiting = nil
        lastText = .now
        post(.writing, sources: nil, text: text)
    }

    private func post(_ stage: AskStage, sources: [[String: Any]]?, text: String?) {
        seq += 1
        session?.send(["jsonrpc": "2.0", "method": LinkFeatures.askProgressMethod,
                       "params": LinkAskProgress.params(token: token, seq: seq, stage: stage, sources: sources, text: text)])
    }
}

// MARK: The Manager (lane MG1)

extension LinkServer {
    /// Chats with your agents, from your iPhone (lane AC1): the list (`agent`: one agent's), one chat with its messages
    /// (`id`), your message (`agent`, `text`, `chat?`, `id?` the phone's own for it), or Stop (`id`, `action` "stop").
    fileprivate func chats(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        guard let controller else { throw MCPCore.ToolFailure("Binders is shutting down") }
        let chats = controller.chats
        func uuid(_ key: String) -> UUID? { (params[key] as? String).flatMap(UUID.init(uuidString:)) }
        switch method {
        case LinkFeatures.chatListMethod:
            let agent = (params["agent"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let list = agent.isEmpty ? chats.file.chats : chats.chats(with: agent)
            return ["chats": list.prefix(60).map { $0.jsonObject(messages: false, live: chats.live[$0.id]) }]
        case LinkFeatures.chatMethod:
            guard let id = uuid("id"), let chat = chats.chat(id) else { throw MCPCore.ToolFailure("Binders on this Mac doesn't have that chat.") }
            return chat.jsonObject(messages: true, live: chats.live[id])
        case LinkFeatures.chatSendMethod:
            let agent = (params["agent"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !agent.isEmpty else { throw MCPCore.ToolFailure("Say which agent it's for.") }
            switch chats.send(params["text"] as? String ?? "", to: agent, chat: uuid("chat"), via: "iphone", id: uuid("id")) {
            case .success(let chat): return chat.jsonObject(messages: true, live: chats.live[chat.id])
            case .failure(let failure): throw MCPCore.ToolFailure(failure.why)
            }
        default:
            guard let id = uuid("id"), chats.chat(id) != nil else { throw MCPCore.ToolFailure("Binders on this Mac doesn't have that chat.") }
            guard params["action"] as? String == "stop" else { throw MCPCore.ToolFailure("A chat takes stop.") }
            chats.stop(id)
            return ["message": "Stopped."]
        }
    }

    /// An agent's sessions, from your iPhone (lane AC2): the list (`agent`), one as its terminal (`kind` "card" or "chat",
    /// `id`, `agent`), your words into a card's session (`card`, `text`, `agent`: the one the phone asked you about, `id`:
    /// the phone's own for them), or Stop on a card's run (`card`, `action` "stop").
    fileprivate func sessions(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let controller else { throw MCPCore.ToolFailure("Binders is shutting down") }
        func string(_ key: String) -> String { (params[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch method {
        case LinkFeatures.sessionListMethod:
            return AgentSessionLink.object(try phoneSessions.list(agent: string("agent"), controller: controller))
        case LinkFeatures.sessionMethod:
            let agent = string("agent")
            return AgentSessionLink.object(try await phoneSessions.shown(kind: string("kind"), id: string("id"), agent: agent.isEmpty ? nil : agent, controller: controller))
        case LinkFeatures.sessionSendMethod:
            guard !string("agent").isEmpty else { throw MCPCore.ToolFailure("Say which agent it's for.") }
            return ["message": try phoneSessions.send(params["text"] as? String ?? "", card: string("card"), agent: string("agent"),
                                                      id: UUID(uuidString: string("id")), controller: controller)]
        default:
            return ["message": try phoneSessions.act(string("action"), card: string("card"), controller: controller)]
        }
    }

    /// Something you typed to the Manager on your iPhone, or a tidy you asked for there: it goes to the Manager at once,
    /// as a request from you. `id`, the phone's own, makes one sent twice a single request. `thread`: the request whose
    /// conversation it goes on. `kind` "tidy" with `binder` (an id or a name; none: every binder). `agent`: the Manager the
    /// iPhone asked you about first; one given the role since refuses it.
    fileprivate func askManager(_ params: [String: Any]) throws -> [String: Any] {
        guard let controller else { throw MCPCore.ToolFailure("Binders is shutting down") }
        let manager = controller.manager
        if let given = (params["id"] as? String).flatMap(UUID.init(uuidString:)), let earlier = manager.request(given) {
            return earlier.jsonObject
        }
        let text = (params["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = ManagerRequest.Kind(rawValue: params["kind"] as? String ?? "") ?? .ask
        // The Manager the iPhone asked you about, or asked of: it runs only on that one.
        let askedOf = (params["agent"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        if let askedOf, let current = manager.agent?.name, askedOf != current {
            throw MCPCore.ToolFailure("The Manager is \(current) now, not \(askedOf). Look again, and ask again.")
        }
        let request: ManagerRequest
        switch kind {
        case .tidy:
            var binder: UUID?
            if let named = (params["binder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
                guard let found = Store.shared.binders(includeArchived: false).first(where: { $0.id.uuidString == named || $0.name.localizedCaseInsensitiveCompare(named) == .orderedSame }) else {
                    throw MCPCore.ToolFailure("No binder named “\(named)”.")
                }
                binder = found.id
            }
            request = manager.tidy(binder: binder, from: .iphone, id: (params["id"] as? String).flatMap(UUID.init(uuidString:)), askedOf: askedOf)
        case .ask:
            guard !text.isEmpty else { throw MCPCore.ToolFailure("Say what you'd like the Manager to do.") }
            request = manager.ask(text, thread: (params["thread"] as? String).flatMap(UUID.init(uuidString:)), from: .iphone,
                                  id: (params["id"] as? String).flatMap(UUID.init(uuidString:)), askedOf: askedOf)
        }
        return request.jsonObject
    }

    /// What you asked the Manager, newest first (`limit`, at most 50; or the `ids` asked after, or one `thread`), the note
    /// edits it suggested that wait for you, and who has the role.
    fileprivate func managerRequests(_ params: [String: Any]) -> [String: Any] {
        guard let controller else { return ["requests": [Any](), "suggestions": [Any]()] }
        let manager = controller.manager
        var requests = manager.requests
        if let ids = params["ids"] as? [String] {
            let wanted = Set(ids.compactMap(UUID.init(uuidString:)))
            requests = requests.filter { wanted.contains($0.id) }
        } else if let thread = (params["thread"] as? String).flatMap(UUID.init(uuidString:)) {
            requests = manager.thread(thread)
        }
        let limit = min(max(1, params["limit"] as? Int ?? 20), 50)
        var reply: [String: Any] = ["requests": requests.suffix(limit).reversed().map(\.jsonObject),
                                    "suggestions": manager.waitingSuggestions.map { $0.jsonObject(current: Store.shared.note($0.note)?.text) }]
        if let agent = manager.agent {
            reply["agent"] = agent.name
            // A local model stays on this Mac; anything else, the iPhone asks you about first (its list_agents entry).
            if case .localModel = agent.wake { reply["local"] = true }
        }
        if let problem = manager.problem { reply["problem"] = problem }
        return reply
    }

    /// Stop or Undo on a request (`id`), Accept or Dismiss on a suggested note edit (`suggestion`).
    fileprivate func actOnManager(_ params: [String: Any]) throws -> String {
        guard let controller else { throw MCPCore.ToolFailure("Binders is shutting down") }
        let manager = controller.manager
        let action = params["action"] as? String ?? ""
        if let suggestion = (params["suggestion"] as? String).flatMap(UUID.init(uuidString:)) {
            switch action {
            case "accept":
                switch manager.accept(suggestion) {
                case .success(let message): return message
                case .failure(let failure): throw MCPCore.ToolFailure(failure.why)
                }
            case "dismiss":
                manager.dismiss(suggestion)
                return "Dismissed."
            default:
                throw MCPCore.ToolFailure("A suggestion takes accept or dismiss")
            }
        }
        guard let id = (params["id"] as? String).flatMap(UUID.init(uuidString:)), manager.request(id) != nil else {
            throw MCPCore.ToolFailure("Binders on this Mac doesn't know that one")
        }
        switch action {
        case "stop":
            manager.stop(id)
            return "Stopped."
        case "undo":
            return manager.undo(id)
        default:
            throw MCPCore.ToolFailure("A request takes stop or undo")
        }
    }
}
