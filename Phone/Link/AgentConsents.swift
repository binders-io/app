import BindersKit
import Foundation

/// Your yes to giving cards to an agent, asked on this iPhone before the first card goes to it, once it has said where the
/// cards go and what goes with them (App Store 5.1.2(i)). A yes is for the agent as your Mac has it set up now: a Mac that
/// says where an agent's cards go fingerprints that too (list_agents), so an agent pointed somewhere new, or given more to
/// read, is asked about again. With a Mac that says only names and kinds, a yes to the name stands, as it always did.
/// Giving it a card, making a card meant for it Ready, answering its question, commenting on a card it's working on (on a
/// Mac that wakes it for that), approving or declining what it asks your approval for and sending its work back all ask
/// first.
@MainActor
enum AgentConsents {
    /// The agents said yes to, by name (lowercased), with the fingerprint each had then ("" when the Mac gave none).
    private static let consentsKey = "agentConsents"
    /// Names said yes to before Macs said where an agent's cards go; builds before this one read only these.
    private static let namesKey = "agentsAgreed"
    /// Answers typed into a question's notification before you'd said yes to that agent, by card.
    private static let heldKey = "answersAwaitingConsent"

    /// A yes is kept per brain: a Mac's agents by name, as always; a hub's under its address too. So a yes given to an agent
    /// on your Mac never counts for one of the same name on a hub (a teammate's runner, say), nor the other way round.
    private static func key(_ name: String) -> String {
        let bare = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let hub = hubPrefix else { return bare }
        return hub + bare
    }

    /// "hub:<address>|" with the hub as the brain; nil with the Mac.
    private static var hubPrefix: String? {
        guard MacConnection.onHub else { return nil }
        return "hub:\(HubBrain.load()?.address.absoluteString.lowercased() ?? "")|"
    }

    /// Names said yes to before fingerprints: only ever a Mac's.
    private static func namedBefore(_ name: String) -> Bool { hubPrefix == nil && names.contains(name) }

