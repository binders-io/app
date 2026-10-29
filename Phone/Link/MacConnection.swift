import BindersKit
import CryptoKit
import Foundation
import Network
import Observation
import OSLog
import Security
import UIKit

/// How long the iPhone waits for its Mac, by what it asks, in seconds: one table, so a screen never hangs on a Mac that
/// has gone quiet, and nothing gives up just before its answer comes. A request that times out has the link checked.
enum LinkTimeouts {
    /// Opening a connection to one of the Mac's addresses, from that address's own start.
    static let connect: TimeInterval = 4
    /// Each step of saying hello on a connection that opened: a Mac that doesn't answer is passed over for the next
    /// address rather than kept "Connecting…".
    static let handshake: TimeInterval = 10
    /// Between starting one address and the next, when the one before hasn't failed: Bonjour and the last good one start
    /// together, the rest this far apart.
    static let stagger: TimeInterval = 0.25
    /// The quick words that check a link gone quiet: a busy Mac gets the second, longer one.
    static let checks: [TimeInterval] = [2, 5]
    /// The word to the Mac while someone talks near the phone.
    static let ping: TimeInterval = 3
    /// A screen reading from the Mac: a list, a card, a note, a meeting. Past it, the screen keeps last time's copy.
    static let read: TimeInterval = 8
    /// A change made on a screen: a card moved, a to-do ticked, a comment.
    static let change: TimeInterval = 15
    /// Ask: past the Mac's own limit on the whole answer (180 s, its search included), so the iPhone never gives up just
    /// before the answer comes.
    static let ask: TimeInterval = 200
    /// A note, a to-do or an answer from the outbox. Not answered in time, it waits for the next run.
    static let send: TimeInterval = 20
    /// A dictation from the outbox, its words only.
    static let dictation: TimeInterval = 15
    /// A moment from the outbox: the Mac decides what it is before it answers.
    static let moment: TimeInterval = 45
    /// Siri's moment, said now, and how long it waits for the link first. Past them it's kept in the outbox.
    static let momentNow: TimeInterval = 20
    static let momentLink: TimeInterval = 6
    /// A conversation, or one part of a long one: the Mac files it before it answers.
    static let conversation: TimeInterval = 60
    /// Anything else asked from wherever the app is (request()): an outcome's Undo, a suggestion's Add.
    static let errand: TimeInterval = 30
    /// A dictation's whole cleanup: the wait for the link and the Mac's model, then this iPhone's model with what's left.
    /// Past it, Binders' rules, which take no time. Of it, the wait for the link takes at most `cleanupLink`.
    static let cleanup: TimeInterval = 4
    static let cleanupLink: TimeInterval = 2

    /// The Mac's tools that only read.
    private static let reads: Set<String> = ["work_streams", "search_knowledge", "recent_dictations"]

    /// How long one of the Mac's tools may take: Ask, a read, or a change.
    static func tool(_ name: String) -> TimeInterval {
        if name == "ask_knowledge" { return ask }
        return name.hasPrefix("list_") || name.hasPrefix("get_") || reads.contains(name) ? read : change
    }

    /// How long a request may take: a tool by its name, the Mac's lists of outcomes and suggestions as reads, the rest as
    /// errands.
    static func request(_ method: String, _ params: [String: Any]) -> TimeInterval {
        if method == "tools/call", let name = params["name"] as? String { return tool(name) }
        return [CaptureOutcome.listMethod, ConversationSuggestion.listMethod, LinkFeatures.sessionListMethod].contains(method) ? read : errand
    }
}

/// The phone's side of the link: pairing, staying connected (every address it knows, tried together: Bonjour at home,
/// the last good one, what you added, what the Mac said at its last hello, what worked before and the pairing code's),
/// calling the Mac's tools, and turning the Mac's change notifications into refreshes.
@MainActor
@Observable
final class MacConnection {
    enum State: Equatable {
        case unpaired
        case connecting
        case connected
        case offline(String)
    }

