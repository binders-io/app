import Foundation
import SwiftData
import BindersKit

/// The one router for new cards and to-dos: where each goes, and the agent whose work it is. For one that doesn't say,
/// in this order: the rules (a binder or an agent you named wins), then the decision model chosen in Settings → AI
/// (DecisionModels: Tev1 0.8B unless you choose another, when it can be used), then the LLM step where the entry point has
/// one today (a moment's classify or route call), then the entry point's fallback (General, or the open binder). The
/// agent is only ever named where Give to is offered, and nothing goes to it until you tap, with one exception you turn
/// on per agent: "Start on cards Binders sends it", for a card you type into Ready, a to-do you add in Command Mode or a
/// "Binders, …" you say on your own in your voice, when the model is sure enough of it at its own start level
/// (RouterRules.mayStart) and is still the model that decided (DecisionModels.confirm); and, while your iPhone is in Auto,
/// a to-do or an idea you say on your own in your voice, at the model's Auto level, for an agent whose start switch has
/// its yes renewed for Auto (RouterRules.mayHandOver). Never from a capture, a conversation, Siri, a teammate, MCP or an
/// agent. Each decision goes in the tuning log (RouterLogFile), without words or names: the model is there by its
/// fingerprint.
@MainActor
final class CardRouter {
    weak var controller: DictationController?
    /// The decision model chosen, its bands and its starts. The self-tests give the router one of their own.
    var models: DecisionModels
    /// A backend asked in place of the chosen one, for the self-tests; nil otherwise. Its answers never start an agent.
    var override: (any DecisionBackend)?
    /// The decision model asked for the next card: read at the start of each `ask`, so a choice in Settings takes effect
    /// for the next card. Nil for Off.
    var backend: (any DecisionBackend)? { override ?? models.backend }
    /// What a card may take with the model: waiting, a cold load and working out which model it is included.
    var budget: Duration = MLXDecisionBackend.cardBudget
    let log: RouterLogFile
    /// Why the model didn't answer the last time it was asked, for the log.
    private(set) var lastFailure: String?

    /// `models`: DecisionModels.shared unless a self-test gives its own.
    init(controller: DictationController, models: DecisionModels? = nil, log: RouterLogFile = .shared) {
        self.controller = controller
        self.models = models ?? .shared
        self.log = log
    }

    // MARK: What it reads

    /// What the router reads, gathered from the store and the agents' files: plain values (RouterInputs), and what
    /// they stand for.
    struct Library {
        var inputs: RouterInputs
        var general: BinderRecord
        /// Your binders that may be named, by name: every one of yours but team copies and archived ones, General among
        /// them, as the rules read them.
        var named: [BinderRecord]
        /// The agents that may be named, by board name: enabled ones.
        var agents: [AgentProfile]

        var agentNames: [String] { agents.map(\.name) }
        func binder(_ id: UUID?) -> BinderRecord? { named.first { $0.id == id } ?? (general.id == id ? general : nil) }
    }

    /// Without each binder's latest titles: `ask` reads those, for the binder question alone, once the model can be asked,
    /// so a Mac without it never reads them for a moment, a card or a to-do.
    func gather() -> Library {
        let store = Store.shared
        let general = store.defaultBinder()
        let named = store.binders().filter { !$0.isTeamCopy && !$0.archived }
        let registry = AgentRegistry.shared
        let enabled = registry.agents.filter(\.isEnabled)
        let (offered, unoffered) = Self.agentInputs(enabled, registry: registry)
        let binders = named.filter { !$0.isDefault }.map { binder in
            RouterInputs.Binder(id: binder.id, name: binder.name, whatGoesHere: binder.whatGoesHere, latest: binder.updatedAt)
        }
        return Library(inputs: RouterInputs(binders: binders, agents: offered, unoffered: unoffered, paused: registry.paused),
                       general: general, named: named, agents: enabled)
    }

    /// The enabled agents as the agent question reads them, in Settings order. Changed outside Binders or held: never
    /// offered, as what it says it's for may be its own words; but an agent that takes a binder's cards and wasn't offered
    /// moved its share to the rest, so nothing starts there. `approving`: the one Settings is about to save, taken as saved.
    static func agentInputs(_ agents: [AgentProfile], registry: AgentRegistry,
                            approving: UUID? = nil) -> (offered: [RouterInputs.Agent], unoffered: [RouterInputs.Agent]) {
        var offered: [RouterInputs.Agent] = []
        var unoffered: [RouterInputs.Agent] = []
        for agent in agents where agent.isEnabled {
            let entry = RouterInputs.Agent(id: agent.id, name: agent.name, description: agent.modelDescription, takes: agent.binders)
            if agent.id != approving, registry.changedOutside.contains(agent.id) || registry.held[agent.id] != nil {
                unoffered.append(entry)
            } else {
                offered.append(entry)
            }
        }
        return (offered, unoffered)
    }

    /// The agents the agent question leaves out (nothing says what each is for, held, changed outside Binders) that take a
    /// binder `agent` takes too: Binders never starts `agent` on its own in such a binder (RouterRules.mayStart,
    /// `leftOutTaker`). For the agents list's row, and for the sentences beside its start switch. `agent` as the editor
    /// has it, about to be saved.
    static func leftOutAgents(beside agent: AgentProfile) -> [RouterInputs.Agent] {
        leftOut(beside: agent).agents
    }