    private static var consents: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: consentsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: consentsKey) }
    }

    private static var names: [String] { UserDefaults.standard.stringArray(forKey: namesKey) ?? [] }

    // MARK: Who

    /// The agents your Mac hands cards to, as last heard. `connection` is the app's own unless one is given.
    static func agents(_ connection: MacConnection? = nil) -> AgentList? {
        (connection ?? MacConnection.current)?.cached("agents", as: AgentList.self)
    }

    /// The one going by `name`, matched as the Mac matches names: exactly, whatever the case.
    static func agent(named name: String, connection: MacConnection? = nil) -> AgentList.Agent? {
        let wanted = key(name)
        return agents(connection)?.all.first { key($0.name) == wanted }
    }

    /// Asks the Mac again who they are, so what's said before a card goes is what's set up now.
    static func refresh(_ connection: MacConnection) async {
        _ = await connection.fetch("list_agents", cache: "agents", as: AgentList.self)
    }

    // MARK: Yes

    /// Whether you've said yes to giving `agent` cards, as it's set up now.
    static func agreed(_ agent: AgentList.Agent) -> Bool {
        let given = consents[key(agent.name)]
        if let fingerprint = agent.fingerprint, !fingerprint.isEmpty { return given == fingerprint }
        return given != nil || namedBefore(agent.name)
    }

    static func agree(_ agent: AgentList.Agent) {
        var all = consents
        all[key(agent.name)] = agent.fingerprint ?? ""
        consents = all
        if hubPrefix == nil, !names.contains(agent.name) { UserDefaults.standard.set(names + [agent.name], forKey: namesKey) }
    }

    /// For a name alone, as a moment's Give to has it: the agent by that name as it's set up now, or, before the iPhone
    /// has heard who the agents are, a yes to the name given before.
    static func agreed(toName name: String, connection: MacConnection? = nil) -> Bool {
        if let agent = agent(named: name, connection: connection) { return agreed(agent) }
        return consents[key(name)] != nil || namedBefore(name)
    }

    static func agree(toName name: String, connection: MacConnection? = nil) {
        agree(agent(named: name, connection: connection) ?? AgentList.Agent(name: name, wakes: ""))
    }

    /// Whether your answer to `asker`'s question waits for your yes: it's one of the agents your Mac hands cards to (or
    /// the iPhone can't tell yet) and you haven't said yes to it as it is now. Someone who isn't one of them, such as your
    /// own Claude Code session, gets your answer on the card as before.
    static func answerWaits(for asker: String, connection: MacConnection? = nil) -> Bool {
        guard let list = agents(connection) else { return true }
        guard let agent = list.agents.first(where: { key($0.name) == key(asker) }) else { return false }
        return !agreed(agent)
    }

    /// Every yes given on this iPhone, by name as it's kept (trimmed, lowercased), with the fingerprint each had: what a
    /// "Binders, …" said in your voice carries to a Mac that reads it (MomentAgreement).
    static func agreedFingerprints() -> [String: String] {
        // This brain's only, by name as the Mac reads them.
        guard let hub = hubPrefix else { return consents.filter { !$0.key.hasPrefix("hub:") } }
        return Dictionary(uniqueKeysWithValues: consents.compactMap { $0.key.hasPrefix(hub) ? (String($0.key.dropFirst(hub.count)), $0.value) : nil })
    }

    // MARK: What's said

    /// What goes to an agent with a card, and where, said before the first card goes to it: who the agent hands it to for
    /// its work too, when the Mac says (AgentConsent.disclosure).
    static func disclosure(_ agent: AgentList.Agent) -> String {
        // A teammate's agent (lane DB2): who it belongs to and who it sends cards to, as its owner says.
        if agent.isTeammates {
            return TeamAgentConsent.message(owner: agent.owner ?? "a teammate", sendsTo: agent.sendsTo, headless: agent.headless == true)
        }
        return AgentConsent.disclosure(name: agent.name, wakes: agent.wakes, sendsTo: agent.sendsTo, vendor: agent.vendor, addsContext: agent.addsContext,
                                contextFrom: agent.contextFrom, mayAct: agent.mayAct, openSession: agent.openSession, startsOnItsOwn: agent.autoStart,
                                autoModeStart: agent.autoModeStart, soloStart: agent.soloStart)
    }

    /// The same, laid out for the yes page Review… opens on the Auto sheet: every fact of it, in labelled parts.
    static func page(_ agent: AgentList.Agent) -> AgentConsent.Page {
        AgentConsent.page(name: agent.name, wakes: agent.wakes, sendsTo: agent.sendsTo, vendor: agent.vendor, addsContext: agent.addsContext,
                          contextFrom: agent.contextFrom, mayAct: agent.mayAct, openSession: agent.openSession, startsOnItsOwn: agent.autoStart,
                          autoModeStart: agent.autoModeStart, soloStart: agent.soloStart)
    }

    /// Lane Y2: your yes here was given to the agent's words before Auto read what you think out loud (`auto_fingerprint`),
    /// so it takes only what you say on its own until you say yes again; or the Mac's yes for captures is from before.
    static func agreedBeforeSolo(_ agent: AgentList.Agent) -> Bool {
        guard agent.auto == AutoReach.Agent.takes.rawValue else { return false }
        if agent.solo == "switch-before" { return agreed(agent) }
        guard agent.soloStart == true, let before = agent.autoFingerprint, !before.isEmpty else { return false }
        return consents[key(agent.name)] == before
    }

    // MARK: Auto

    /// An agent's Auto code as this iPhone sees it: the Mac's (list_agents' `auto`), or "no-yes" for one the Mac lets take
    /// what you say that you haven't said yes to here as it's set up now. Nil from a Mac without Auto.
    static func autoCode(_ agent: AgentList.Agent) -> String? {
        guard let code = agent.auto else { return nil }
        // A yes given before Auto read what you think out loud still holds for what you say on its own (lane Y2).
        if code == AutoReach.Agent.takes.rawValue, !agreed(agent), !agreedBeforeSolo(agent) { return AutoReach.Agent.noYes.rawValue }
        return code
    }

    /// The agents Auto may hand what you say to now: the Mac lets it, and you've said yes here.
    static func mayTakeInAuto(_ list: AgentList?) -> [AgentList.Agent] {
        (list?.agents ?? []).filter { autoCode($0) == AutoReach.Agent.takes.rawValue }
    }

    /// The same for a name alone; for one the iPhone hasn't heard about yet, without saying where.
    static func disclosure(named name: String?, connection: MacConnection? = nil) -> String {
        guard let name else {
            return "Binders on your Mac hands the agent a card for this: its title, details and links, its binder and due date, and your answers and comments on it. Nothing else from your binders goes with it."
        }
        return disclosure(agent(named: name, connection: connection) ?? AgentList.Agent(name: name, wakes: ""))
    }

    // MARK: Answers that wait

    /// An answer typed into an agent's question notification before you'd said yes to that agent: it waits on this
    /// iPhone, and the card asks when you open it.
    struct HeldAnswer: Codable, Equatable {
        var text: String
        /// When the question it answers was asked, so an answer to a question that's gone isn't taken.
        var asked: String?
        var agent: String
    }

    private static var heldAnswers: [String: HeldAnswer] {
        get { UserDefaults.standard.data(forKey: heldKey).flatMap { try? JSONDecoder().decode([String: HeldAnswer].self, from: $0) } ?? [:] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: heldKey) }
    }

    static func hold(_ answer: HeldAnswer, card: String) {
        var all = heldAnswers
        all[card] = answer
        heldAnswers = all
    }

    static func held(card: String) -> HeldAnswer? { heldAnswers[card] }

    static func release(card: String) {
        var all = heldAnswers
        guard all.removeValue(forKey: card) != nil else { return }
        heldAnswers = all
    }
}