    private(set) var state: State = .unpaired {
        // When this iPhone was last in touch with its Mac, kept as the link comes up and as it goes.
        didSet { if (oldValue == .connected) != (state == .connected) { noteSeen() } }
    }
    private(set) var mac: PairedMac?
    /// The address in use now (a LinkCandidate id), and what Bonjour reached when that's Bonjour. Nil while not connected.
    private(set) var inUse: String?
    private(set) var reachedHost: String?
    /// What became of each address the last dial that failed tried: kept while the next one runs ("Trying again. Last
    /// time: …"), cleared once one connects.
    private(set) var lastAttempts: [LinkDial.Attempt] = []
    /// When this iPhone was last connected to its Mac: said when you tap the status pill. Nil before the first time.
    private(set) var lastSeen: Date? = UserDefaults.standard.object(forKey: MacConnection.lastSeenKey) as? Date
    /// A link that went quiet is being checked: the status pill says it's connecting if that takes more than a moment.
    private(set) var checkingLink = false
    private(set) var pairingError: String?
    /// Bumped per kind ("todos", "notes", "meetings"…) when the Mac says something changed; screens reload on it.
    private(set) var revisions: [String: Int] = [:]
    /// Notes and to-dos saved while the Mac was out of reach, sent when it's back.
    private(set) var outbox: [PendingSave] = Outbox.load()
    /// What the Mac said it takes besides the tools, at hello: "conversation". Remembered for when it's out of reach.
    private(set) var macFeatures: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "macFeatures") ?? []) {
        // A Mac newly taking moments (or no longer): capture starts or stops listening for them now, not next time.
        didSet { if oldValue.contains(MomentPayload.feature) != macFeatures.contains(MomentPayload.feature) { CaptureSession.shared.momentsChanged() } }
    }
    /// The Mac has said it takes the conversations All-day capture hears.
    var takesConversations: Bool { macFeatures.contains(ConversationPayload.feature) }
    /// The Mac offers cards and answers once it has written a conversation up.
    var hasSuggestions: Bool { macFeatures.contains(ConversationSuggestion.feature) }
    /// The Mac says what became of each capture.
    var hasOutcomes: Bool { macFeatures.contains(CaptureOutcome.feature) }
    /// The Mac reads what you say to yourself (moments).
    var takesMoments: Bool { macFeatures.contains(MomentPayload.feature) }
    /// The Mac has folders inside binders (LinkFeatures.folders): list_folders, and `folder` on list_notes and add_note.
    var hasFolders: Bool { macFeatures.contains(LinkFeatures.folders) }
    /// Told when something changed on the Mac that's worth asking about again: a conversation written up.
    @ObservationIgnored var onMeetingsChanged: (() -> Void)?
    /// Told when a board changed on the Mac, as when an agent asks a question.
    @ObservationIgnored var onTasksChanged: (() -> Void)?
    /// Told when an agent asks your approval on the Mac (`LinkFeatures.approvalMethod`): who asks, and what, in Lock Screen
    /// words.
    @ObservationIgnored var onApproval: ((AgentApproval.Notice) -> Void)?
    /// Stay connected in the background while All-day capture listens, so what the Mac offers about a conversation
    /// arrives while you're out.
    @ObservationIgnored var keepsConnected = false {
        didSet { held(keepsConnected, was: oldValue) }
    }
    /// Told when a conversation has reached the Mac (every part of it), so All-day capture can mark it sent.
    @ObservationIgnored var onConversationSent: ((UUID) -> Void)?
    /// Told when the Mac refused one (it couldn't read it), so it isn't lost without a word.
    @ObservationIgnored var onConversationRefused: ((UUID) -> Void)?
    /// Told when an answer to an agent's question has gone to the Mac (true) or been turned down (false), with its card.
    @ObservationIgnored var onAnswerSettled: ((String, Bool) -> Void)?
    /// Told when a moment has reached the Mac (true), with what it made of it when it said in time, or was turned down.
    @ObservationIgnored var onMomentSettled: ((UUID, CaptureOutcome?, Bool) -> Void)?
    /// The kinds that have graduated, for a moment kept in Auto or Add at Once that now goes as Suggest
    /// (MomentModes.asSent's `addsNow`): installed at launch (CaptureWiring.connect), before the first connect. Missing,
    /// such a moment is offered, which only ever asks more.
    @ObservationIgnored var graduatedKinds: (@MainActor () -> [String]?)?
    /// What the Mac said of a moment as it took it, until the moment leaves the outbox.
    @ObservationIgnored private var momentOutcomes: [UUID: CaptureOutcome] = [:]
    /// Told when a Give to kept for the Mac has gone (true) or been turned down (false), with what the Mac said.
    @ObservationIgnored var onHandOffSettled: ((PendingSave, Bool, String?) -> Void)?
    /// What the Mac said to a Give to, or why it turned it down, until it's settled.
    @ObservationIgnored private var handOffReplies: [UUID: String] = [:]
    /// Give to's being tried at once: in the outbox meanwhile, so a try cut short doesn't lose them, but passed over by its
    /// runs. Watched: one isn't shown as waiting for the Mac while it's tried (givingLater).
    private var givingNow: Set<UUID> = []

    @ObservationIgnored private var client: LinkClient?
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var lastProbe = Date.distantPast
    @ObservationIgnored private var lastWarm = Date.distantPast
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Tries in a row that didn't connect. Watched: the status pill says offline, rather than connecting, after one.
    private var failures = 0
    @ObservationIgnored private let browser = MacBrowser()
    /// The Macs Bonjour sees on this network, by name. Watched: Your Mac's Bonjour row comes and goes with them.
    private(set) var bonjourNames: Set<String> = []
    @ObservationIgnored var isActive = true
    /// Stay connected in the background, while the microphone is on for the keyboard, so its dictations are cleaned up by
    /// the Mac. Turned on after the app had let go in the background, it connects again.
    @ObservationIgnored var holdOpen = false {
        didSet { held(holdOpen, was: oldValue) }
    }
    @ObservationIgnored private var lastAttempt = Date.distantPast
    /// Background work waiting on the Mac (All-day capture sending what it processed): stay connected until it's done.
    @ObservationIgnored private var errands = 0
    private var isHeld: Bool { holdOpen || keepsConnected || errands > 0 }
    /// Just gone to the background: the link stays up a little while, in case you're straight back.
    @ObservationIgnored private var lingering: Task<Void, Never>?
    @ObservationIgnored private var lingerTask: UIBackgroundTaskIdentifier = .invalid
    static let linger: TimeInterval = 25
    @ObservationIgnored private var sendingOutbox = false
    @ObservationIgnored private var outboxAgain = false
    /// Answers being sent from their notifications, and those of them the Mac turned down.
    @ObservationIgnored private var answering: Set<UUID> = []
    @ObservationIgnored private var refusedAnswers: Set<UUID> = []
    /// An address just tested that answered: the next dial starts it at once.
    @ObservationIgnored private var preferred: String?
    /// The network changed while a dial ran: one more, straight after.
    @ObservationIgnored private var dialAgain = false
    /// The Mac's new addresses, heard on a link still saying hello: taken if that link wins.
    @ObservationIgnored private var heardDuringHandshake: (link: LinkClient, list: [LinkAddress])?
    @ObservationIgnored private var network: NetworkWatch?

    init() {
        mac = Self.loadMac()
        state = mac == nil ? .unpaired : .offline(Self.notConnectedYet)
        let network = NetworkWatch()
        network.onChange = { [weak self] now, was in self?.networkChanged(now, was: was) }
        self.network = network
        browser.onChange = { [weak self] in
            Task { @MainActor in self?.bonjourChanged() }
        }
        // What it found before it could say so.
        bonjourChanged()
    }

    /// Why it's offline as the app opens, before the first try.
    static let notConnectedYet = "Not connected yet"

    var isConnected: Bool { state == .connected }

    /// What the status pill says: connecting while the link is on its way (or a Mac gone quiet is checked), offline once
    /// a try has failed, until the link is back or you retry. Nil while connected, and without a Mac.
    enum LinkStatus: Equatable { case connecting, offline }

    var linkStatus: LinkStatus? {
        switch state {
        case .unpaired: nil
        case .connected: checkingLink ? .connecting : nil
        case .connecting: failures == 0 ? .connecting : .offline
        // Not tried yet, as the app opens or comes back to the front: on its way.
        case .offline(let reason): [Self.notConnectedYet, Self.pausedInBackground].contains(reason) && failures == 0 ? .connecting : .offline
        }
    }

    /// Why the Mac is out of reach, when it's something to act on (a missing key, a Mac that turned this iPhone away)
    /// rather than only not being there.
    var offlineReason: String? {
        guard case .offline(let reason) = state, let mac else { return nil }
        let plain = [Self.notConnectedYet, Self.pausedInBackground, "Can't reach \(mac.name)", "Lost the connection to \(mac.name)"]
        return plain.contains(reason) ? nil : reason
    }

    /// Retry, from the status pill: a try now, with the waits between tries starting over. A try already on its way
    /// carries on, and the pill says it's connecting.
    func retryNow() {
        guard mac != nil, client == nil else { return }
        failures = 0
        guard !connecting else { return }
        retry?.cancel()
        Task { await connect() }
    }

    private static let lastSeenKey = "macLastSeen"
    private static let pausedInBackground = "Paused in the background"

    private func noteSeen() {
        let now = Date()
        lastSeen = now
        UserDefaults.standard.set(now, forKey: Self.lastSeenKey)
    }

    private func forgetSeen() {
        lastSeen = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSeenKey)
    }

    /// A screen's reload key: changes when its kind of data, or everything, changed.
    func revision(_ kind: String) -> Int { revisions[kind, default: 0] + revisions["all", default: 0] }

    // MARK: Pairing

    func pair(with url: URL) async {
        guard let pairing = LinkPairing(url: url) else {
            pairingError = "That isn't a Binders pairing link."
            return
        }
        pairingError = nil
        lastAttempts = []
        disconnect()
        state = .connecting
        do {
            let result = try await LinkClient.pair(pairing, deviceName: UIDevice.current.name)
            try Keychain.save(result.key.withUnsafeBytes { Data($0) }, account: result.device.uuidString)
            if let old = mac, old.device != result.device { Keychain.delete(account: old.device.uuidString) }
            var paired = PairedMac(device: result.device, name: pairing.name,
                                   hosts: pairing.addresses.compactMap { LinkClient.split($0)?.host }, port: result.port, lastHost: result.host)
            // The same Mac paired again: what you added and what worked still hold.
            if let old = mac, old.name == pairing.name { paired.carryOver(from: old) }
            Self.saveMac(paired)
            mac = paired
            Cache.clear()
            forgetSeen()
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
        lastAttempts = []
        state = .unpaired
        Cache.clear()
        forgetSeen()
    }

    // MARK: Staying connected

    /// Tries every address this iPhone knows for its Mac together (LinkDial): Bonjour and the last good one at once, the
    /// rest a quarter second apart; the first that answers says hello, and the rest are closed. Offline, it says what
    /// was tried.
    func connect() async {
        guard let mac, client == nil, !connecting else { return }
        guard let keyData = Keychain.load(account: mac.device.uuidString) else {
            lastAttempts = []
            inUse = nil
            reachedHost = nil
            state = .offline("This iPhone's key is missing. Pair again.")
            return
        }
        connecting = true
        lastAttempt = Date()
        dialAgain = false
        heardDuringHandshake = nil
        defer { connecting = false }
        retry?.cancel()
        state = .connecting
        let key = SymmetricKey(data: keyData), device = mac.device, phoneName = UIDevice.current.name
        let bonjour = browser.endpoint(named: mac.name)
        let candidates = mac.candidates(bonjour: bonjour != nil, preferred: preferred)
        preferred = nil
        let result = await LinkDial.dial(candidates, bonjour: bonjour, identity: device.uuidString, key: key,
                                         connect: LinkTimeouts.connect, stagger: LinkTimeouts.stagger,
                                         handshake: LinkTimeouts.handshake) { [weak self] link, nonce in
            let hello = try await link.prove(nonce, device: device, key: key, name: phoneName, features: LinkFeatures.thisPhone,
                                             timeout: LinkTimeouts.handshake)
            self?.listen(to: link)
            _ = try await link.request("binders/subscribe", timeout: LinkTimeouts.handshake)
            return hello
        }
        // Unpaired, or paired again, meanwhile: this dial was for the Mac before. One for the Mac paired now starts from a
        // task, which runs once this has returned.
        guard let now = self.mac, now.device == device else {
            result.client?.close()
            heardDuringHandshake = nil
            if self.mac != nil, mayDial { dialAfterThis() }
            return
        }
        guard let link = result.client, let winner = result.winner else {
            heardDuringHandshake = nil
            lastAttempts = result.attempts
            inUse = nil
            reachedHost = nil
            let forgot = LinkDial.macForgotThisPhone(result.attempts)
            state = .offline(result.rejection ?? (forgot ? "\(now.name) doesn't know this iPhone any more. Pair again." : "Can't reach \(now.name)"))
            if dialAgain, mayDial {
                dialAgain = false
                // A try has failed, so the status pill says offline while the next one runs, as after a wait.
                failures += 1
                dialAfterThis()
            } else {
                scheduleRetry()
            }
            return
        }
        let featuresBefore = macFeatures
        macFeatures = Set(result.reply["features"] as? [String] ?? [])
        UserDefaults.standard.set(Array(macFeatures), forKey: "macFeatures")
        // A Mac that has just learnt Auto, with Auto chosen here: a word, once, that opens the sheet.
        MomentCenter.shared.macFeaturesChanged(from: featuresBefore, to: macFeatures)
        // Where the Mac can be reached, as it said at this hello: a Mac before 0.8.1 says nothing, and what it said last
        // time stays.
        if macFeatures.contains(LinkFeatures.addresses), let list = LinkAddress.list(from: result.reply["addresses"]) { learn(list) }
        client = link
        failures = 0
        lastAttempts = []
        inUse = winner.id
        reachedHost = link.remoteHost
        state = .connected
        // A notice heard during the handshake went to a link that wasn't in use yet.
        if let heard = heardDuringHandshake, heard.link === link { learn(heard.list) }
        heardDuringHandshake = nil
        // Closed during the handshake too: that went unheard as well.
        if link.isClosed { return closed(link) }
        link.onTimeout { [weak self] in
            Task { @MainActor in await self?.check(link) }
        }
        beat(link)
        if var paired = self.mac, paired.used(winner) {
            self.mac = paired
            Self.saveMac(paired)
        }
        changed(["all"])
        await sendOutbox()
        // Stop, Undo and Not Me on what Auto handed over, kept while the Mac was out of reach (their own queue).
        await MomentCenter.shared.sendKeptActions()
    }

    /// The Mac's notifications on a link, and its closing, each taken on the main actor. Set while it says hello, so a
    /// notice the Mac sends before its subscribe reply isn't missed.
    nonisolated private func listen(to link: LinkClient) {
        link.onNotification { [weak self] message in
            let method = message["method"] as? String
            let params = message["params"] as? [String: Any] ?? [:]
            // An agent asks your approval: it rings now, without waiting for the board's change to be read.
            if method == LinkFeatures.approvalMethod {
                guard let notice = AgentApproval.Notice(params: params) else { return }
                Task { @MainActor in self?.onApproval?(notice) }
                return
            }
            // Ask's answer as the Mac writes it, for the screen that asked (AskStreams).
            if method == LinkFeatures.askProgressMethod {
                if let update = LinkAskProgress.Update(params: params) {
                    Task { @MainActor in AskStreams.shared.received(update) }
                }
                return
            }
            // Where the Mac can be reached now: the whole new list.
            if method == LinkFeatures.addressesMethod {
                guard let list = LinkAddress.list(from: params["addresses"]) else { return }
                Task { @MainActor in self?.addressesHeard(list, on: link) }
                return
            }
            // Only what this phone listed in its hello comes, but a notification it doesn't know is let go.
            guard method == LinkFeatures.changed else { return }
            let kinds = (params["kinds"] as? [String]) ?? ["all"]
            Task { @MainActor in self?.changed(kinds) }
        }
        link.onClose { [weak self] in
            Task { @MainActor in self?.closed(link) }
        }
    }

    /// The Mac's addresses changed: taken from the link in use, or kept while a link says hello, for if it wins.
    private func addressesHeard(_ list: [LinkAddress], on link: LinkClient) {
        if link === client {
            learn(list)
        } else if connecting {
            heardDuringHandshake = (link, list)
        }
    }

    /// What the Mac says its addresses are, kept when it changed.
    private func learn(_ list: [LinkAddress]) {
        guard var paired = mac, paired.learn(list) else { return }
        mac = paired
        Self.saveMac(paired)
    }

    /// A dial straight after this one, from a task: it starts once the dial that asked for it has returned.
    private func dialAfterThis() {
        retry = Task { [weak self] in
            self?.retry = nil
            await self?.connect()
        }
    }

    /// Whether the app may start a dial of its own straight after another, or for a Mac paired again during a dial: in
    /// front, or with capture, the keyboard or an errand holding the link. A background launch with no window is
    /// neither, though `isActive` starts true there.
    private var mayDial: Bool { isHeld || (isActive && UIApplication.shared.applicationState != .background) }

    /// Open in front, which a network change needs before it dials: never in the background, held or not, nor in a
    /// background launch.
    private var inFront: Bool { isActive && UIApplication.shared.applicationState == .active }

    // MARK: Addresses

    /// Every address this iPhone knows for its Mac, in the order they're tried, for Your Mac: Bonjour while the browser
    /// sees the Mac (watched, so the row comes and goes while Your Mac is open), or while it's the one in use.
    var addressRows: [LinkCandidate] {
        guard let mac else { return [] }
        return mac.candidates(bonjour: bonjourNames.contains(mac.name) || inUse == LinkCandidate.bonjourID, limit: nil)
    }

    /// What the browser sees now, taken on the main actor.
    private func bonjourChanged() {
        let names = browser.names
        if names != bonjourNames { bonjourNames = names }
    }

    /// Opens one address and asks for a challenge: the TLS key proves it's this Mac, the answer that Binders is there. No
    /// hello, so the Mac doesn't count it as a connection. One that answers while offline is tried first, now.
    func test(_ id: String) async -> LinkDial.Outcome {
        guard let mac, let keyData = Keychain.load(account: mac.device.uuidString) else { return .failed }
        let bonjour = browser.endpoint(named: mac.name)
        guard var candidate = mac.candidates(bonjour: bonjour != nil, limit: nil).first(where: { $0.id == id }) else { return .notFound }
        candidate.atOnce = true
        let result = await LinkDial.dial([candidate], bonjour: bonjour, identity: mac.device.uuidString, key: SymmetricKey(data: keyData),
                                         connect: LinkTimeouts.connect, stagger: 0, handshake: LinkTimeouts.handshake, prove: nil)
        result.client?.close()
        let outcome: LinkDial.Outcome = result.winner != nil ? .answered : result.attempts.first?.outcome ?? .failed
        if outcome == .answered, client == nil, self.mac?.device == mac.device {
            preferred = id
            retryNow()
        }
        return outcome
    }

    /// What became of Add an Address: its id, or why not.
    enum AddressAdded: Equatable {
        case added(String)
        case refused(String)
    }

    /// An address you typed, kept on this iPhone: tried with the rest from now on, whatever the Mac says.
    func addAddress(_ text: String) -> AddressAdded {
        guard var paired = mac else { return .refused("Pair with your Mac first.") }
        if let problem = paired.add(text) { return .refused(problem.words(port: paired.port)) }
        mac = paired
        Self.saveMac(paired)
        return .added(paired.id(ofTyped: text) ?? "")
    }

    /// Keep on This iPhone, on an address the Mac listed or the pairing code had: it becomes yours, or why not (eight
    /// added already). Nil when there's nothing to keep.
    @discardableResult
    func keep(_ id: String) -> AddressAdded? {
        guard let row = addressRows.first(where: { $0.id == id }), row.host != nil, !row.addedHere else { return nil }
        return addAddress(row.text)
    }

    /// Remove, on an address you added or one that's only there because it worked.
    func removeAddress(_ id: String) {
        guard var paired = mac, let row = addressRows.first(where: { $0.id == id }) else { return }
        if row.addedHere {
            paired.removeAdded(id)
        } else if row.workedOnly {
            paired.forget(id)
        } else {
            return
        }
        mac = paired
        Self.saveMac(paired)
    }

    /// The network changed (settled 1 s): `now`, and the update before it. Only while the app is open in front: in the
    /// background, a link something holds comes back on the waits between tries, or once a check finds it gone, and back
    /// in front the app checks or connects anyway. Offline, any update may be the way back, as a VPN coming up can show
    /// only as some change, even one LinkNetwork doesn't keep: a dial now, at most one every 3 s, the waits between tries
    /// left as they were. Connected, a new route has the link checked, or dropped and dialled again when its own path went.
    private func networkChanged(_ now: LinkNetwork, was: LinkNetwork) {
        guard mac != nil, inFront, now.reachable else { return }
        if let client {
            guard now.gainsRoute(over: was) else { return }
            // The link's own path went with the old network: dial now, rather than a check that takes 7 s to time out.
            if !client.isViable || now.lost(client.interfaceName, since: was) {
                self.client = nil
                client.close()
                inUse = nil
                reachedHost = nil
                Task { await connect() }
                return
            }
            // A request waiting has its own timeout: the heartbeat leaves such a link alone too.
            guard !client.isWaitingForReply else { return }
            Task { await check(client) }
            return
        }
        if connecting {
            dialAgain = true
            return
        }
        let wait = max(0, 3 - Date().timeIntervalSince(lastAttempt))
        retry?.cancel()
        retry = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.retry = nil
            await self?.connect()
        }
    }

    func disconnect() {
        retry?.cancel()
        retry = nil
        client?.close()
        client = nil
        inUse = nil
        reachedHost = nil
    }

    /// While nothing else is said, a word now and then shows the Mac still hears this iPhone: a Mac that went to sleep
    /// doesn't say goodbye, and TCP alone takes about ten minutes to notice. After 10 s of quiet in front; after a minute in
    /// the background, where capture or the keyboard holds the link and speech brings a quicker word; never while
    /// lingering, which lets go soon anyway. A request still waiting has its own timeout. Nothing cancels the loop: it ends
    /// once its link isn't the one in use.
    private func beat(_ link: LinkClient) {
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard let self, link === self.client else { return }
                let quiet: TimeInterval = UIApplication.shared.applicationState == .background ? 60 : 10
                guard self.lingering == nil, link.quietFor >= quiet else { continue }
                await self.check(link)
            }
        }
    }

    /// Someone is talking near the phone. A quick word to the Mac, at most every 30 seconds, notices a Mac that went to
    /// sleep before the sentence ends; every two minutes it's binders/warm, so the Mac loads its model for the write-up
    /// (only a Mac that takes it). With the link down while capture holds it, it tries again now rather than waiting.
    func warm(now: Date = Date()) {
        guard let client else {
            if isHeld, mac != nil, !connecting, now.timeIntervalSince(lastAttempt) > 10 { Task { await connect() } }
            return
        }
        guard now.timeIntervalSince(lastProbe) > 30 else { return }
        lastProbe = now
        let warming = macFeatures.contains(LinkFeatures.warm) && now.timeIntervalSince(lastWarm) > 120
        if warming { lastWarm = now }
        // Unanswered in time, the link is checked (onTimeout).
        Task { _ = try? await client.request(warming ? LinkFeatures.warmMethod : "ping", timeout: LinkTimeouts.ping) }
    }

    /// Foreground: connect, or check that the link still up works. Background: keep the link for a little while, in case
    /// you're straight back, then let go; iOS would suspend the connection anyway.
    func sceneChanged(active: Bool) {
        if active {
            stopLingering()
            isActive = true
            if let client { Task { await check(client) } } else { Task { await connect() } }
            return
        }
        // An app closed from the app switcher goes without a word: the time it was last in touch is kept now.
        if isConnected { noteSeen() }
        guard !isHeld else { return }
        // Nothing reconnects from the background.
        isActive = false
        guard lingering == nil else { return }
        guard client != nil else { return letGo() }
        lingerTask = UIApplication.shared.beginBackgroundTask(withName: "Binders link") { [weak self] in
            MainActor.assumeIsolated { self?.letGo() }
        }
        lingering = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.linger))
            guard !Task.isCancelled else { return }
            self?.letGo()
        }
    }

    /// Lets go of the link in the background, once nothing there needs it. Only in the background: Control Center or a
    /// notification pulled down leaves the app inactive, still on screen.
    private func letGo() {
        lingering?.cancel()
        lingering = nil
        if !isHeld, UIApplication.shared.applicationState == .background {
            isActive = false
            disconnect()
            if mac != nil { state = .offline(Self.pausedInBackground) }
        }
        endLingerTask()
    }

    /// A hold began (capture listening, the keyboard's microphone): connect, even from the background, and keep a link
    /// that was about to go. A hold that ends in the background lets go as leaving the app does, rather than leave a
    /// suspended app with its connection open.
    private func held(_ now: Bool, was before: Bool) {
        guard now != before else { return }
        if now {
            guard mac != nil else { return }
            stopLingering()
            isActive = true
            if client == nil { Task { await connect() } }
        } else if UIApplication.shared.applicationState == .background {
            sceneChanged(active: false)
        }
    }

    /// From an errand's end: in the background, let go as leaving the app does.
    private func errandDone() {
        if UIApplication.shared.applicationState == .background { sceneChanged(active: false) }
    }

    private func stopLingering() {
        lingering?.cancel()
        lingering = nil
        endLingerTask()
    }

    private func endLingerTask() {
        guard lingerTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(lingerTask)
        lingerTask = .invalid
    }

    /// Back in front with the link still up: a quick word shows whether the Mac still hears it, as a Mac that went to
    /// sleep doesn't say goodbye. A busy Mac gets a second, longer try; without an answer, it connects again.
    private func check(_ link: LinkClient) async {
        guard !checking else { return }
        checking = true
        checkingLink = true
        defer {
            checking = false
            checkingLink = false
        }
        for timeout in LinkTimeouts.checks {
            do {
                _ = try await link.request("binders/subscribe", timeout: timeout)
                return
            } catch LinkClient.Failure.rejected {
                // It answered.
                return
            } catch LinkClient.Failure.timedOut {
                continue
            } catch {
                break
            }
        }
        guard link === client else { return }
        client = nil
        inUse = nil
        reachedHost = nil
        link.close()
        // On the way out (lingering in the background), let go rather than connect again from there.
        guard isActive || isHeld else {
            state = .offline("Lost the connection to \(mac?.name ?? "the Mac")")
            return letGo()
        }
        await connect()
    }

    private func closed(_ link: LinkClient) {
        guard link === client else { return }
        client = nil
        inUse = nil
        reachedHost = nil
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
            // Not the task in use any more, so the dial never cancels the task it runs in.
            self?.retry = nil
            await self?.connect()
        }
    }

    private func changed(_ kinds: [String]) {
        for kind in kinds { revisions[kind, default: 0] += 1 }
        // Captures are written up as meetings; moments are kept as dictations.
        if kinds.contains("meetings") || kinds.contains("dictations") || kinds.contains("all") { onMeetingsChanged?() }
        if kinds.contains("tasks") || kinds.contains("all") { onTasksChanged?() }
    }

    /// A request to the Mac from wherever the app is: connects for it in the background, and lets go after. Nil when the
    /// Mac can't be reached. It waits as long as LinkTimeouts gives its kind (Ask, through "tools/call", gets Ask's).
    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> Any? {
        errands += 1
        defer {
            errands -= 1
            errandDone()
        }
        if client == nil, mac != nil { Task { await connect() } }
        guard await ready(), let client else { return nil }
        return try await client.request(method, params, timeout: LinkTimeouts.request(method, params))
    }

    // MARK: Dictation

    /// The Mac's cleanup of what was dictated here (its model, dictionary and snippets), within `budget`: waiting for the
    /// link takes at most LinkTimeouts.cleanupLink of it, and the Mac's answer has the rest. Nil when the Mac isn't reached
    /// or doesn't answer in time, or is too old to know how: the iPhone then tidies it up itself with what's left.
    func format(_ text: String, within budget: TimeBudget) async -> (text: String, model: String)? {
        guard await ready(within: budget.left(atMost: LinkTimeouts.cleanupLink)), let client else { return nil }
        let left = budget.left
        guard left > 0,
              let result = try? await client.request("binders/format", ["text": text], timeout: left) as? [String: Any],
              let cleaned = result["text"] as? String else { return nil }
        return (cleaned, result["model"] as? String ?? "")
    }

    /// Saves a note ("add_note") or a to-do ("add_todo") on the Mac, or keeps it here until the Mac is back. True when it
    /// went straight to the Mac. `folder`: a note's folder's id, in that binder; one that's gone when it reaches the Mac
    /// puts the note at the binder's top.
    @discardableResult
    func save(_ tool: String, text: String, binder: String?, folder: String? = nil) async -> Bool {
        await deliver(PendingSave(id: UUID(), tool: tool, text: text, binder: binder, created: Date(), folder: folder))
    }

    /// A conversation All-day capture heard, transcribed here, for the Mac: now, or once the Mac is back (and takes them).
    /// Saved before this returns, so the audio can go. A long one goes in parts that each fit in a message.
    @discardableResult
    func keepConversation(_ payload: ConversationPayload) async -> Bool {
        guard queueConversation(payload, send: false) else { return false }
        guard await ready() else { return false }
        await sendOutbox()
        return !outbox.contains { $0.conversation == payload.id }
    }

    /// The same, without waiting: in the outbox and saved before this returns, then sent in the background, so what
    /// writes captures down goes straight on to the next. It's marked sent once it reaches the Mac (onConversationSent).
    ///
    /// Lane Y2: `solo`, what the iPhone heard of it (its verdict, its mode, the moments said in it that may go with it, and
    /// whether it's kept only for them): to a Mac that lists ConversationPayload.soloFeature, in Add at Once, or in Auto
    /// once the sheet was seen with Y2's words, the payload carries its vouch (SoloAgreement); otherwise none of it.
    @discardableResult
    func queueConversation(_ payload: ConversationPayload, send: Bool = true, solo: SoloSend? = nil) -> Bool {
        var payload = payload
        if let solo, macFeatures.contains(ConversationPayload.soloFeature) {
            let defaults = UserDefaults.standard
            let mode = MomentMode(stored: solo.mode)
            let listed = defaults.bool(forKey: "momentAutoListed") && defaults.bool(forKey: MomentCenter.soloAutoListedKey)
            if mode == .add || (mode == .auto && listed) {
                payload.mode = mode.rawValue
                let parts = payload.parts().count
                payload.soloHold = SoloAgreement.hold(solo.verdict, mode: mode, listed: listed, parts: parts)
                if payload.soloHold == nil, solo.verdict.isOnlyYou {
                    payload.solo = true
                    payload.agreed = SoloAgreement.agreed(solo.verdict, mode: mode, listed: listed, macFeatures: macFeatures,
                                                          consents: AgentConsents.agreedFingerprints())
                    payload.soloMoments = solo.moments.isEmpty ? nil : solo.moments
                }
                payload.voice = solo.verdict.lowest
                payload.otherSpeech = solo.verdict.otherSpeech
                payload.keptForMoment = solo.keptForMoment ? true : nil
            }
        }
        let items = payload.parts().compactMap { part -> PendingSave? in
            guard let data = try? part.encoded() else { return nil }
            return PendingSave(id: part.id, tool: PendingSave.conversation, text: "", binder: nil, created: part.started,
                               conversation: payload.id, payload: data)
        }
        guard !items.isEmpty else { return false }
        outbox.removeAll { $0.conversation == payload.id }
        outbox += items
        Outbox.save(outbox)
        if send {
            Task {
                guard await self.ready() else { return }
                await self.sendOutbox()
            }
        }
        return true
    }

    /// The app's one connection, for what runs without a window: Siri, the Action Button.
    static weak var current: MacConnection?

    /// For Siri: a moment now, and what the Mac made of it; nil when the Mac can't be reached in time, and then it's kept
    /// in the outbox like any moment (sent again, the Mac knows it by its id).
    func momentNow(_ payload: MomentPayload, said: String) async -> CaptureOutcome? {
        errands += 1
        defer {
            errands -= 1
            errandDone()
        }
        guard takesMoments, await ready(within: LinkTimeouts.momentLink), let client, let params = try? payload.jsonObject() else {
            await keepMoment(payload, said: said)
            return nil
        }
        do {
            let reply = try await client.request(MomentPayload.method, params, timeout: LinkTimeouts.momentNow) as? [String: Any]
            // Kept on the Mac and not decided yet: it's working on it, and says when asked after (binders/outcomes).
            return reply?["outcome"].flatMap { CaptureOutcome.decodeEach([$0]).first }
                ?? CaptureOutcome(id: payload.id, state: "working", line: "")
        } catch {
            await keepMoment(payload, said: said)
            return nil
        }
    }

    /// Something you said to yourself, for the Mac: only the words, now or once it's back. It rides the outbox as a
    /// dictation carrying the moment, so an older build of this app would still send its words.
    func keepMoment(_ payload: MomentPayload, said: String) async {
        guard let data = try? payload.encoded() else { return }
        let item = PendingSave(id: payload.id, tool: PendingSave.dictation, text: payload.text, binder: nil, created: payload.heard,
                               raw: said, app: "All-day capture", payload: data)
        errands += 1
        defer {
            errands -= 1
            errandDone()
        }
        if await ready() {
            switch await send(item) {
            case .sent:
                onMomentSettled?(payload.id, momentOutcomes.removeValue(forKey: payload.id), true)
                return
            case .dropped:
                onMomentSettled?(payload.id, nil, false)
                return
            case .kept:
                break
            }
        }
        outbox.append(item)
        Outbox.save(outbox)
    }

    /// The same for one found in a conversation's transcript: into the outbox now, ahead of the conversation queued next,
    /// so the Mac has it when it writes that conversation up. It goes with the outbox, at once when the Mac can be reached.
    func queueMoment(_ payload: MomentPayload, said: String) {
        guard let data = try? payload.encoded() else { return }
        outbox.append(PendingSave(id: payload.id, tool: PendingSave.dictation, text: payload.text, binder: nil, created: payload.heard,
                                  raw: said, app: "All-day capture", payload: data))
        Outbox.save(outbox)
        Task {
            errands += 1
            defer {
                errands -= 1
                errandDone()
            }
            guard await ready() else { return }
            await sendOutbox()
        }
    }

    /// Add, Not Now, Undo or Assign on what this iPhone sent: the Mac's answer, or why it couldn't.
    func actOnOutcome(_ id: UUID, action: String, agent: String? = nil) async -> (ok: Bool, message: String) {
        var params: [String: Any] = ["id": id.uuidString, "action": action]
        if let agent { params["agent"] = agent }
        do {
            guard let reply = try await request(CaptureOutcome.actMethod, params) as? [String: Any] else {
                return (false, "\(mac?.name ?? "Your Mac") is out of reach. Try again in a moment.")
            }
            return (true, reply["message"] as? String ?? "")
        } catch LinkClient.Failure.rejected(let message) {
            return (false, message)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Stop, Undo or Not Me on what Auto handed over, to a Mac that lists MomentPayload.autoFeature: what the Mac said
    /// (`sent`), why it turned it down (`refused`), or `kept` when it can't be reached now, for MomentCenter to keep and
    /// send when it's back.
    /// `mode` (lane Y2): with action "mode", the mode a capture sent but not yet read goes as now.
    func outcomeAction(_ id: UUID, action: String, mode: String? = nil) async -> HandOff {
        errands += 1
        defer {
            errands -= 1
            errandDone()
        }
        if client == nil, mac != nil { Task { await connect() } }
        guard await ready(within: 4), let client else { return .kept }
        do {
            var params: [String: Any] = ["id": id.uuidString, "action": action]
            if let mode { params["mode"] = mode }
            let reply = try await client.request(CaptureOutcome.actMethod, params,
                                                 timeout: LinkTimeouts.request(CaptureOutcome.actMethod, [:])) as? [String: Any]
            return .sent(reply?["message"] as? String ?? "")
        } catch LinkClient.Failure.rejected(let message) {
            return .refused(message)
        } catch {
            return .kept
        }
    }

    // MARK: Hand-offs

    /// What became of a Give to: it went (with what the Mac said), it's kept here until the Mac is back, or the Mac said
    /// no (why).
    enum HandOff: Equatable {
        case sent(String)
        case kept
        case refused(String)
    }

    /// Give to on something you said to yourself that the Mac acted on: its Assign, now or once the Mac is back. Kept only
    /// for a Mac that takes it (binders/outcome).
    func give(moment id: UUID, to agent: String?) async -> HandOff {
        await handOff(PendingSave(id: UUID(), tool: PendingSave.handOff, text: "", binder: nil, created: Date(), agent: agent, moment: id),
                      trying: true, keeps: hasOutcomes)
    }

    /// Give to on a card: who it's for (nil for no one in particular), and into Ready if it was in Backlog, now or once the
    /// Mac is back. Not `trying`, it's kept at once. Its title goes with it, to say which card if the Mac turns it down.
    func give(card id: String, title: String, to agent: String?, fromBacklog: Bool, trying: Bool = true) async -> HandOff {
        await handOff(PendingSave(id: UUID(), tool: PendingSave.handOff, text: title, binder: nil, created: Date(), card: id, agent: agent ?? "",
                                  fromBacklog: fromBacklog), trying: trying, keeps: true)
    }

    /// The Give to waiting here for the Mac on something you said: not one that's being tried at once.
    func givingLater(moment id: UUID) -> PendingSave? {
        outbox.first { $0.tool == PendingSave.handOff && $0.moment == id && !givingNow.contains($0.id) }
    }

    /// Kept first, the newest Give to for the same thing standing, so a try cut short (the phone locked straight after the
    /// tap, the app suspended on the way, then closed) doesn't lose it. Then sent now when the Mac can be reached, and out
    /// of the outbox once it went or the Mac turned it down; otherwise it goes with the rest of the outbox once the Mac is
    /// back (connecting sends what's waiting). One a Mac couldn't take later (not `keeps`) is only tried.
    private func handOff(_ item: PendingSave, trying: Bool, keeps: Bool) async -> HandOff {
        let time = BackgroundTime(name: "Binders Give to")
        errands += 1
        givingNow.insert(item.id)
        defer {
            givingNow.remove(item.id)
            errands -= 1
            errandDone()
            time.end()
        }
        // Written down before it's tried, when it's kept at all; outbox runs pass it over while it's tried (givingNow).
        let kept = keeps && mac != nil
        let before = outbox.count
        outbox = OutboxRules.beforeTrying(item, in: outbox, keeps: kept) {
            $0.tool == PendingSave.handOff && $0.moment == item.moment && $0.card == item.card
        }
        if kept || outbox.count != before { Outbox.save(outbox) }
        if trying, await ready() {
            let result = await send(item)
            // It went, or the Mac turned it down: out of the outbox, unless a newer Give to for the same thing took its place
            // meanwhile. Not through, it's there already.
            if result != .kept, outbox.contains(where: { $0.id == item.id }) {
                outbox.removeAll { $0.id == item.id }
                Outbox.save(outbox)
            }
            switch result {
            case .sent: return .sent(handOffReplies.removeValue(forKey: item.id) ?? "")
            case .dropped: return .refused(handOffReplies.removeValue(forKey: item.id) ?? "\(mac?.name ?? "Your Mac") couldn't do that.")
            case .kept: break
            }
        }
        handOffReplies[item.id] = nil
        guard kept else { return .refused("\(mac?.name ?? "Your Mac") is out of reach. Try again when it's back.") }
        return .kept
    }

    /// A Give to, to the Mac. On something you said, its Assign. On a card, who it's for first (a Mac too old to know it
    /// says no, rather than the card moving unassigned), then into Ready if it's still in Backlog: it may have moved
    /// meanwhile. With its id as request_id, for a Mac that saves a repeat once.
    private func sendHandOff(_ item: PendingSave, _ client: LinkClient) async throws {
        if let moment = item.moment {
            var params: [String: Any] = ["id": moment.uuidString, "action": "assign"]
            if let agent = item.agent { params["agent"] = agent }
            let reply = try await client.request(CaptureOutcome.actMethod, withRequestID(params, of: item), timeout: LinkTimeouts.send) as? [String: Any]
            handOffReplies[item.id] = reply?["message"] as? String
        } else if let card = item.card {
            _ = try await client.callTool("update_task", withRequestID(["id": card, "for": item.agent ?? ""], of: item), timeout: LinkTimeouts.send)
            guard item.agent?.isEmpty == false, item.fromBacklog == true else { return }
            struct Placed: Decodable { let column: String }
            let text = try await client.callTool("get_task", ["id": card], timeout: LinkTimeouts.read)
            if (try? Self.decode(Placed.self, from: text))?.column == BoardColumn.backlog.rawValue {
                _ = try await client.callTool("update_task", ["id": card, "column": BoardColumn.ready.rawValue], timeout: LinkTimeouts.change)
            }
        }
    }

    enum Answered { case sent, kept, refused }

    /// An answer to an agent's question, typed into its notification, for the question asked at `asked`. It's kept in
    /// the outbox before anything else, so an app suspended or closed on the way doesn't lose it, then goes now,
    /// connecting for it from the background, or once the Mac is back. Refused when its question isn't waiting any more
    /// (answered meanwhile, asked again, the card gone).
    func answer(card id: String, question asked: String?, text: String) async -> Answered {
        let time = BackgroundTime(name: "Binders answer")
        let item = PendingSave(id: UUID(), tool: PendingSave.answer, text: text, binder: nil, created: Date(), card: id, question: asked)
        errands += 1
        answering.insert(item.id)
        defer {
            answering.remove(item.id)
            errands -= 1
            errandDone()
            time.end()
        }
        outbox.insert(item, at: 0)
        Outbox.save(outbox)
        // From a notification the app is usually asleep: try every address it knows now, together. Connecting sends
        // what's waiting, this answer first.
        if client == nil, mac != nil { await connect() }
        if outbox.contains(where: { $0.id == item.id }), await ready() { await sendOutbox() }
        if refusedAnswers.remove(item.id) != nil { return .refused }
        return outbox.contains { $0.id == item.id } ? .kept : .sent
    }

    /// Takes a conversation that hasn't gone yet out of the outbox.
    func forgetConversation(_ id: UUID) {
        outbox.removeAll { $0.conversation == id }
        Outbox.save(outbox)
    }

    /// From the background: connects for as long as it takes to send what's waiting, then lets go again.
    func flushOutbox() async {
        guard !outbox.isEmpty, mac != nil else { return }
        errands += 1
        defer {
            errands -= 1
            errandDone()
        }
        if client == nil { Task { await connect() } }
        if await ready() { await sendOutbox() }
    }

    /// Keeps a dictation made on this iPhone with the Mac's own, in its history and its search: now, or once the Mac is
    /// back. `app` says where it was made.
    @discardableResult
    func keepDictation(_ text: String, heard raw: String, app: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return await deliver(PendingSave(id: UUID(), tool: PendingSave.dictation, text: text, binder: nil, created: Date(), raw: raw, app: app))
    }

    /// Sends it, or keeps it in the outbox. True when it went straight to the Mac.
    private func deliver(_ item: PendingSave) async -> Bool {
        if await ready() {
            switch await send(item) {
            case .sent: return true
            case .dropped: return false
            case .kept: break
            }
        }
        outbox.append(item)
        Outbox.save(outbox)
        return false
    }

    private enum Sent { case sent, kept, dropped }

    /// An outbox item's arguments for the Mac, with the item's id as `request_id` when the Mac remembers those
    /// (LinkFeatures.dedupe): sent again after its reply was lost (a timeout, the link gone on the way), it's saved once.
    /// Every kind the outbox sends as a tool call goes through here: notes, to-dos, answers, hand-offs.
    private func withRequestID(_ arguments: [String: Any], of item: PendingSave) -> [String: Any] {
        OutboxRules.arguments(arguments, id: item.id, dedupe: macFeatures.contains(LinkFeatures.dedupe))
    }

    /// One item to the Mac. A Mac too old to take it says no, and the item goes; a lost connection keeps it for later.
    private func send(_ item: PendingSave) async -> Sent {
        guard let client else { return .kept }
        do {
            if item.tool == PendingSave.conversation {
                // A Mac that doesn't take them yet keeps them waiting here until it's updated.
                guard takesConversations, let data = item.payload,
                      let params = Self.conversationAsSent(data, macFeatures: macFeatures) else { return .kept }
                _ = try await client.request(ConversationPayload.method, params, timeout: LinkTimeouts.conversation)
            } else if item.tool == PendingSave.dictation, let data = item.payload, takesMoments,
                      let params = Self.momentAsSent(data, macFeatures: macFeatures, graduated: graduatedKinds?()) {
                // A moment, to a Mac that reads them: what it made of it comes back, when it's quick enough to say.
                let reply = try await client.request(MomentPayload.method, params, timeout: LinkTimeouts.moment) as? [String: Any]
                if let outcome = reply?["outcome"].flatMap({ CaptureOutcome.decodeEach([$0]).first }) { momentOutcomes[item.id] = outcome }
            } else if item.tool == PendingSave.dictation {
                var params: [String: Any] = ["id": item.id.uuidString, "text": item.text, "raw": item.raw ?? item.text,
                                             "app": item.app ?? "iPhone", "date": Date.isoParser.string(from: item.created)]
                if let model = item.model { params["model"] = model }
                _ = try await client.request("binders/dictation", params, timeout: LinkTimeouts.dictation)
            } else if item.tool == PendingSave.answer, let card = item.card {
                // Only to the question it answers: one answered meanwhile, or followed by a new question, doesn't take it.
                if let asked = item.question {
                    let text = try await client.callTool("get_task", ["id": card], timeout: LinkTimeouts.read)
                    guard let detail = try? Self.decode(CardDetail.self, from: text) else { return .dropped }
                    // Already on the card: it went before, and only the Mac's reply was lost on the way. It isn't sent
                    // again, or turned down for the question it answered.
                    if OutboxRules.answerArrived(item.text, card: card, asked: asked,
                                                 in: detail.timeline.map { ($0.kind, $0.when, $0.agent, $0.text) }) { return .sent }
                    guard let waiting = detail.question,
                          BoardRules.questionKey(card: card, asked: waiting.when) == BoardRules.questionKey(card: card, asked: asked) else {
                        return .dropped
                    }
                }
                _ = try await client.callTool(item.tool, withRequestID(["id": card, "text": item.text], of: item), timeout: LinkTimeouts.send)
            } else if item.tool == PendingSave.handOff {
                do {
                    try await sendHandOff(item, client)
                } catch LinkClient.Failure.rejected(let message) {
                    // Turned down (taken back meanwhile, the card gone): it wouldn't go later either.
                    handOffReplies[item.id] = message
                    return .dropped
                }
            } else {
                var arguments: [String: Any] = ["text": item.text]
                if let binder = item.binder { arguments["binder"] = binder }
                // Its folder, only to a Mac that has folders; its id decides the binder there, a renamed one too.
                if let folder = item.folder, hasFolders { arguments["folder"] = folder }
                do {
                    _ = try await client.callTool(item.tool, withRequestID(arguments, of: item), timeout: LinkTimeouts.send)
                } catch LinkClient.Failure.rejected where item.binder != nil {
                    // The binder was renamed or deleted on the Mac since: the note or to-do goes to the current one rather
                    // than wait here for good. Its request id stays: nothing was saved the first time.
                    arguments["binder"] = nil
                    _ = try await client.callTool(item.tool, withRequestID(arguments, of: item), timeout: LinkTimeouts.send)
                }
            }
            return .sent
        } catch LinkClient.Failure.rejected {
            // An answer the Mac turns down is for a card that's gone: it would only hold up what's behind it.
            return [PendingSave.dictation, PendingSave.conversation, PendingSave.answer].contains(item.tool) ? .dropped : .kept
        } catch {
            return .kept
        }
    }

    /// A capture as it's sent now (SoloModes.asSent, lane Y2): its mode lowered to the mode now, the yeses cut to those
    /// still given, and none of Y2's fields to a Mac that doesn't list them. A payload that doesn't read goes as kept.
    nonisolated static func conversationAsSent(_ data: Data, macFeatures: Set<String>, defaults: UserDefaults = .standard) -> [String: Any]? {
        guard let payload = try? ConversationPayload.decode(data) else {
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let consents = defaults.dictionary(forKey: "agentConsents") as? [String: String] ?? [:]
        let sent = SoloModes.asSent(payload, modeNow: MomentMode(stored: defaults.string(forKey: "momentMode")),
                                    listed: defaults.bool(forKey: "momentAutoListed"), soloListed: defaults.bool(forKey: "soloAutoListed"),
                                    macFeatures: macFeatures, consents: consents)
        return try? sent.jsonObject()
    }

    /// A moment as it's sent now (MomentModes.asSent), from the mode kept in UserDefaults (`momentMode`, and whether the
    /// sheet has listed Auto's agents, `momentAutoListed`): one heard in Auto goes as Add at Once or Suggest once Auto is
    /// off, without the yes it carried, and to a Mac without Auto without its mode. Read here, from where it's kept, so it
    /// holds even when the app was launched in the background to send what's waiting. A payload that doesn't read goes as
    /// it was kept.
    nonisolated static func momentAsSent(_ data: Data, macFeatures: Set<String>, graduated: [String]?,
                                         defaults: UserDefaults = .standard) -> [String: Any]? {
        guard let payload = try? MomentPayload.decode(data) else {
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        // The yeses cut to those still given now (lane Y2): one taken back while the Mac was away goes for what waited too.
        let consents = defaults.dictionary(forKey: "agentConsents") as? [String: String]
        let sent = MomentModes.asSent(payload, modeNow: MomentMode(stored: defaults.string(forKey: "momentMode")),
                                      listed: defaults.bool(forKey: "momentAutoListed"), addsNow: graduated, macFeatures: macFeatures,
                                      consents: consents)
        return try? sent.jsonObject()
    }

    /// Connected, or soon: waits a few seconds for a connection that's on its way, as when the app has just opened. When
    /// there's none and none has been tried for a while, it tries once more, briefly, as something is waiting on it.
    private func ready(within longest: TimeInterval = 8) async -> Bool {
        var wait = longest
        if client == nil, mac != nil, !connecting, state != .connecting, isActive || isHeld, Date().timeIntervalSince(lastAttempt) > 20 {
            state = .connecting
            wait = min(3, longest)
            Task { await connect() }
        }
        let deadline = Date().addingTimeInterval(wait)
        while client == nil, mac != nil, isActive || isHeld, connecting || state == .connecting || state == .offline(Self.notConnectedYet),
              Date() < deadline {
            // A cancelled sleep returns at once: stop waiting rather than spin.
            if (try? await Task.sleep(for: .milliseconds(150))) == nil { break }
        }
        return client != nil
    }

    /// What's waiting, in order, until something can't go. One run at a time: a call while it runs (an answer just kept)
    /// has it look again before it's through, and waits for it. Each item is tried once a run: one that didn't get
    /// through in time isn't sent straight again when the run looks again.
    private func sendOutbox() async {
        if sendingOutbox {
            outboxAgain = true
            while sendingOutbox {
                // A cancelled sleep returns at once: stop waiting rather than spin.
                if (try? await Task.sleep(for: .milliseconds(100))) == nil { break }
            }
            return
        }
        sendingOutbox = true
        defer { sendingOutbox = false }
        var tried: Set<UUID> = []
        repeat {
            outboxAgain = false
            // A file of the outbox set aside because it couldn't be opened (the iPhone locked) goes too, once it opens.
            var waiting = outbox
            if Outbox.recover(into: &waiting) { outbox = waiting }
            // Conversations wait for a Mac that takes them; everything else still goes. One taken out while the others
            // went (a capture deleted on this iPhone) doesn't go, and a Give to being tried at once waits for its try.
            while let item = OutboxRules.next(in: outbox, tried: tried, trying: givingNow,
                                              sends: { $0.tool != PendingSave.conversation || takesConversations }) {
                tried.insert(item.id)
                let result = await send(item)
                // Without the link, the rest waits too; one that only didn't get through in time waits for the next run
                // while the others go.
                guard result != .kept else {
                    if client == nil { return }
                    continue
                }
                outbox.removeAll { $0.id == item.id }
                Outbox.save(outbox)
                if let conversation = item.conversation, !outbox.contains(where: { $0.conversation == conversation }) {
                    if result == .sent { onConversationSent?(conversation) } else { onConversationRefused?(conversation) }
                }
                if item.tool == PendingSave.answer, let card = item.card {
                    if result == .dropped, answering.contains(item.id) { refusedAnswers.insert(item.id) }
                    onAnswerSettled?(card, result == .sent)
                }
                if item.tool == PendingSave.dictation, item.payload != nil {
                    onMomentSettled?(item.id, momentOutcomes.removeValue(forKey: item.id), result == .sent)
                }
                if item.tool == PendingSave.handOff {
                    onHandOffSettled?(item, result == .sent, handOffReplies.removeValue(forKey: item.id))
                }
            }
        } while outboxAgain
    }

    // MARK: Calling the Mac

    /// One of the Mac's tools, given as long as LinkTimeouts gives its kind (a read, a change, Ask) unless `timeout` says.
    /// A Mac that doesn't answer in that time counts as out of reach, and the link is checked.
    func call(_ tool: String, _ arguments: [String: Any] = [:], timeout: TimeInterval? = nil) async throws -> String {
        guard let client else { throw LinkClient.Failure.closed }
        return try await client.callTool(tool, arguments, timeout: timeout ?? LinkTimeouts.tool(tool))
    }

    /// Fresh from the Mac, and kept for next time. Nil when the Mac is out of reach or doesn't answer in a read's time
    /// (LinkTimeouts.read): the screen keeps what it shows, last time's copy at first (`cached`), rather than going back to
    /// an older one or to nothing, and the status pill shows if the Mac has gone quiet.
    /// `keeping` is what of the answer is kept for next time, when that isn't all of it.
    func fetch<T: Decodable>(_ tool: String, _ arguments: [String: Any] = [:], cache key: String, as type: T.Type,
                             keeping: (String) -> String = { $0 }) async -> (value: T?, fresh: Bool) {
        guard let client, let text = try? await client.callTool(tool, arguments, timeout: LinkTimeouts.read),
              let value = try? Self.decode(T.self, from: text) else { return (nil, false) }
        Cache.store(keeping(text), for: key)
        return (value, true)
    }

    /// The copy from last time: what a screen shows at once, while it asks the Mac. `keeping` is what of it is read, when
    /// that isn't all of it.
    func cached<T: Decodable>(_ key: String, as type: T.Type, keeping: (String) -> String = { $0 }) -> T? {
        Cache.load(key).map(keeping).flatMap { try? Self.decode(T.self, from: $0) }
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

/// Says when the phone's network changes: an interface or a VPN coming up or going, another Wi-Fi. Each update is
/// settled for a second (a VPN coming up sends a burst), and the first one is only the baseline. Every settled update
/// after it is told, even one that's the same in what LinkNetwork keeps: a VPN coming up can show only in what it
/// doesn't (its interface type, its DNS), and a connected link is left alone unless there's a new route.
@MainActor
final class NetworkWatch {
    var onChange: ((LinkNetwork, LinkNetwork) -> Void)?
    private let monitor = NWPathMonitor()
    private var settled: LinkNetwork?
    private var pending: LinkNetwork?
    private var settling: Task<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let network = LinkNetwork(reachable: path.status == .satisfied, interfaces: Set(path.availableInterfaces.map(\.name)),
                                      gateways: Set(path.gateways.map { "\($0)" }))
            Task { @MainActor in self?.updated(network) }
        }
        monitor.start(queue: DispatchQueue(label: "io.binders.link.network", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    private func updated(_ network: LinkNetwork) {
        guard settled != nil else {
            settled = network
            return
        }
        pending = network
        settling?.cancel()
        settling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let now = self.pending, let was = self.settled else { return }
            self.pending = nil
            self.settled = now
            self.onChange?(now, was)
        }
    }
}

/// Watches the local network for Macs running Binders with the phone link on.
final class MacBrowser: @unchecked Sendable {
    private let browser = NWBrowser(for: .bonjour(type: Link.serviceType, domain: nil), using: .tcp)
    private let lock = NSLock()
    private var found: [String: NWEndpoint] = [:]
    private var told: (@Sendable () -> Void)?

    init() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var endpoints: [String: NWEndpoint] = [:]
            for result in results {
                if case .service(let name, _, _, _) = result.endpoint { endpoints[name] = result.endpoint }
            }
            guard let self else { return }
            let tell = self.lock.withLock { () -> (@Sendable () -> Void)? in
                self.found = endpoints
                return self.told
            }
            tell?()
        }
        browser.start(queue: .global(qos: .utility))
    }

    /// Told, on the browser's queue, whenever what it sees changes; `names` says what it sees then.
    var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { told } }
        set { lock.withLock { told = newValue } }
    }

    /// The names of the Macs it sees now.
    var names: Set<String> {
        lock.withLock { Set(found.keys) }
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
    static func load(_ key: String) -> String? { (try? Data(contentsOf: file(key))).map { String(decoding: EarlierSpellings.json($0), as: UTF8.self) } }
    static func clear() { try? FileManager.default.removeItem(at: folder) }
}

/// A note, to-do, dictation or conversation waiting for the Mac.
struct PendingSave: Codable, Identifiable, Equatable {
    let id: UUID
    /// add_note, add_todo, `dictation` or `conversation`.
    let tool: String
    let text: String
    let binder: String?
    let created: Date
    /// A dictation's words as heard, before cleanup, and where it was made.
    var raw: String? = nil
    var app: String? = nil
    var model: String? = nil
    /// A conversation's id (shared by its parts), and the part itself as the JSON the Mac reads.
    var conversation: UUID? = nil
    var payload: Data? = nil
    /// The card an answer is for, and when the question it answers was asked: it goes only while that one waits.
    var card: String? = nil
    var question: String? = nil
    /// A Give to kept for the Mac: who it's for ("" for no one in particular), and what. Something you said: its moment's
    /// id. A card: `card`, with its title as `text`, and whether it was in Backlog, to go into Ready with it.
    var agent: String? = nil
    var moment: UUID? = nil
    var fromBacklog: Bool? = nil
    /// A note's folder's id, from a binder's folder on a Mac that has folders. Nil from builds before folders, and for
    /// everything else.
    var folder: String? = nil

    static let dictation = "dictation"
    static let conversation = "conversation"
    /// An answer to an agent's question: a comment on its card, as the card's own answer box sends.
    static let answer = "comment_task"
    /// Give to, on something you said or on a card, while the Mac was out of reach.
    static let handOff = "hand-off"
}

/// A little time to finish something in the background, such as an answer typed into a notification, or a Give to tapped
/// just before the phone locks: until it's done, or iOS says time's up.
@MainActor
final class BackgroundTime {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

/// The outbox, kept in a file so it survives the app being closed. Each file is a JSON list of PendingSave, as every
/// build has written it, read one item at a time: an item this build can't read is left out and logged, never the rest
/// with it. A file that's there but can't be opened just now is set aside rather than written over.
enum Outbox {
    private static var folder: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func file(in folder: URL) -> URL { folder.appendingPathComponent("outbox.json") }
    /// Answers to agents' questions wait in a file of their own: an earlier build of this app, reading outbox.json, would
    /// send one the wrong way, be refused, and hold back everything behind it.
    private static func answersFile(in folder: URL) -> URL { folder.appendingPathComponent("answers.json") }
    /// So do Give to's kept for the Mac, for the same reason: an earlier build would send one as a tool the Mac doesn't
    /// have, and hold everything behind it.
    private static func handOffsFile(in folder: URL) -> URL { folder.appendingPathComponent("handoffs.json") }
    /// In the name of a file set aside: "outbox-set-aside-<id>.json".
    static let setAsideMark = "-set-aside-"
    private static let log = Logger(subsystem: "io.binders.app", category: "outbox")

    static func load() -> [PendingSave] {
        #if DEBUG
        // The iPhone has no unit tests: each debug run checks, beside the app and in a folder of its own, that every
        // build's outbox still reads (OutboxCheck.swift).
        DispatchQueue.global(qos: .utility).async {
            let failed = selfCheck()
            assert(failed.isEmpty, "The outbox doesn't read as it should: \(failed.joined(separator: "; "))")
        }
        #endif
        return load(in: folder, log: log)
    }

    @discardableResult
    static func save(_ items: [PendingSave]) -> Bool { save(items, in: folder) }

    /// Files set aside because they couldn't be opened: once one opens, what's in it joins `items` (each id once,
    /// answers first) and is saved, and only then does the file go. True when anything came back.
    @discardableResult
    static func recover(into items: inout [PendingSave]) -> Bool { recover(into: &items, in: folder, log: log) }

    static func load(in folder: URL, log: Logger) -> [PendingSave] {
        // Answers first, as they're sent first; each item once, in order, however it was saved. Then what was set aside,
        // if it opens now.
        var seen = Set<UUID>()
        var items = (read(answersFile(in: folder), log: log) + read(file(in: folder), log: log) + read(handOffsFile(in: folder), log: log))
            .filter { seen.insert($0.id).inserted }
        recover(into: &items, in: folder, log: log)
        return items
    }

    /// True when every file was written.
    @discardableResult
    static func save(_ items: [PendingSave], in folder: URL) -> Bool {
        let rest = write(items.filter { $0.tool != PendingSave.answer && $0.tool != PendingSave.handOff }, to: file(in: folder))
        let answers = write(items.filter { $0.tool == PendingSave.answer }, to: answersFile(in: folder))
        let handOffs = write(items.filter { $0.tool == PendingSave.handOff }, to: handOffsFile(in: folder))
        return rest && answers && handOffs
    }

    @discardableResult
    static func recover(into items: inout [PendingSave], in folder: URL, log: Logger) -> Bool {
        let aside = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.contains(setAsideMark) && $0.hasSuffix(".json") }.sorted()
        var opened: [URL] = []
        var found: [PendingSave] = []
        for name in aside {
            let url = folder.appendingPathComponent(name)
            // Still can't be opened: next time.
            guard let data = try? Data(contentsOf: url) else { continue }
            opened.append(url)
            found += decode(data, from: name, log: log)
        }
        guard !opened.isEmpty else { return false }
        var known = Set(items.map(\.id))
        let back = found.filter { known.insert($0.id).inserted }
        // Written down before the files go: if it can't be, nothing changes, and they're read again next time.
        let merged = back.filter { $0.tool == PendingSave.answer } + items + back.filter { $0.tool != PendingSave.answer }
        guard back.isEmpty || save(merged, in: folder) else { return false }
        items = merged
        for url in opened { try? FileManager.default.removeItem(at: url) }
        if !back.isEmpty { log.notice("Brought back \(back.count, privacy: .public) item(s) from a file set aside earlier") }
        return !back.isEmpty
    }

    /// A file's items. One that's there but can't be opened now (the iPhone locked, and the file written by a build
    /// before 2.0 (10), which kept it for an unlocked iPhone only) is set aside under a name of its own, so the next save
    /// doesn't write over what's in it, and comes back by recover() once it opens.
    private static func read(_ url: URL, log: Logger) -> [PendingSave] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else {
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent + setAsideMark + UUID().uuidString + ".json")
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                keepOutOfBackups(aside)
                log.notice("\(url.lastPathComponent, privacy: .public) can't be opened now: set aside until it can")
            } catch {
                log.error("\(url.lastPathComponent, privacy: .public) can't be opened now, or set aside: \(error.localizedDescription, privacy: .public)")
            }
            return []
        }
        return decode(data, from: url.lastPathComponent, log: log)
    }

    /// Each item on its own: one that doesn't read is left out and logged, by its place and why, never its words.
    private static func decode(_ data: Data, from name: String, log: Logger) -> [PendingSave] {
        guard let read = JSONItems.decode(PendingSave.self, from: data) else {
            log.error("\(name, privacy: .public) isn't a list this build can read: nothing in it was loaded")
            return []
        }
        for skipped in read.skipped {
            log.error("Left out item \(skipped.index + 1, privacy: .public) of \(name, privacy: .public), which this build can't read: \(skipped.reason, privacy: .public)")
        }
        return read.items
    }

    /// True when it's written, or when there was nothing to write.
    private static func write(_ items: [PendingSave], to url: URL) -> Bool {
        guard !items.isEmpty || FileManager.default.fileExists(atPath: url.path) else { return true }
        // Written while the phone is locked too, when All-day capture finishes a conversation in the background.
        guard let data = try? JSONEncoder().encode(items),
              (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return false }
        // An atomic write makes a new file, so it's marked again each time.
        keepOutOfBackups(url)
        return true
    }

    /// The outbox holds what captures heard, on its way to your Mac: not for iCloud backups.
    private static func keepOutOfBackups(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

/// Lane Y2: what the iPhone heard of a capture, for its vouch (MacConnection.queueConversation): the verdict on its voices,
/// Said to yourself's mode as it was heard, the moments said in it that may go with it, and whether it's kept only for them.
struct SoloSend {
    var verdict: SoloRule.Verdict
    var mode: String?
    var moments: [UUID]
    var keptForMoment: Bool
}