    /// The left-out agents beside `agent`, and the names the agent question offers.
    private static func leftOut(beside agent: AgentProfile) -> (agents: [RouterInputs.Agent], offered: [String]) {
        let registry = AgentRegistry.shared
        var agents = registry.agents
        if let index = agents.firstIndex(where: { $0.id == agent.id }) { agents[index] = agent } else { agents.append(agent) }
        let (offered, unoffered) = agentInputs(agents, registry: registry, approving: agent.id)
        let inputs = RouterInputs(binders: [], agents: offered, unoffered: unoffered, paused: registry.paused)
        let me = RouterInputs.Agent(id: agent.id, name: agent.name, description: agent.modelDescription, takes: agent.binders)
        return (RouterQuestions.leftOut(sharingBindersWith: me, inputs: inputs), offered.map(\.name))
    }

    /// The agents the agent question leaves out that take a binder `agent` takes too (`leftOutAgents`), each in a sentence
    /// for Settings beside its start switch, saying what puts it right. `agent` as the editor has it, about to be saved,
    /// called `subject` in the sentence.
    static func leftOutLines(beside agent: AgentProfile, calling subject: String = "it") -> [String] {
        let registry = AgentRegistry.shared
        let (others, names) = leftOut(beside: agent)
        return others.map { other in
            let until = if registry.changedOutside.contains(other.id) {
                "until you open \(other.name) here, look it over and save it"
            } else if registry.held[other.id] != nil {
                "until you fix \(other.name) as its row here says"
            } else if PythonText.oneLine(other.description ?? "").isEmpty {
                "until \(other.name) says what it's for"
            } else if names.filter({ $0 == other.name }).count > 1 || PythonText.strip(other.name).lowercased() == RouterQuestions.nobody {
                "until \(other.name) has a name of its own"
            } else {
                "while more than \(RouterQuestions.maxAgents) agents are on"
            }
            return "Binders won't start \(subject) in a binder \(other.name) also takes \(until)."
        }
    }

    /// For the self-test: how many times a binder's titles were read.
    private(set) var titlesRead = 0

    /// The binders with their latest titles, as the binder question describes them.
    func titled(_ inputs: RouterInputs) -> RouterInputs {
        var inputs = inputs
        inputs.binders = inputs.binders.map { binder in
            var binder = binder
            binder.titles = routerTitles(in: binder.id)
            return binder
        }
        return inputs
    }

    /// A binder's latest titles as the router reads them: the three latest meetings and the three latest notes that are
    /// yours, as recentTitles takes them, passing over team copies and notes with an agent's mark. Agent text never steers
    /// filing. Meetings an agent adds over add_meeting carry no mark, so they still count. Two fetches.
    func routerTitles(in binderID: UUID) -> [String] {
        titlesRead += 1
        let context = Store.shared.context
        var meetings = FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.binderID == binderID && $0.status == "ready" && !$0.isTeamCopy },
                                                      sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        meetings.fetchLimit = 3
        var notes = FetchDescriptor<NoteItem>(predicate: #Predicate { $0.binderID == binderID && !$0.isTeamCopy },
                                              sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        notes.fetchLimit = 24
        let yours = ((try? context.fetch(notes)) ?? []).filter { $0.agentMark.isEmpty }.prefix(3)
        let titles = ((try? context.fetch(meetings)) ?? []).map(\.title) + yours.map(\.title)
        return titles.map { String($0.prefix(80)) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Asking the model

    /// The decision model's answers, raw, with what was asked, the model that answered and the bands it's held to.
    struct ModelAnswer {
        /// The backend that answered, for `confirm` right before a start.
        var backend: any DecisionBackend
        /// Which model it was (fingerprint and reader), and whose bands: built in, measured or unmeasured.
        var identity: DecisionIdentity
        var source: ResolvedBands.Source
        var bands: RouterBands
        var numbersMatch: Bool
        /// The model a server said answered; nil for an MLX model.
        var answeredBy: String?
        var binders: RouterQuestions.Binders?
        var binderProbs: [Double]?
        var agents: RouterQuestions.Agents?
        var agentProbs: [Double]?
        var ms: Int

        /// The binder answer by id, in the order offered.
        var binderAnswer: [(id: UUID, p: Double)]? {
            guard let binders, let binderProbs, binderProbs.count == binders.offered.count else { return nil }
            return Array(zip(binders.offered.map(\.id), binderProbs))
        }

        /// The agent answer by key (board name, or nobody), in the order offered.
        var agentAnswer: [RankedOption]? {
            guard let agents, let agentProbs, agentProbs.count == agents.question.options.count else { return nil }
            return zip(agents.question.options.map(\.key), agentProbs).map { RankedOption(key: $0.0, p: $0.1) }
        }

        var agentTop: RankedOption? { agentAnswer.flatMap { answer in RouterMath.argmax(answer.map(\.p)).map { answer[$0] } } }
    }

    /// The decision model's answers for what was said or typed: the binder question when `binder`, the agent question when
    /// `agent`, one after the other within the card's budget, which also covers working out which model it is and its
    /// bands. Nil with Off, when the model can't be used, isn't known in time, failed, or the card's time ran out: the
    /// router then goes on without it, as before. A model with no measure is asked too, with bands that name agents and
    /// start none. Each binder's latest titles are read only here, for the binder question, once the model can be asked.
    /// The answer carries the backend and the bands it started with, so a switch meanwhile can't lend it another's.
    func ask(_ state: String, binder askBinder: Bool, agent askAgent: Bool, library: Library) async -> ModelAnswer? {
        guard let backend else { return nil }
        let started = ContinuousClock.now
        let deadline = started + budget
        // A model still being checked is waited for inside the card's own time, and a server that didn't answer last time
        // is tried again.
        let now = await backend.state()
        guard now.worthAsking, let resolved = await models.bands(for: backend, by: deadline) else { return nil }
        let binders = askBinder ? RouterQuestions.binders(state: state, inputs: titled(library.inputs)) : nil
        let agents = askAgent ? RouterQuestions.agents(state: state, inputs: library.inputs) : nil
        let questions = [binders?.question, agents?.question].compactMap { $0 }
        guard !questions.isEmpty else { return nil }
        do {
            let answered = try await backend.decide(questions, expecting: resolved.identity, by: deadline)
            let answers = answered.probs
            let elapsed = started.duration(to: .now)
            let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            var index = 0
            var answer = ModelAnswer(backend: backend, identity: resolved.identity, source: resolved.source, bands: resolved.bands,
                                     numbersMatch: await backend.numbersMatch(), answeredBy: answered.answeredBy, binders: binders, agents: agents, ms: ms)
            if binders != nil, answers.indices.contains(index) {
                answer.binderProbs = answers[index]
                index += 1
            }
            if agents != nil, answers.indices.contains(index) { answer.agentProbs = answers[index] }
            lastFailure = nil
            return answer
        } catch {
            lastFailure = error.localizedDescription
            Log.app.info("The router model didn't answer for a card: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Deciding

    /// The agent named on Give to, or none, with the reason when an agent you named can't take the binder's cards.
    /// `agentFit`: without the model's answer, today's AgentFit (a moment's only taker, the LLM's FITS); false for cards
    /// and Command Mode, which never had it, so without the model they name only an agent you named.
    func agentOutcome(kind: RouteKind, named: [String], answer: ModelAnswer?, binder: UUID, llmAgent: String? = nil,
                      llmFits: String? = nil, agentFit: Bool = true) -> RouterRules.AgentOutcome {
        let registry = AgentRegistry.shared
        let takers = registry.takers(for: binder).map(\.name)
        // Those whose own list takes the binder's cards, paused, held or changed outside Binders or not: one you named
        // among them can't take a card now, which is a different line from not taking them at all.
        let listed = registry.agents.filter { $0.isEnabled && $0.takesCards(from: binder) }.map(\.name)
        return RouterRules.agent(kind: kind, named: named, model: answer?.agentAnswer, bands: answer?.bands, takers: takers, listed: listed,
                                 llmAgent: llmAgent, llmFits: llmFits, agentFit: agentFit)
    }

    /// Why the agent suggested doesn't start on its own here, or nil when every condition holds (RouterRules.mayStart).
    /// `named`: the agents you named in it, of which only one may start.
    func whyNotStart(_ pick: AgentPick, answer: ModelAnswer?, binder: UUID, origin: RouteOrigin, kind: RouteKind,
                     payload: MomentPayload? = nil, named: [String] = []) -> RouterRules.NotStarted? {
        guard let agent = AgentRegistry.shared.agent(named: pick.name) else { return .notATaker }
        return RouterRules.mayStart(startCheck(agent, pick: pick, answer: answer, binder: binder, origin: origin, kind: kind, payload: payload,
                                               named: named))
    }

    /// Why Auto doesn't hand a to-do or an idea you said to the agent picked for it, or nil when every condition holds
    /// (RouterRules.mayHandOver): the same check as a start's, with whether Binders may wake the agent at all, whatever its
    /// hourly cap, the iPhone's yes for the words that name Auto, and what only Auto depends on (`auto`, which MomentService
    /// fills in).
    func whyNotHandOver(_ pick: AgentPick, answer: ModelAnswer?, binder: UUID, origin: RouteOrigin, kind: RouteKind,
                        payload: MomentPayload, named: [String], auto: RouterRules.AutoCheck, soloAuto: Bool = false) -> RouterRules.NotStarted? {
        guard let agent = AgentRegistry.shared.agent(named: pick.name) else { return .notATaker }
        return RouterRules.mayHandOver(startCheck(agent, pick: pick, answer: answer, binder: binder, origin: origin, kind: kind, payload: payload,
                                                  named: named, soloAuto: soloAuto), auto: auto)
    }

    /// Everything a start or a hand-over without a tap depends on, for this agent and this card or moment.
    private func startCheck(_ agent: AgentProfile, pick: AgentPick, answer: ModelAnswer?, binder: UUID, origin: RouteOrigin, kind: RouteKind,
                            payload: MomentPayload?, named: [String], soloAuto: Bool = false) -> RouterRules.StartCheck {
        let registry = AgentRegistry.shared
        return RouterRules.StartCheck(
            agent: agent.name, how: pick.how, startsOnItsOwn: registry.startsOnItsOwn(agent), hasOwnPurpose: agent.hasOwnPurpose,
            draftsFirst: agent.draftsFirst, checksBoard: agent.wake == .board, bands: answer?.bands, numbersMatch: answer?.numbersMatch ?? false,
            modelTop: answer?.agentTop, takesBinder: agent.takesCards(from: binder),
            takerNow: registry.takers(for: binder).contains { $0.id == agent.id },
            leftOutTakesBinder: answer?.agents?.leftOut.contains { $0.takesCards(from: binder) } ?? false,
            origin: origin, kind: kind, phone: payload.map { phoneCheck($0, agent: agent, soloAuto: soloAuto) },
            wouldWake: controller?.agents.wouldWake(agent) ?? false, named: named, wakeable: registry.wakeable(agent))
    }

    /// The line for an agent you named that takes the binder's cards but can't take one now.
    static func cantTakeNow(_ name: String) -> String {
        AgentRegistry.shared.paused ? "Agents are paused, so \(name) can't take it now." : "\(name) can't take cards now: see Settings → Agents."
    }

    /// `why` as a clause inside a sentence: without the period it may end with, so a line never ends in "..".
    static func clause(_ why: String) -> String {
        var text = why.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// What came with a moment, for the Mac's own check of where it came from, with the agent's fingerprint as an iPhone
    /// that sends its yes is given it ("starts" in it), and, for a moment that came with a mode (only an iPhone that lists
    /// MomentPayload.autoFeature sends one) and an agent with the Mac's yes for Auto, as such an iPhone is given it ("starts"
    /// and "auto"). A moment said on its own that took the words of the conversation that opened at its first word
    /// (`alone`) was said on its own, whatever its conversation's id says.
    func phoneCheck(_ payload: MomentPayload, agent: AgentProfile, soloAuto: Bool = false) -> RouterRules.PhoneCheck {
        let reads = AgentBriefing.reads(for: agent.name)
        let auto = payload.mode != nil && AgentRegistry.shared.startsInAuto(agent)
        // Lane Y2: for a moment or an item from a phone that lists soloAuto (`soloAuto`), the fingerprint with "solo" too.
        let solo = auto && soloAuto && AgentRegistry.shared.startsInSolo(agent)
        return RouterRules.PhoneCheck(wake: payload.wake, engine: payload.engine, conversation: payload.alone == true ? nil : payload.conversation,
                                      kind: payload.kind, adds: payload.adds, heard: payload.heard, now: Date(), agreed: payload.agreed,
                                      key: RouterRules.PhoneCheck.consentKey(agent.name),
                                      fingerprint: AgentRegistry.consentFingerprint(agent, reads: reads, startsOnItsOwn: true),
                                      autoFingerprint: auto ? AgentRegistry.consentFingerprint(agent, reads: reads, startsOnItsOwn: true, auto: true) : nil,
                                      soloFingerprint: solo ? AgentRegistry.consentFingerprint(agent, reads: reads, startsOnItsOwn: true, auto: true, solo: true) : nil)
    }

    // MARK: Carrying it out

    /// Binders' suggestion on a card: a Give to that waits for your tap, never in place of your own choice, with why on
    /// the timeline.
    func suggest(_ card: TaskCard, _ pick: AgentPick) {
        controller?.board.assign(card, to: pick.name, by: BoardService.binders, suggesting: true, why: Self.why(pick))
    }

    /// "it looks like Codex's work." or "you named it." In words, never the model's percentage: its raw probability isn't a
    /// rate (from 0.50 to 0.97 its picks were right about 4 times in 5 whatever the number), so the log keeps the number
    /// and the card says what the band means.
    static func why(_ pick: AgentPick) -> String? {
        switch pick.how {
        case .model: pick.p.map { _ in "it looks like \(pick.name)'s work." }
        case .named: "you named it."
        case .llm, .onlyTaker: nil
        }
    }

    enum Started: Equatable {
        case woke
        case notWoken(String)
        case changed
    }

    /// A hand-over in Auto, for its note on the card: when you said it, whether it's an idea to look into and plan, and
    /// whether you named the agent.
    struct AutoModeStart {
        var heard: Date
        var idea: Bool
        var named: Bool
        /// Lane Y2: from a capture in which your iPhone heard only you; `joined`, a moment said in it that went with it, and
        /// `asked`, one that was a "Binders, …".
        var solo = false
        var joined = false
        var asked = false
    }

    /// Hands the card to the agent without a tap, through Give to's own path (the hourly cap, the briefing, the receipt),
    /// by Binders, after checking once more that nothing changed: the card is in Ready (or, `fromBacklog`, in Backlog, as an
    /// idea's own card is, which Give to moves to Ready), meant for no one or for Binders' own suggestion, nobody holds it,
    /// and its title is still `title`. The note on the card follows the wake: what Binders did and why (`auto`: Auto's
    /// note), or that it meant to and why it couldn't.
    func start(_ card: TaskCard, agent: AgentProfile, origin: RouteOrigin, title: String, fromBacklog: Bool = false, auto: AutoModeStart? = nil) -> Started {
        guard let board = controller?.board else { return .changed }
        guard card.column == .ready || (fromBacklog && card.column == .backlog), card.meantFor == nil || card.meantForByAgent,
              card.assignee == nil || !BoardRules.isClaimed(card.state, at: Date()), card.title == title else { return .changed }
        switch board.give(card, to: agent.name, by: BoardService.binders) {
        case .woke:
            let note = auto.map { start in
                start.solo ? AutoText.note(agent: agent.name, idea: start.idea, asked: start.asked, named: start.named, heard: start.heard, now: Date(),
                                           solo: true, joined: start.joined)
                    : Self.autoNote(agent: agent.name, origin: origin, idea: start.idea, heard: start.heard, named: start.named)
            }
            board.note(card, text: note ?? Self.startNote(agent: agent.name, origin: origin))
            return .woke
        case .notWoken(let why):
            board.note(card, text: "\(Self.notWokenNote(agent.name)): \(Self.clause(why)). Wake Now on the card does it.")
            return .notWoken(why)
        }
    }

    /// How the card's note for a start that wasn't woken begins, for it and for finding it again.
    static func notWokenNote(_ agent: String) -> String { "Binders meant to hand this to \(agent) without asking, but it wasn't woken" }

    /// The card's note for a start: what Binders did, why, and how to stop it.
    static func startNote(agent: String, origin: RouteOrigin) -> String {
        let from = switch origin {
        case .commandMode: "you added it in Command Mode"
        case .typedReady: "you typed it into Ready on this board"
        default: "you said it to Binders on your iPhone"
        }
        return "Binders handed this to \(agent) without asking: \(from), and it's clearly \(agent)'s work. "
            + "Stop it here, or turn off Start on cards Binders sends it for \(agent) in Settings → Agents."
    }

    /// The card's note for a hand-over in Auto (AutoText.note): it begins as `startNote` does, which is what Stop on the
    /// card looks for, and says that Auto skips only Binders' own question, for you and for the agent, who reads it too.
    /// "Looks like", as `why` says below the start level. The time is this Mac's, as the card's own times are.
    static func autoNote(agent: String, origin: RouteOrigin, idea: Bool, heard: Date, named: Bool) -> String {
        AutoText.note(agent: agent, idea: idea, asked: origin == .moment, named: named, heard: heard, now: Date())
    }

    /// Stop, or Undo, of a start: the card goes back to Backlog meant for no one, by you, and a run Binders started for it
    /// stops. Nothing running for it (a web hook or a Shortcut, a command that has rung its agent and ended, a post to
    /// your open Claude Code session): the agent has the card already and Binders can't fetch it back, so it's only moved
    /// back, and the line says so. Never woken: it's moved back, and the line says that. Once the agent has finished
    /// (Review or Done), nothing changes. The words for what happened, and whether anything did.
    func stopStarted(_ card: TaskCard, agent name: String) -> (changed: Bool, line: String, title: String, short: String) {
        guard let controller else { return (false, "Binders is shutting down", "Not stopped", "Binders is shutting down") }
        let binder = Store.shared.binder(card.binderID)?.name ?? "General"
        if card.column == .review || card.column == .done {
            let line = "\(name) has finished it: it's in \(card.column.title) on the \(binder) board."
            return (false, line, "Finished", line)
        }
        let agent = AgentRegistry.shared.agents.first { AgentRegistry.isAgent($0, named: name) }
        // What was going on for it, before Stop changes that.
        let running = controller.agents.isBusy(on: card.id)
        let woke = handedOver(card, to: name)
        controller.agents.stop(card.id)
        controller.board.assign(card, to: nil, by: .you)
        try? controller.board.move(card, to: .backlog, by: .you)
        log.outcome("stopped", card: card.id, todo: card.sourceRef, to: agent?.id)
        if running {
            return (true, "Stopped \(name). “\(card.title)” waits in the \(binder) board's Backlog.", "Stopped \(name)",
                    "Stopped \(name). “\(card.title)” waits in Backlog.")
        }
        if woke {
            return (true, "\(name) already has the card. Binders moved “\(card.title)” back to the \(binder) board's Backlog.", "Moved back to Backlog",
                    "\(name) already has the card. Binders moved it back to Backlog.")
        }
        return (true, "\(name) wasn't woken, so Binders moved “\(card.title)” back to the \(binder) board's Backlog.", "Moved back to Backlog",
                "\(name) wasn't woken, so Binders moved it back to Backlog.")
    }

    /// Whether Binders' note on the card says it handed the card to `name` without a tap (not that it meant to and couldn't).
    private func handedOver(_ card: TaskCard, to name: String) -> Bool {
        controller?.board.timeline(card.id).contains {
            $0.kind == .comment && $0.author == BoardService.binders.name && $0.text.hasPrefix("Binders handed this to \(name) without asking")
        } ?? false
    }

    /// The agent Binders handed this card to without a tap, while it's still meant for it; nil for one you gave.
    func startedBy(_ card: TaskCard) -> String? {
        guard let name = card.meantFor, !card.meantForByAgent, let board = controller?.board else { return nil }
        let timeline = board.timeline(card.id)
        guard let last = timeline.last(where: { $0.kind == .assigned }), last.author == BoardService.binders.name, last.text == "Meant for \(name)." else { return nil }
        return handedOver(card, to: name) ? name : nil
    }

    /// Whether the card's page offers Stop: while a run Binders started works on it, and for a card Binders handed over
    /// without a tap, whatever kind of agent has it (the start's note says "Stop it here"). Not once the agent has finished
    /// it (Review or Done), where Stop would change nothing.
    func showsStop(_ card: TaskCard) -> Bool {
        guard card.column != .review, card.column != .done else { return false }
        return (controller?.agents.isWorking(on: card.id) ?? false) || startedBy(card) != nil
    }

    /// Move to, on a card: its board changes, with its to-do, and Binders' own suggestion goes if the new binder's agents
    /// don't include that one. The router's record notes it.
    func move(_ card: TaskCard, to binder: BinderRecord) throws {
        guard let board = controller?.board else { return }
        let registry = AgentRegistry.shared
        try board.moveBinder(card, to: binder, by: .you) { name, binderID in
            registry.agent(named: name)?.takesCards(from: binderID) ?? false
        }
        log.outcome("moved", card: card.id, todo: card.sourceRef, to: binder.id)
    }

    /// Move to, on a to-do of its own: it moves to the binder, and its card with it.
    func moveTodo(_ id: UUID, to binder: BinderRecord, card: TaskCard?) {
        if let card {
            do { try move(card, to: binder) } catch {
                controller?.flowBar.toast(error.localizedDescription, symbol: BindersTheme.problemSymbol, duration: 5)
            }
            return
        }
        guard let commitment = Store.shared.commitments().first(where: { $0.id == id }), commitment.binderID != binder.id else { return }
        commitment.binderID = binder.id
        Store.shared.save()
        log.outcome("moved", todo: id.uuidString, moment: id, to: binder.id)
    }

    /// What the flow bar says once Stop stopped a start on this Mac.
    func stopLine(_ card: TaskCard, agent name: String) -> String {
        stopStarted(card, agent: name).short
    }

    // MARK: The tuning log

    /// One decision, for the log.
    struct Decision {
        let id = UUID()
        var origin: RouteOrigin
        var kind: RouteKind
        var answer: ModelAnswer?
        var binder: BinderPick?
        var agent: AgentPick?
        var llmBinder: UUID?
        var did = "filed"
        var whyNotStarted: String?
        var card: UUID?
        var todo: String?
        var moment: UUID?
        /// For a moment from an iPhone that sends one, its mode as sent (MomentPayload.mode).
        var mode: String?
    }

    func record(_ decision: Decision) {
        let registry = AgentRegistry.shared
        func agentID(_ key: String) -> String {
            key == RouterQuestions.nobody ? key : registry.agents.first { $0.name == key }?.id.uuidString ?? "unknown"
        }
        let answer = decision.answer
        let binderTop = answer?.binderAnswer.map { ranked in
            ranked.sorted { $0.p > $1.p }.prefix(5).map { RouterLogEntry.Ranked(id: $0.id.uuidString, p: $0.p) }
        }
        let agentTop = answer?.agentAnswer.map { ranked in
            ranked.sorted { $0.p > $1.p }.prefix(5).map { RouterLogEntry.Ranked(id: agentID($0.key), p: $0.p) }
        }
        let leftOut = (answer?.binders?.leftOut.count ?? 0) + (answer?.agents?.leftOut.count ?? 0)
        let entry = RouterLogEntry(
            id: decision.id, origin: decision.origin.rawValue, kind: decision.kind.rawValue, backend: answer?.identity.reader,
            model: answer?.identity.fingerprint, bands: answer?.source.logName, ms: answer?.ms,
            form: answer?.binders?.form.rawValue,
            binder: decision.binder.map { RouterLogEntry.Pick(id: $0.id.uuidString, how: $0.how.rawValue, p: $0.p, top: binderTop) },
            agent: decision.agent.map { pick in
                RouterLogEntry.Pick(id: registry.agents.first { $0.name == pick.name }?.id.uuidString, how: pick.how.rawValue, p: pick.p, top: agentTop)
            } ?? (agentTop.map { RouterLogEntry.Pick(id: nil, how: nil, top: $0) }),
            llmBinder: decision.llmBinder, did: decision.did,
            whyNotStarted: decision.whyNotStarted ?? (answer == nil ? lastFailure.map { "router model: \($0)" } : nil),
            leftOut: leftOut > 0 ? leftOut : nil, card: decision.card, todo: decision.todo, moment: decision.moment, mode: decision.mode)
        log.write(entry)
    }

    /// Whether a start that didn't happen is worth its reason in the log: the model's pick reached the start bar, or the agent is
    /// one you let start.
    func keepsWhy(_ pick: AgentPick, answer: ModelAnswer?) -> Bool {
        if let bar = answer?.bands.start, let top = answer?.agentTop, top.key == pick.name, top.p >= bar { return true }
        return AgentRegistry.shared.agent(named: pick.name)?.autoStart == true
    }

    // MARK: Cards you type

    /// A card you typed on a board: made at once, in that board's binder. Then, for one in Ready or Backlog, the agent
    /// whose work it is a moment later: named in the title, else the model's pick. In Ready, an agent you let start on its own
    /// is handed it; otherwise, and in Backlog, it's suggested. In the other columns you're on it, or it waits on someone,
    /// so no agent. Without the model, only an agent you named is suggested, as before the router there was none.
    @discardableResult
    func typedCard(title: String, binder: BinderRecord, column: BoardColumn) -> TaskCard? {
        guard let board = controller?.board else { return nil }
        let card = board.create(title: title, binderID: binder.id, column: column == .done ? .backlog : column, by: .you)
        guard card.column == .ready || card.column == .backlog else { return card }
        let id = card.id, typed = card.title, origin: RouteOrigin = card.column == .ready ? .typedReady : .typedBacklog
        Task { await routeCard(id, title: typed, origin: origin) }
        return card
    }

    /// A card made some other way: from the iPhone, over MCP, with Add to Board or Put on Board, or from a capture. The
    /// agent whose work it is is suggested a moment later, and never started without your tap. Only your own typing names
    /// one (RouteOrigin.typedByYou): an agent's, a tool's or a capture's words, and a to-do's or a note's put on the board,
    /// are read by the model alone. A card put on the board from a note is read by its title and the start of its details
    /// (`DistillWhoState.cardState`, lane AS1); the others by their title, as before.
    func suggestLater(for card: TaskCard, origin: RouteOrigin) {
        guard card.meantFor == nil, card.column == .ready || card.column == .backlog else { return }
        let id = card.id, title = card.title
        let state = Self.state(for: card, origin: origin)
        Task { await routeCard(id, title: title, origin: origin, state: state) }
    }

    /// What the decision model reads to suggest who a card is for: for Put on Board from a note, its title and the start of
    /// its details; else nil, its title alone.
    static func state(for card: TaskCard, origin: RouteOrigin) -> String? {
        guard origin == .toBoard, card.distilledFrom?.put == true else { return nil }
        return DistillWhoState.cardState(title: card.title, details: card.details)
    }

    /// For the self-tests: the same as `typedCard`'s and `suggestLater`'s work, awaited. `state`: what the decision model
    /// reads, when it's more than the title.
    func routeCard(_ id: UUID, title: String, origin: RouteOrigin, state: String? = nil) async {
        let library = gather()
        // A name counts as one you named only in words you typed: never an agent's, a tool's or a capture's.
        let named = origin.typedByYou ? NamedAgents.find(in: [title], agents: library.agentNames) : []
        let answer = await ask(state ?? title, binder: false, agent: true, library: library)
        guard answer != nil || !named.isEmpty, let board = controller?.board, let card = board.card(id) else { return }
        let binderName = Store.shared.binder(card.binderID)?.name ?? "General"
        let binderID = card.binderID ?? Store.shared.defaultBinder().id
        var decision = Decision(origin: origin, kind: .card, answer: answer, binder: BinderPick(id: binderID, how: .named), card: id)
        let outcome = agentOutcome(kind: .card, named: named, answer: answer, binder: binderID, agentFit: false)
        if let pick = outcome.pick {
            decision.agent = pick
            var why = whyNotStart(pick, answer: answer, binder: binderID, origin: origin, kind: .card, named: named)
            var card = card
            if why == nil, let answer {
                // Right before the start: still the model that decided. The card is read again after, as it may have gone.
                why = await models.confirm(answer, by: .now + .seconds(2))
                guard let again = board.card(id) else { return record(decision) }
                card = again
            }
            if why == nil, let agent = AgentRegistry.shared.agent(named: pick.name) {
                switch start(card, agent: agent, origin: origin, title: title) {
                case .woke:
                    decision.did = "started"
                    // What happened first, the title last: the bar's two lines may cut the title, never the agent.
                    controller?.flowBar.showPrompt("Binders handed \(agent.name) “\(card.title)”.", button: "Stop", symbol: "arrow.right.circle") { [weak self] in
                        guard let self, let card = self.controller?.board.card(id) else { return }
                        self.controller?.flowBar.toast(self.stopLine(card, agent: agent.name), symbol: "stop.circle", duration: 5)
                    }
                case .notWoken:
                    decision.did = "suggested"
                    decision.whyNotStarted = "not woken"
                case .changed:
                    decision.did = "suggested"
                    decision.whyNotStarted = RouterRules.NotStarted.changedSince.rawValue
                    if card.meantFor == nil { suggest(card, pick) }
                }
            } else {
                suggest(card, pick)
                decision.did = "suggested"
                if let why, keepsWhy(pick, answer: answer) { decision.whyNotStarted = why.rawValue }
            }
        } else if let notTaker = outcome.notTaker {
            board.note(card, text: "\(notTaker) doesn't take cards from the \(binderName) board, so Binders didn't suggest it. Change that in Settings → Agents.")
            decision.did = "named-not-taker"
        } else if let waiting = outcome.cantTakeNow {
            board.note(card, text: Self.cantTakeNow(waiting))
            decision.did = "named-not-now"
        }
        record(decision)
    }

    /// The binder for a card an agent or a tool makes over MCP without naming one: the model's pick at its General threshold,
    /// else the current binder (create_task's documented default). With the decision, for the log.
    func binderForMCP(title: String) async -> (binder: BinderRecord, decision: Decision?) {
        let current = Store.shared.binder(AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder()
        let library = gather()
        guard let answer = await ask(title, binder: true, agent: false, library: library), let form = answer.binders?.form else { return (current, nil) }
        let pick = RouterRules.binder(named: nil, model: answer.binderAnswer, form: form, bands: answer.bands, llm: nil, fallback: current.id)
        let binder = library.binder(pick.id) ?? Store.shared.binder(pick.id) ?? current
        return (binder, Decision(origin: .mcp, kind: .card, answer: answer, binder: pick))
    }

    // MARK: Command Mode

    /// "Add to-do …" in Command Mode, decided: where it goes, the agent whose work it is, and whether it starts. Nothing is
    /// made yet, so Esc meanwhile adds nothing.
    struct CommandTodo {
        var phrase: String
        var binder: BinderRecord
        var how: BinderPick.How
        var outcome: RouterRules.AgentOutcome
        var start: Bool
        var decision: Decision
    }

    func decideCommandTodo(_ phrase: String) async -> CommandTodo {
        let library = gather()
        let open = Store.shared.binder(AppSettings.shared.currentBinderID) ?? library.general
        let reading = MomentRules.read(phrase, binders: library.named.map(\.name), agents: library.agentNames, heard: Date(), wake: true)
        let rules = reading.binder.flatMap { name in library.named.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
        // With the binder named in it, the to-do is the rules' words, without the binder's; the time said stays with it.
        var said = phrase
        if rules != nil, reading.kind == .todo, !reading.text.isEmpty { said = reading.text + (reading.due.map { " " + $0 } ?? "") }
        let named = NamedAgents.find(in: [phrase, reading.text], agents: library.agentNames)
        let answer = await ask(phrase, binder: rules == nil, agent: true, library: library)
        let pick = RouterRules.binder(named: rules?.id, model: answer?.binderAnswer, form: answer?.binders?.form ?? .both, bands: answer?.bands,
                                      llm: nil, fallback: open.id)
        let binder = library.binder(pick.id) ?? open
        // Without the model's answer, only an agent you named: Command Mode never offered one before the router, and being the
        // only agent that takes the binder's cards isn't a reason to give it the card.
        let outcome = agentOutcome(kind: .todo, named: named, answer: answer, binder: binder.id, agentFit: false)
        var decision = Decision(origin: .commandMode, kind: .todo, answer: answer, binder: pick, agent: outcome.pick)
        var start = false
        if let chosen = outcome.pick {
            var why = whyNotStart(chosen, answer: answer, binder: binder.id, origin: .commandMode, kind: .todo, named: named)
            // Right before the start: still the model that decided.
            if why == nil, let answer { why = await models.confirm(answer, by: .now + .seconds(2)) }
            start = why == nil
            decision.did = start ? "started" : "suggested"
            if let why, keepsWhy(chosen, answer: answer) { decision.whyNotStarted = why.rawValue }
        } else if outcome.notTaker != nil {
            decision.did = "named-not-taker"
        } else if outcome.cantTakeNow != nil {
            decision.did = "named-not-now"
        }
        return CommandTodo(phrase: said, binder: binder, how: pick.how, outcome: outcome, start: start, decision: decision)
    }

    /// Carries a Command Mode to-do out: the to-do in its binder, then the flow bar: the toast, the Give to prompt for the
    /// agent whose work it is, or, for a start, the line with Stop.
    func addCommandTodo(_ plan: CommandTodo) -> String {
        guard let controller else { return "" }
        var decision = plan.decision
        let added = controller.commitments.addSpoken(plan.phrase, binderID: plan.binder.id, toast: false)
        let todo = added.commitment
        decision.todo = todo.id.uuidString
        let due = todo.dueAt.map { " · \(CommitmentService.dueLabel($0))" } ?? ""
        let place = plan.how == .model ? "Added to \(plan.binder.name), Binders' pick" : "Added to \(plan.binder.name)"
        var line = "\(place): \(todo.task)\(due)"
        if let pick = plan.outcome.pick {
            if plan.start, let agent = AgentRegistry.shared.agent(named: pick.name), let item = Todos.find(todo.id.uuidString) {
                let card = controller.board.create(from: item, column: .ready, binderID: plan.binder.id, by: .you).card
                decision.card = card.id
                switch start(card, agent: agent, origin: .commandMode, title: card.title) {
                case .woke:
                    // What happened first, the to-do last: the bar's two lines may cut its words, never the agent.
                    line = "Added to \(plan.binder.name). Binders handed it to \(agent.name): \(todo.task)."
                    let id = card.id
                    if !controller.flowBar.showPrompt(line, button: "Stop", symbol: "arrow.right.circle", onAccept: { [weak self] in
                        guard let self, let card = self.controller?.board.card(id) else { return }
                        self.controller?.flowBar.toast(self.stopLine(card, agent: agent.name), symbol: "stop.circle", duration: 5)
                    }) {
                        controller.flowBar.toast(line, symbol: "arrow.right.circle", duration: 5)
                    }
                    record(decision)
                    return line
                case .notWoken:
                    decision.did = "suggested"
                    decision.whyNotStarted = "not woken"
                case .changed:
                    decision.did = "suggested"
                    decision.whyNotStarted = RouterRules.NotStarted.changedSince.rawValue
                }
                controller.flowBar.toast(line, symbol: "checklist", duration: 5)
                record(decision)
                return line
            }
            // Give to, one tap away in the flow bar's prompt.
            let prompt = "Added to \(plan.binder.name): \(todo.task). Give to \(pick.name)?"
            let todoID = todo.id.uuidString, binderID = plan.binder.id, name = pick.name
            let shown = controller.flowBar.showPrompt(prompt, button: "Give to \(pick.name)", symbol: "person.crop.circle.badge.checkmark") { [weak self] in
                guard let self, let controller = self.controller, let item = Todos.find(todoID) else { return }
                let card = controller.board.create(from: item, column: .ready, binderID: binderID, by: .you).card
                controller.board.give(card, to: name, by: .you)
                controller.flowBar.toast("Gave “\(card.title)” to \(name).", symbol: "checkmark.circle", duration: 4)
            }
            if !shown { controller.flowBar.toast(line, symbol: "checklist", duration: 5) }
            record(decision)
            return shown ? prompt : line
        }
        if let notTaker = plan.outcome.notTaker {
            line += ". \(notTaker) doesn't take \(plan.binder.name)'s cards: change that in Settings → Agents."
        } else if let waiting = plan.outcome.cantTakeNow {
            line += ". " + Self.cantTakeNow(waiting)
        }
        controller.flowBar.toast(line, symbol: "checklist", duration: 5)
        if decision.answer != nil || plan.outcome.notTaker != nil || plan.outcome.cantTakeNow != nil || plan.how == .named { record(decision) }
        return line
    }
}
