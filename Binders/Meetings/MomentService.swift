import Foundation
import SwiftData
import BindersKit

/// Something you said to yourself near your iPhone, a moment: only the sentence comes, read here with the rules (one short
/// model call when they can't tell, which also files it), then acted on or offered. A to-do goes into its binder, an idea
/// onto its board's Backlog, a note into a binder of yours, a question is answered from your binders, "what's happening"
/// gets the boards' digest. Said with "Binders, …" it's done at once, with Undo; heard on its own, it's offered (Add, Not
/// Now), unless it's of a kind you've let the iPhone add at once (MomentPayload.adds, MomentGraduation): then it's done at
/// once too, with Undo, but runs no automation, and one meant for an agent is still offered. Where it goes and the agent
/// whose work it is come from the card router (CardRouter): the rules, then the decision model chosen in Settings → AI
/// when it can be used (asked at once, while the classify call runs), then the model calls below, then General. A to-do
/// or an idea done comes with Give to, naming that agent; one you named that doesn't take the binder's cards is named with
/// why, and no Give to. Nothing from a moment wakes or assigns an agent without your tap, except a "Binders, …" said on
/// its own, in your voice, for an agent you let start on cards Binders sends it, when the decision model is sure it's that
/// agent's work at its own start level (RouterRules.mayStart), and is still the model that decided (DecisionModels.confirm);
/// and, from an iPhone in Auto (MomentPayload.mode), a to-do or an idea you said on your own in your voice, added at once
/// and handed to the agent the model picks at its Auto level, or the one you named, when every condition of
/// RouterRules.mayHandOver holds, with Stop, Undo and Not Me. Suggest and Add at Once hand nothing over.
///
/// Each moment is kept as a record (mode "moment", status "answered"), which keeps it out of search, MCP and paste, with
/// its state, so one sent again gets the same answer and nothing is done twice. The record keeps its timings too: when it
/// was heard, reached this Mac and was decided, and how long writing it down and the model took.
@MainActor
final class MomentService {
    weak var controller: DictationController?
    /// Moments being decided, with what the phone sent.
    private var working: [UUID: (task: Task<CaptureOutcome, Never>, payload: MomentPayload)] = [:]
    /// The model the short calls go to: the one set up in Settings. The self-test puts a stand-in here, so what's done
    /// with a reply is checked without a model.
    var model: @MainActor () -> LLMClient? = { AppSettings.shared.makeLLMClient() }
    /// Hand-overs in Auto being decided now: what, to whom, where and when it was said, taken before anything is awaited,
    /// so two moments decided together can't both hand the same thing over. Given back when it doesn't happen, and once
    /// the moment's record keeps it.
    private var handing: [UUID: (task: String, agent: String, binder: UUID, heard: Date)] = [:]
    /// The late ones among them, counted towards how many late words Auto hands over at once.
    private var lateTaken: Set<UUID> = []
    /// Lane Y2: the ids of a capture's items, which aren't moments said in it.
    private var items: Set<UUID> = []
    /// The devices paired with this Mac now, for whether Auto from an iPhone may hand over (AutoPhones): the link's. A
    /// self-test gives its own link's.
    var pairedDevices: @MainActor () -> [UUID]

    init(controller: DictationController) {
        self.controller = controller
        pairedDevices = { [weak controller] in controller?.link.devices.map(\.id) ?? [] }
    }

    /// What a moment was read as, what became of it, and what it made.
    struct State: Codable {
        var kind: String
        var acts: Bool
        var task: String
        var due: Date?
        var dueText: String?
        var binderID: UUID?
        var said: String
        var outcome: CaptureOutcome
        /// What it made: the to-do's id (list_todos's), the card's, the note's.
        var todo: String?
        var card: UUID?
        var note: UUID?
        /// Who Assign gives it to, when one agent fits.
        var agent: String?
        /// How long it took, as the phone and this Mac saw it. Optional, so moments kept before it still read.
        var timings: MomentTimings?
        /// Added at once because its kind graduated on the iPhone, not because you asked or tapped Add: so no automation
        /// ran for it. Optional, as above.
        var graduated: Bool?
        /// The conversation it was said in (MomentPayload.conversation), whose write-up leaves its words out. Optional, as
        /// above.
        var conversation: UUID?
        /// Binders handed its card to an agent without a tap, or meant to and the agent wasn't woken (`agent` names it):
        /// Undo takes the card back to Backlog. Optional, as above.
        var started: Bool?
        /// The router's decision for it, in the tuning log. Optional, as above.
        var route: UUID?
        /// The iPhone's mode when it was heard (MomentPayload.mode), from an iPhone that sends one. Optional, as above.
        var mode: String?
        /// Binders handed its card over in Auto, woken or not (`started` is set too). Optional, as above.
        var auto: Bool?
        /// In Auto, it reached this Mac late (AutoRules.isLate) when it was decided. Optional, as above.
        var late: Bool?
        /// Stop was used on it: its run stopped and its card went back to Backlog. Optional, as above.
        var stopped: Bool?
        /// The paired iPhone it came from (LinkDevice's id), when the link said. Optional, as above.
        var device: UUID?
        /// Lane Y2, Optional as above: read from this capture, in which your iPhone heard only you (an item; its id is
        /// SoloReading.itemID's); the capture a moment said in it waits for, until it's decided there; the moment's own
        /// hold and whether it was a "Binders, …", for its hand-over at its capture; and that it was decided at its capture.
        var solo: UUID?
        var joins: UUID?
        var hold: String?
        var wake: Bool?
        var joined: Bool?

        /// The outcome as the phone gets it, with the timings and what it was read as, whatever has happened to it since.
        /// The kind lets the phone say what was done without the words, on a Lock Screen that shows previews. For an iPhone
        /// that sends a mode, whether it came late, so the iPhone says when it was said, in its own time zone.
        var told: CaptureOutcome {
            var told = outcome
            told.timings = told.timings ?? timings
            told.kind = told.kind ?? kind
            if mode != nil, late == true { told.late = true }
            told.joins = joins
            return told
        }

        /// Handed over without a tap from an iPhone that sends a mode: by Auto, or by the start rule ("Binders, …"). Both
        /// count as one thing handed over, so the same thing said again isn't handed over twice (AutoRules.repeatWithin).
        var handedWithoutTap: Bool { auto == true || (started == true && mode != nil) }

        /// From a capture (an item, or a moment that went with it): every hand-over takes a place among Auto's five in ten
        /// minutes, late or not (lane Y2).
        var fromCapture: Bool { solo != nil || joined == true }
    }

    /// Lane Y2: one thing read from a capture in which your iPhone heard only you, decided as a moment of its own.
    struct SoloItem {
        var capture: UUID
        var item: SoloReading.Item
        /// Where the capture's write-up filed it, which the item falls back to.
        var binder: UUID?
        /// The capture's mode as it stands now, read again right before the hand-over (Turn Off Auto can land mid-way).
        var modeNow: @MainActor () -> MomentMode
    }

    /// A question is answered only while it's fresh: one kept on the iPhone for an hour isn't worth answering now.
    static let freshFor: TimeInterval = 15 * 60

    /// Why a note wasn't kept: a note made from what you said never goes into a binder shared with your team.
    static let everyBinderShared = "Every binder is shared with your team, so it wasn't kept as a note."

    // MARK: Receiving

    /// The outcome of a moment, deciding it the first time: a moment sent again (its reply lost) gets what it got before.
    /// `device`: the paired iPhone it came from, as the link knows it.
    /// `soloAuto`: the phone's hello listed ConversationPayload.soloFeature (lane Y2); `solo`: an item read from a capture.
    func receive(_ payload: MomentPayload, from device: UUID? = nil, soloAuto: Bool = false, solo: SoloItem? = nil) async -> CaptureOutcome {
        if let state = state(payload.id) { return state.told }
        if let running = working[payload.id] { return await running.task.value }
        if solo != nil { items.insert(payload.id) }
        let task = Task { await handle(payload, from: device, soloAuto: soloAuto, solo: solo) }
        working[payload.id] = (task, payload)
        let outcome = await task.value
        working[payload.id] = nil
        return outcome
    }

    /// Its outcome as it stands, for binders/outcomes; nil when no such moment is here. One still being decided says who has
    /// it and what comes next, as an iPhone before MomentWait shows the line as it is.
    func outcome(_ id: UUID) -> CaptureOutcome? {
        if working[id] != nil { return CaptureOutcome(id: id, state: "working", line: MomentWait.working, title: "Working on it") }
        // A moment waiting for its capture, which didn't come within Auto's 12 hours: it stays added, and says so.
        if var state = state(id), state.joins != nil, let heard = record(id)?.createdAt, Date().timeIntervalSince(heard) > AutoRules.horizon {
            state.outcome.line = AutoText.joined(Self.withoutJoinLine(state.outcome.line), AutoText.joinedNoCapture)
            state.joins = nil
            save(state, id: id)
            return state.told
        }
        return state(id)?.told
    }

    /// The words of the moments said in a conversation (MomentPayload.conversation), heard between `start` and `end`, which
    /// its write-up leaves out (ConversationService.writeUp): those still being decided, and those acted on, offered or
    /// answered, taken back since or not. One this Mac did nothing with ("Heard too long ago to answer now", say) stays in
    /// the conversation.
    func said(in conversation: UUID, from start: Date, to end: Date) -> [String] {
        let mode = "moment"
        let records = (try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate {
            $0.mode == mode && $0.createdAt >= start && $0.createdAt <= end
        }))) ?? []
        let decided = records.compactMap { record -> String? in
            // A capture's own items aren't moments said in it.
            guard let state = try? JSONDecoder().decode(State.self, from: EarlierSpellings.json(Data(record.outcomeJSON.utf8))), state.conversation == conversation,
                  state.outcome.state != "nothing", state.solo == nil else { return nil }
            return state.said
        }
        return decided + working.values.filter { $0.payload.conversation == conversation && !items.contains($0.payload.id) }.map(\.payload.text)
    }

    private func handle(_ payload: MomentPayload, from phone: UUID?, soloAuto phoneSolo: Bool = false, solo: SoloItem? = nil) async -> CaptureOutcome {
        // It reached this Mac now: where its timings go on from the phone's.
        let reached = Date()
        guard let controller else { return nothing(payload.id, "Binders is shutting down") }
        if Store.shared.isFallback { return nothing(payload.id, "Your Mac couldn't open its library.") }
        let binders = Store.shared.binders().filter { !$0.isTeamCopy && !$0.archived }
        let registry = AgentRegistry.shared
        let profiles = registry.agents.filter(\.isEnabled)
        let agents = profiles.map(\.name)
        // The agents as the model sees them: with what each is for and the binders whose cards it takes.
        let agentHints = hints(profiles)
        let said = DictionaryMatcher.apply(Store.shared.vocabulary(), to: payload.text.trimmed).text
        // Asked through Siri's "Ask Binders" (the only one that sends kind question): answered, never added.
        let asking = payload.kind == MomentKind.question.rawValue
        var reading = MomentRules.read(said, binders: binders.map(\.name), agents: agents, heard: payload.heard, wake: payload.wake ?? false,
                                       asking: asking)
        // Lane Y2: an item read from a capture comes with its kind and title; the rules read only the binder you named.
        if let solo {
            reading.kind = solo.item.momentKind
            reading.text = solo.item.title
            reading.woke = false
        }
        // Read as thinking out loud (an item, or a sentence kept without a cue): names only when said as meant.
        let thinkingAloud = solo != nil || payload.uncued != nil
        // The binder you named, as the rules found it, kept apart from the one the classify call names.
        let rulesBinder = reading.binder.flatMap { name in binders.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
        var classifyBinder: BinderRecord?
        // Tev1, asked at once while the classify call runs, for anything that may be filed: its part never takes more than
        // its budget, so a moment never stays "working" because of it.
        let routable = !asking && [nil, MomentKind.todo, MomentKind.idea, MomentKind.note].contains(reading.kind)
        let router = controller.router
        let tev1: Task<CardRouter.ModelAnswer?, Never>? = routable ? {
            let library = router.gather()
            // The decision model is asked an item's title, short and in the form of the bench's cards.
            let question = solo?.item.title ?? said
            return Task { await router.ask(question, binder: rulesBinder == nil, agent: true, library: library) }
        }() : nil
        var usedModel: String?
        var modelMillis = 0
        // The one call below filed it too: no second call to route it.
        var filed = false
        // The agent the model says it was meant for, and the one it says it fits; and what its AGENT line wrote, kept apart,
        // for one it gave to someone who isn't one of your agents.
        var meantFor: String?
        var meantForWritten: String?
        var fits: String?
        if reading.kind == nil || reading.kind == MomentKind.none, asking {
            reading.kind = .question
            reading.searchQuery = reading.searchQuery ?? reading.text
        }
        // The rules' reading of your words, before the classify call below may write its own.
        let rulesText = reading.text
        // The rules couldn't tell: one short call, in the fast lane, that sorts it and files it, knowing your agents. The
        // model never decides a date.
        if reading.kind == nil, let client = model() {
            usedModel = client.model
            let began = Date()
            // A sentence kept without a cue: the to-do kind also takes a fix (lane Y2).
            let system = MomentPrompts.classifySystemPrompt(binders: hints(binders), agents: agentHints, fixes: payload.uncued != nil)
            let output = try? await client.complete(system: system, user: reading.text, maxTokens: 120, temperature: 0, timeout: 10)
            modelMillis += Self.millis(since: began)
            if let output {
                let parsed = MomentPrompts.parseClassification(output)
                filed = true
                reading.kind = parsed.kind ?? MomentKind.none
                classifyBinder = parsed.binder.flatMap { name in binders.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
                if let text = parsed.text, !text.isEmpty { reading.text = text }
                if let due = parsed.due, let date = CommitmentDetection.dueDate(from: due, relativeTo: payload.heard) {
                    reading.due = due
                    reading.dueAt = date
                }
                meantFor = MomentPrompts.agent(parsed.agent, among: agents)
                meantForWritten = parsed.agent
                fits = MomentPrompts.agent(parsed.fits, among: agents)
            }
        }
        let kind = reading.kind ?? MomentKind.none
        // You asked: "Binders, …", Siri, or the wake word the rules found.
        let asked = payload.wake == true || reading.woke
        // Heard on its own, of a kind you've let the iPhone add at once. Never a question or a status request.
        let graduated = !asked && MomentGraduation.kinds.contains(kind) && (payload.adds ?? []).contains(kind.rawValue)
        var state = State(kind: kind.rawValue, acts: asked, task: reading.text, due: reading.dueAt, dueText: reading.due, binderID: nil, said: payload.text,
                          outcome: CaptureOutcome(id: payload.id, state: "nothing", line: "", settled: true), conversation: payload.conversation)
        state.mode = payload.mode
        state.device = phone
        state.solo = solo?.capture
        state.hold = payload.autoHold
        state.wake = payload.wake
        // For a question or a status request, the binder it named, as before: the rules', else the classify call's.
        let named = rulesBinder ?? classifyBinder
        // Heard by an iPhone in Auto. Never from Siri, a Shortcut or a transcript: those send no mode.
        let inAuto = payload.mode == MomentMode.auto.rawValue
        // Said in a conversation; not one said on its own that took the words of the conversation that opened at its
        // first word (`alone`), whatever its id says.
        let inConversation = payload.conversation != nil && payload.alone != true
        // Lane Y2: said in a capture while the iPhone was in Auto, from a phone that vouches for captures: it waits for
        // its capture, and goes with it if only you spoke in it (`rejoin`).
        let waitsForCapture = solo == nil && phoneSolo && inAuto && inConversation

        switch kind {
        case .todo, .idea, .note:
            let answer = await tev1?.value
            // The agents named in what was said, or in the rules' to-do ("remind me to give the plan to Pennant").
            // An item's names are read on its own sentences only, never its title (lane Y2).
            let spoken = NamedAgents.find(in: solo != nil ? [said] : [said, reading.text], agents: agents, thinkingAloud: thinkingAloud)
            // In Auto a name decides only when you said it: in your words, or the rules' reading of them. One only the
            // classify call wrote ("Ask Codex to fix…" for words that named no agent) can at most narrow the choice: it keeps
            // the card from every other agent, and the model's pick and Auto's bar still decide.
            let yours = NamedAgents.find(in: solo != nil ? [said] : [said, rulesText], agents: agents, thinkingAloud: thinkingAloud)
            // The reading's fourth field: always an agent its sentences mention; it can only narrow who gets it.
            if let solo, let written = solo.item.agent {
                meantFor = MomentPrompts.agent(written, among: agents)
                meantForWritten = written
            }
            let autoNamed = spoken.filter(yours.contains)
            let writtenIn = spoken.filter { !yours.contains($0) }
            var routedByModel = false
            var routeBinder: BinderRecord?
            // The binder: the rules', else Tev1's at the General threshold, else the model's (the classify call that
            // filed it, or one route call when Tev1 is unsure or missing), else General.
            let form = answer?.binders?.form ?? .both
            let sure = RouterRules.modelBinder(answer?.binderAnswer, form: form, bands: answer?.bands)
            if rulesBinder == nil, sure == nil, !filed, binders.count > 1, let route = await route(reading.text, kind: kind, among: binders, agents: agentHints) {
                routedByModel = true
                routeBinder = route.binder
                if meantFor == nil {
                    meantFor = route.agent
                    meantForWritten = meantForWritten ?? route.written
                }
                fits = route.fits
                usedModel = usedModel ?? route.model
                modelMillis += route.millis
            }
            let llmBinder = filed ? classifyBinder : routeBinder
            let general = Store.shared.defaultBinder()
            // An item falls back to its capture's own binder, where its write-up filed it, not General.
            let fallback = solo?.binder.flatMap { id in binders.first { $0.id == id } } ?? general
            let pick = RouterRules.binder(named: rulesBinder?.id, model: answer?.binderAnswer, form: form, bands: answer?.bands, llm: llmBinder?.id,
                                          fallback: fallback.id)
            var binder = binders.first { $0.id == pick.id } ?? fallback
            // A note made from what you said never goes into a binder shared with your team: into one of yours that isn't,
            // or nowhere.
            if kind == .note, binder.sharedWithTeam || binder.isTeamCopy {
                guard let own = binders.first(where: { !$0.sharedWithTeam && !$0.isTeamCopy }) else {
                    if asked {
                        state.outcome = CaptureOutcome(id: payload.id, state: "answered", line: Self.everyBinderShared, title: "Not kept", settled: true)
                    }
                    break
                }
                binder = own
            }
            state.binderID = binder.id
            // An item that's already an open card or to-do there: nothing new (lane Y2).
            if solo != nil, let there = alreadyThere(reading.text, binder: binder.id) {
                state.outcome = CaptureOutcome(id: payload.id, state: "nothing", line: AutoText.alreadyThere(binder: binder.name, title: there.title),
                                               title: "Already on the \(binder.name) board", settled: true, binder: binder.name, card: there.card)
                break
            }
            // Without Tev1's answer, the agent as before: with several that could take it from its binder and none named,
            // which one it fits, from the call that filed it, or else one short call that sees only that binder.
            let takers = registry.takers(for: binder.id).map(\.name)
            if kind != .note, spoken.isEmpty, meantFor == nil, !filed, !routedByModel, answer?.agentAnswer == nil, takers.count > 1,
               let route = await route(reading.text, kind: kind, among: [binder], agents: agentHints) {
                meantFor = route.agent
                meantForWritten = route.written
                fits = route.fits
                usedModel = usedModel ?? route.model
                modelMillis += route.millis
            }
            let routeKind: RouteKind = kind == .todo ? .todo : kind == .idea ? .idea : .note
            let outcome = router.agentOutcome(kind: routeKind, named: spoken, answer: answer, binder: binder.id,
                                              llmAgent: meantFor.flatMap { agents.contains($0) ? $0 : nil }, llmFits: fits)
            state.agent = outcome.pick?.name
            let origin: RouteOrigin = (payload.engine ?? "").lowercased() == "siri" ? .siri
                : solo != nil ? .solo : payload.fromTranscript == true ? .transcript
                : inConversation ? .conversation : asked ? .moment : inAuto ? .auto : .heard
            var decision = CardRouter.Decision(origin: origin, kind: routeKind, answer: answer, binder: pick, agent: outcome.pick,
                                               llmBinder: llmBinder?.id, moment: payload.id)
            decision.mode = payload.mode
            if outcome.pick != nil { decision.did = "suggested" } else if outcome.notTaker != nil { decision.did = "named-not-taker" }
            else if outcome.cantTakeNow != nil { decision.did = "named-not-now" }
            // Meant for an agent ("give the booth plan to Claude Code"): offered, however its kind is going, as work for an
            // agent never starts from what was heard on its own; but in Auto, added at once, which is what Auto hands over.
            let forAnAgent = meantFor != nil || !spoken.isEmpty
            let addsNow = graduated || (inAuto && !asked && MomentGraduation.kinds.contains(kind))
            if asked || (addsNow && (inAuto || !forAnAgent)) {
                state.acts = true
                state.graduated = asked ? nil : true
                if inAuto { state.late = AutoRules.isLate(Date().timeIntervalSince(payload.heard)) }
                // The start rule's verdict for a to-do, before anything is made. In Auto a "Binders, …" to-do is asked it
                // first, as in every mode, so an agent switched on before Auto still starts at its start level.
                var startWhy: RouterRules.NotStarted?
                var startAsked = false
                if kind == .todo, let chosen = outcome.pick {
                    startAsked = true
                    startWhy = router.whyNotStart(chosen, answer: answer, binder: binder.id, origin: origin, kind: .todo, payload: payload, named: spoken)
                }
                var startsByRule = inAuto && asked && startAsked && startWhy == nil
                // Auto's verdict, the model's confirm included, before anything is made, so an idea's card says what's asked
                // of the agent only when it's handed over.
                var auto: (pick: AgentPick, why: RouterRules.NotStarted?, heard: String?, heardTaker: String?, minutesAgo: Int?)?
                // In Auto the start rule's start is a hand-over without a tap too: not the same thing to the same agent twice
                // within half an hour (3.10), whichever of the two came first. Its place is taken before anything is awaited.
                if startsByRule, let chosen = outcome.pick {
                    let recent = recentAuto(since: Date().addingTimeInterval(-AutoRules.repeatWithin))
                    if let ago = handedAlready(task: reading.text, agent: chosen.name, binder: binder.id, heard: payload.heard, recent: recent) {
                        startsByRule = false
                        auto = (chosen, .alreadyHanded, nil, nil, ago)
                    } else {
                        take(payload.id, task: reading.text, agent: chosen.name, binder: binder.id, heard: payload.heard, late: false)
                    }
                }
                if inAuto, !startsByRule, auto == nil, kind == .todo || kind == .idea, let chosen = outcome.pick {
                    let levelNow = await router.models.autoLevel()
                    // From here to `take`, nothing is awaited: the places counted are taken before another moment can count them.
                    let filled = autoCheck(payload, pick: chosen, texts: solo != nil ? [said] : [said, reading.text], task: reading.text, named: autoNamed,
                                           writtenIn: writtenIn, meantFor: meantFor, meantForWritten: meantForWritten, binder: binder.id, agents: agents,
                                           takers: takers, levelNow: levelNow, phone: phone, solo: solo != nil, thinkingAloud: thinkingAloud)
                    var why = router.whyNotHandOver(chosen, answer: answer, binder: binder.id, origin: origin, kind: routeKind, payload: payload,
                                                    named: autoNamed, auto: filled.check, soloAuto: phoneSolo || solo != nil)
                    // Every hand-over from a capture takes a place among the five in ten minutes, late or not.
                    if why == nil {
                        take(payload.id, task: reading.text, agent: chosen.name, binder: binder.id, heard: payload.heard, late: state.late == true || solo != nil)
                    }
                    // Right before the hand-over: still the model that decided.
                    if why == nil, let answer { why = await router.models.confirm(answer, by: .now + .seconds(2)) }
                    // And, from a capture, still in Auto: Turn Off Auto may have landed while it was deciding.
                    if why == nil, let solo, solo.modeNow() != .auto { why = .notAuto }
                    if why != nil { giveBack(payload.id) }
                    auto = (chosen, why, filled.heardFirst, filled.heardTaker, filled.minutesAgo)
                }
                let handing = auto != nil && auto?.why == nil
                act(&state, id: payload.id, heard: payload.heard, device: payload.device, tapped: false, picked: pick.how == .model,
                    asksForAPlan: handing && kind == .idea, solo: solo != nil)
                // What was added, before any line about the hand-over: a moment that waits for its capture keeps it.
                let addedLine = state.outcome.line
                if let notTaker = outcome.notTaker, state.outcome.state == "acted" {
                    state.outcome.line += ". \(notTaker) doesn't take \(binder.name)'s cards: change that in Settings → Agents."
                } else if let waiting = outcome.cantTakeNow, state.outcome.state == "acted" {
                    state.outcome.line += ". " + CardRouter.cantTakeNow(waiting)
                }
                if let auto, state.outcome.state == "acted" {
                    // handOver sets the outcome and the decision's `did` when it hands the card over.
                    let handed = handing && handOver(&state, decision: &decision, agent: auto.pick.name, binder: binder, kind: kind,
                                                     heard: payload.heard, origin: origin, named: !autoNamed.isEmpty, picked: pick.how == .model,
                                                     solo: solo != nil)
                    if !handed, waitsForCapture, let capture = payload.conversation, auto.why == .origin {
                        // Said in a capture in Auto: it goes with its capture, if only you spoke in it (lane Y2).
                        giveBack(payload.id)
                        state.outcome.line = AutoText.joined(addedLine, AutoText.joinsCapture)
                        state.joins = capture
                        decision.whyNotStarted = RouterRules.NotStarted.origin.rawValue
                    } else if !handed {
                        giveBack(payload.id)
                        let reason = auto.why ?? .changedSince
                        // A reason about the model is asked for now, for this moment, never a kept one.
                        let modelWhy = reason == .noAutoLevel ? await router.models.whyNoAuto() : nil
                        let line = AutoText.notHandedOver(reason, agent: auto.pick.name, binder: binder.name, hold: payload.autoHold, why: modelWhy,
                                                          model: DecisionModels.name(router.models.choice), heardAgent: auto.heard,
                                                          clockAhead: payload.heard > Date(), minutesAgo: auto.minutesAgo, fromCapture: solo != nil)
                        state.outcome.line = AutoText.joined(state.outcome.line, line)
                        // "You said Codex": Give to names the agent heard, when it takes the binder's cards.
                        if reason == .heardAnother, let other = auto.heardTaker {
                            state.agent = other
                            state.outcome.agent = other
                        }
                        if reason == .tooManyAtOnce { state.outcome.waiting = CaptureOutcome.Waiting.give }
                        decision.whyNotStarted = reason.rawValue
                    }
                } else if waitsForCapture, kind == .todo || kind == .idea, let capture = payload.conversation, state.outcome.state == "acted" {
                    // No agent picked now: it still waits for its capture, which asks again then.
                    state.outcome.line = AutoText.joined(addedLine, AutoText.joinsCapture)
                    state.joins = capture
                } else if inAuto, kind == .todo || kind == .idea, registry.paused, outcome.cantTakeNow == nil, state.outcome.state == "acted" {
                    state.outcome.line = AutoText.joined(state.outcome.line, AutoText.pausedLine)
                } else if inAuto, kind == .todo || kind == .idea, outcome.pick == nil, outcome.notTaker == nil, outcome.cantTakeNow == nil,
                          let top = answer?.agentTop, top.key != RouterQuestions.nobody, state.outcome.state == "acted" {
                    // The model's top pick is an agent, under the suggest band: say so, where Suggest says nothing.
                    state.outcome.line = AutoText.joined(state.outcome.line, AutoText.notSureWhose)
                }
                // A to-do you said to Binders on your own, in your voice, for an agent you let start on its own: handed
                // over at once, when every condition holds, as before Auto (in Auto, when the start rule takes it).
                if !inAuto || startsByRule, kind == .todo, let chosen = outcome.pick, state.outcome.state == "acted" {
                    var why = startWhy
                    // Right before the start: still the model that decided. Otherwise the to-do keeps its Give to.
                    if why == nil, let answer { why = await router.models.confirm(answer, by: .now + .seconds(2)) }
                    if why == nil { startTodo(&state, decision: &decision, agent: chosen.name, binder: binder, mode: payload.mode) }
                    else if let why, router.keepsWhy(chosen, answer: answer) { decision.whyNotStarted = why.rawValue }
                }
            } else {
                state.outcome = offer(state, id: payload.id, binder: binder.name)
            }
            decision.todo = state.todo
            decision.card = state.card
            state.route = decision.id
            if answer != nil || pick.how == .model || outcome.pick != nil || outcome.notTaker != nil { router.record(decision) }
        case .question:
            if Date().timeIntervalSince(payload.heard) > Self.freshFor {
                state.outcome = nothing(payload.id, asked ? "Heard too long ago to answer now." : "")
                break
            }
            let began = Date()
            let answer = await controller.knowledge.ask(reading.text, searchQuery: reading.searchQuery, binder: named?.id, brief: true)
            // Something was found, so the model was asked to answer from it (the search before it counts in too).
            if !answer.sources.isEmpty, let client = AppSettings.shared.makeLLMClient() {
                modelMillis += Self.millis(since: began)
                usedModel = usedModel ?? client.model
            }
            if !answer.text.isEmpty {
                let sources = Array(NSOrderedSet(array: answer.sources.map(\.title))).compactMap { $0 as? String }.prefix(3)
                // The titles go on a line of their own after the answer, as a phone before `sources` shows them, and apart
                // in `sources`, so Siri says the answer alone.
                state.outcome = CaptureOutcome(id: payload.id, state: "answered", line: answer.text + (sources.isEmpty ? "" : "\n\(sources.joined(separator: " · "))"),
                                               title: "From your binders", settled: true, sources: Array(sources))
            } else if let todo = reading.orTodo {
                // Nothing answers it, but it's something to find out: a to-do, offered, in the binder you named, else
                // Tev1's at its General threshold, else General. No agent, as before.
                state.kind = MomentKind.todo.rawValue
                state.task = todo
                let general = Store.shared.defaultBinder()
                var binder = named ?? general
                if named == nil, let answer = await router.ask(todo, binder: true, agent: false, library: router.gather()) {
                    let pick = RouterRules.binder(named: nil, model: answer.binderAnswer, form: answer.binders?.form ?? .both, bands: answer.bands,
                                                  llm: nil, fallback: general.id)
                    binder = binders.first { $0.id == pick.id } ?? general
                    var decision = CardRouter.Decision(origin: inConversation ? .conversation : asked ? .moment : .heard, kind: .todo,
                                                       answer: answer, binder: pick, moment: payload.id)
                    decision.mode = payload.mode
                    state.route = decision.id
                    router.record(decision)
                }
                state.binderID = binder.id
                state.outcome = offer(state, id: payload.id, binder: binder.name)
            } else if asked {
                let subject = reading.searchQuery ?? reading.text
                state.outcome = CaptureOutcome(id: payload.id, state: "nothing", line: "Nothing in your binders about \(subject).",
                                               title: "Nothing in your binders", settled: true)
            }
        case .status:
            // The headline only: what runs are doing isn't read for it.
            var cards = WorkStreams.cards(in: named?.id, doing: false)
            if let agent = reading.agent { cards = WorkStreams.involving(agent, in: cards) }
            let digest = WorkStreams.digest(cards)
            state.outcome = CaptureOutcome(id: payload.id, state: "answered", line: digest.headline, title: "Your work streams", settled: true, sources: [])
        case .none:
            break
        }
        state.timings = MomentTimings(heard: payload.heard, seconds: payload.seconds, sent: reached, decided: Date(), asrMillis: payload.asrMillis,
                                      llmMillis: modelMillis)
        keep(state, payload: payload, model: usedModel, llmMillis: modelMillis)
        // A hand-over is counted from its record from here on.
        giveBack(payload.id)
        // Its capture read already (the outbox's order, or decided later): it goes the capture's way now (lane Y2).
        if let capture = state.joins, let vouch = controller.conversations.readVouch(capture) {
            await rejoin(payload.id, vouch: vouch)
            return self.state(payload.id)?.told ?? state.told
        }
        return state.told
    }

    /// Whole milliseconds since then.
    private static func millis(since start: Date) -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }

    /// Each binder with the titles of a few things in it, for the model to file by.
    private func hints(_ binders: [BinderRecord]) -> [ConversationPrompts.BinderHint] {
        guard let controller else { return binders.map { ConversationPrompts.BinderHint(name: $0.name, titles: [], about: Self.about($0)) } }
        return binders.map {
            ConversationPrompts.BinderHint(name: $0.name, titles: controller.conversations.recentTitles(in: $0.id, excluding: UUID()), about: Self.about($0))
        }
    }

    /// What goes in a binder, when you've said: the model sees it after the binder's name.
    static func about(_ binder: BinderRecord) -> String? {
        let about = binder.whatGoesHere.trimmingCharacters(in: .whitespacesAndNewlines)
        return about.isEmpty ? nil : about
    }

    /// Each agent with what it's for and, when it takes only some binders' cards, which, for the model to say which one a
    /// moment fits. One changed outside Binders (agents.json edited since you last saved it, maybe by an agent) goes by its
    /// name alone until you save it: what it says it's for, or which boards it takes, may be its own words, and agent text
    /// never steers how what you said is sorted or filed.
    private func hints(_ agents: [AgentProfile]) -> [MomentPrompts.AgentHint] {
        let changedOutside = AgentRegistry.shared.changedOutside
        return agents.map { agent in
            guard !changedOutside.contains(agent.id) else { return MomentPrompts.AgentHint(name: agent.name) }
            return MomentPrompts.AgentHint(name: agent.name, purpose: agent.modelDescription,
                                           binders: agent.binders.map { ids in ids.compactMap { Store.shared.binder($0)?.name } })
        }
    }

    /// Asked for ("Binders, …"), tapped Add, or of a kind added at once (`State.graduated`): the to-do, idea card or note is
    /// made, with the moment's id. The to-do automation is asked only for the first two, so nothing heard on its own, and
    /// not tapped, starts anything; and a rule runs for one said to yourself only with its "Also for…" option on (origin).
    /// False when nothing could be made: a note, with every binder shared with your team.
    /// `picked`: Tev1 picked its binder, which the line says ("Added to Website, Binders' pick: …"); the title stays.
    /// `asksForAPlan`: an idea Auto is about to hand over, whose card says what's asked of the agent.
    @discardableResult
    /// `solo` (lane Y2): read from a capture, so an idea's card handed over quotes your sentences "while you thought out loud".
    private func act(_ state: inout State, id: UUID, heard: Date, device: String?, tapped: Bool, picked: Bool = false, asksForAPlan: Bool = false,
                     solo: Bool = false) -> Bool {
        guard let controller else { return false }
        let binderName = Store.shared.binder(state.binderID)?.name ?? "General"
        let pick = picked ? ", Binders' pick" : ""
        switch MomentKind(rawValue: state.kind) {
        case .todo:
            let todo = controller.commitments.addMoment(state.task, due: state.due, dueText: state.dueText, binderID: state.binderID, id: id, heard: heard,
                                                        said: state.said, app: device ?? "iPhone", fireAutomation: tapped || state.graduated != true,
                                                        origin: tapped ? .suggestion : .moment)
            state.todo = todo.id.uuidString
            let due = state.due.map { " · \(CommitmentService.dueLabel($0))" } ?? ""
            state.outcome = CaptureOutcome(id: id, state: "acted", line: "Added to \(binderName)\(pick): \(state.task)\(due)", title: "Added to \(binderName)",
                                           settled: false, binder: binderName, actions: state.agent == nil ? ["undo"] : ["undo", "assign"], agent: state.agent,
                                           todo: state.todo)
        case .idea:
            let title = state.task
            let details = asksForAPlan && solo ? AutoText.soloDetails(said: state.said, heard: heard, now: Date(), idea: true)
                : asksForAPlan ? AutoText.ideaDetails(said: state.said, heard: heard, now: Date())
                : "\(state.said)\n\nSaid to your iPhone at \(heard.formatted(date: .omitted, time: .shortened))."
            let card = controller.board.create(title: title, details: details, binderID: state.binderID, column: .backlog,
                                               source: ("moment", id.uuidString, "what you said to your iPhone"), id: id, by: .you)
            state.card = card.id
            // Give to as for a to-do, when an agent fits: the idea's card goes to Ready, meant for it.
            state.outcome = CaptureOutcome(id: id, state: "acted", line: "Put on the \(binderName) board\(pick): \(title)", title: "An idea for \(binderName)",
                                           settled: false, binder: binderName, actions: state.agent == nil ? ["undo"] : ["undo", "assign"], agent: state.agent,
                                           card: card.id.uuidString)
        case .note:
            // Never into a binder shared with your team, though you shared it after the note was offered: into one of yours
            // that isn't, as when it was heard, or nowhere.
            let ours = { (binder: BinderRecord) in !binder.sharedWithTeam && !binder.isTeamCopy }
            guard let into = Store.shared.binder(state.binderID).flatMap({ ours($0) ? $0 : nil }) ?? Store.shared.binders().first(where: ours) else {
                state.outcome = CaptureOutcome(id: id, state: "answered", line: Self.everyBinderShared, title: "Not kept", settled: true)
                return false
            }
            state.binderID = into.id
            let note = NoteItem(text: "# \(state.task.prefix(60))\n\n\(state.said)")
            note.id = id
            note.binderID = into.id
            note.sharedWithTeam = false
            // Marked on the note, so it stays unshared wherever it goes, History deleted or not.
            note.staysUnshared = true
            Store.shared.insert(note)
            state.note = note.id
            state.outcome = CaptureOutcome(id: id, state: "acted", line: "Kept in \(into.name)\(pick): \(state.task)", title: "Kept in \(into.name)",
                                           settled: false, binder: into.name, actions: ["undo"])
        default:
            break
        }
        return true
    }

    private func offer(_ state: State, id: UUID, binder: String) -> CaptureOutcome {
        let due = state.due.map { " · \(CommitmentService.dueLabel($0))" } ?? ""
        let title = switch MomentKind(rawValue: state.kind) {
        case .idea: "Put this on the \(binder) board?"
        case .note: "Keep in \(binder)?"
        default: "Add to \(binder)?"
        }
        return CaptureOutcome(id: id, state: "offered", line: state.task + due, title: title, settled: false, binder: binder, actions: ["add", "not-now"])
    }

    private func nothing(_ id: UUID, _ line: String) -> CaptureOutcome {
        CaptureOutcome(id: id, state: "nothing", line: line, title: line.isEmpty ? nil : line, settled: true)
    }

    /// Where a to-do, idea or note goes when you didn't say: the model picks among your binders (fast lane, a few
    /// seconds), else where new things go; and, seeing your agents with what each is for, the one you said to give it to
    /// and the one it fits. Given the one binder it's going in, only the agent is in question. Nil when there was nothing
    /// to ask (no binder, no model) or no reply; the binder is nil for none.
    /// `written` is what its AGENT line wrote, as written, beside the agent it matched.
    private func route(_ text: String, kind: MomentKind, among binders: [BinderRecord], agents: [MomentPrompts.AgentHint]) async
        -> (binder: BinderRecord?, agent: String?, written: String?, fits: String?, model: String, millis: Int)? {
        guard !binders.isEmpty, let client = model() else { return nil }
        let hints = hints(binders)
        let prompt = ConversationPrompts.routingUserPrompt(binders: hints, title: text, summary: text)
        let began = Date()
        let output = try? await client.complete(system: MomentPrompts.routingSystemPrompt(item: kind, agents: agents), user: prompt,
                                                maxTokens: 100, temperature: 0.1, timeout: 8)
        let millis = Self.millis(since: began)
        guard let output else { return (nil, nil, nil, nil, client.model, millis) }
        let name = ConversationPrompts.parseRouting(output, names: hints.map(\.name)).binder
        let names = agents.map(\.name)
        return (binders.first { $0.name == name }, MomentPrompts.parseAgent(output, among: names), MomentPrompts.parseClassification(output).agent,
                MomentPrompts.parseFit(output, among: names), client.model, millis)
    }

    /// A "Binders, …" to-do Binders hands to the agent without a tap: its card in Ready, then Give to's own path, by
    /// Binders. The outcome says so, with Undo, which stops it. From an iPhone that sends a mode (`mode`), with Stop and Not
    /// Me beside it, and an Undo that takes the to-do back too.
    private func startTodo(_ state: inout State, decision: inout CardRouter.Decision, agent name: String, binder: BinderRecord, mode: String?) {
        guard let controller, let agent = AgentRegistry.shared.agent(named: name), let todoID = state.todo, let todo = Todos.find(todoID) else { return }
        let card = controller.board.create(from: todo, column: .ready, binderID: state.binderID, by: .you).card
        state.card = card.id
        let actions = mode == nil ? ["undo"] : ["stop", "undo", "not-me"]
        let handed = mode == nil ? nil : CaptureOutcome.Handed.start
        switch controller.router.start(card, agent: agent, origin: .moment, title: card.title) {
        case .woke:
            state.started = true
            decision.did = "started"
            state.outcome = CaptureOutcome(id: state.outcome.id, state: "acted", line: "Added to \(binder.name): \(state.task). Binders handed it to \(agent.name).",
                                           title: "Handed to \(agent.name)", settled: false, binder: binder.name, actions: actions,
                                           card: card.id.uuidString, handedOver: handed)
            state.outcome.todo = state.todo
        case .notWoken(let why):
            // Its card is meant for the agent, in Ready, but nothing woke it: Undo still moves it back, and says it wasn't
            // woken rather than that it was stopped (stopStarted). The log keeps no words: the reason may name the agent.
            state.started = true
            decision.did = "suggested"
            decision.whyNotStarted = "not woken"
            state.outcome = CaptureOutcome(id: state.outcome.id, state: "acted",
                                           line: "Added to \(binder.name): \(state.task). \(agent.name) wasn't woken: \(CardRouter.clause(why)). Wake Now on the card on your Mac does it.",
                                           title: "Added to \(binder.name)", settled: false, binder: binder.name, actions: actions,
                                           card: card.id.uuidString, handedOver: handed, waiting: mode == nil ? nil : CaptureOutcome.Waiting.wake)
            state.outcome.todo = state.todo
        case .changed:
            decision.did = "suggested"
            decision.whyNotStarted = RouterRules.NotStarted.changedSince.rawValue
        }
    }

    // MARK: Auto

    /// Auto's hand-over, through Give to's own path, by Binders, with Auto's note on the card: a to-do's card made in Ready
    /// from it, with what you said and when (AutoText.todoDetails); an idea's own card, from Backlog, which asks for a
    /// plan. The outcome says so, with Stop, Undo and Not Me; past the agent's hourly cap the card waits in Ready, meant for
    /// it and not woken, which waits on you. False when the card changed before it could go.
    /// `solo`, `joined` (lane Y2): from a capture in which your iPhone heard only you; a moment said in it that went with it.
    private func handOver(_ state: inout State, decision: inout CardRouter.Decision, agent name: String, binder: BinderRecord, kind: MomentKind,
                          heard: Date, origin: RouteOrigin, named: Bool, picked: Bool, solo: Bool = false, joined: Bool = false) -> Bool {
        guard let controller, let agent = AgentRegistry.shared.agent(named: name) else { return false }
        let idea = kind == .idea
        let card: TaskCard
        if idea {
            guard let made = state.card.flatMap(controller.board.card) else { return false }
            card = made
        } else {
            guard kind == .todo, let todoID = state.todo, let todo = Todos.find(todoID) else { return false }
            let details = solo && !joined ? AutoText.soloDetails(said: state.said, heard: heard, now: Date(), idea: false)
                : AutoText.todoDetails(said: state.said, heard: heard, now: Date())
            card = controller.board.create(from: todo, column: .ready, binderID: state.binderID, details: details, by: .you).card
        }
        state.card = card.id
        let started = controller.router.start(card, agent: agent, origin: origin, title: card.title, fromBacklog: idea,
                                              auto: CardRouter.AutoModeStart(heard: heard, idea: idea, named: named, solo: solo, joined: joined,
                                                                         asked: state.wake == true))
        let line: String, title: String
        var waiting: String?
        switch started {
        case .woke:
            decision.did = "started"
            line = AutoText.handedLine(idea: idea, binder: binder.name, agent: agent.name, task: state.task, picked: picked)
            title = AutoText.handedTitle(agent.name)
        case .notWoken(let why):
            // Meant for the agent, in Ready, but not woken (its hourly cap, say): Wake Now on the card on your Mac does it,
            // so it waits on you. The log keeps no words: the reason may name the agent.
            decision.did = "suggested"
            decision.whyNotStarted = "not woken"
            line = AutoText.notWokenLine(idea: idea, binder: binder.name, agent: agent.name, task: state.task, why: CardRouter.clause(why), picked: picked)
            title = AutoText.notWokenTitle(agent.name)
            waiting = CaptureOutcome.Waiting.wake
        case .changed:
            return false
        }
        state.started = true
        state.auto = true
        state.outcome = CaptureOutcome(id: state.outcome.id, state: "acted", line: line, title: title, settled: false, binder: binder.name,
                                       actions: ["stop", "undo", "not-me"], agent: agent.name, card: card.id.uuidString, todo: state.todo,
                                       handedOver: CaptureOutcome.Handed.auto, waiting: waiting)
        return true
    }

    /// What only a hand-over in Auto depends on, for this moment (RouterRules.AutoCheck): the iPhone it came from, its hold,
    /// the model's Auto level now, the Mac's own yes for Auto, the names heard in it (`writtenIn`: named only in the classify
    /// call's rewording, which counts as heard, never as named), the same thing handed over already, and the late ones
    /// handed over lately. With the first other agent heard in it, for the line, and the one Give to then
    /// names when that one takes the binder's cards; and, for a repeat, how many minutes before this one it was said.
    /// Nothing is awaited here, so the places it counts are taken (`take`) before another moment can count them.
    /// Lane Y2: `solo`, from a capture vouched for as only you (an item, or a moment that went with it): every agent
    /// mentioned in its sentences keeps it from every other, and the reading's own field never lifts "only mentioned";
    /// `thinkingAloud`, names read only when said as meant.
    private func autoCheck(_ payload: MomentPayload, pick: AgentPick, texts: [String], task: String, named: [String], writtenIn: [String] = [],
                           meantFor: String?, meantForWritten: String?, binder: UUID, agents: [String], takers: [String], levelNow: Double?,
                           phone: UUID?, solo: Bool = false, thinkingAloud: Bool = false) -> (check: RouterRules.AutoCheck, heardFirst: String?, heardTaker: String?, minutesAgo: Int?) {
        let registry = AgentRegistry.shared
        // With no agent named exactly: the names heard loosely ("cloud code"), the AGENT line's, and those only the classify
        // call's rewording named, any of which keeps the card from every other agent; and whether the pick is only
        // mentioned, in the words as heard.
        var heard: [String] = []
        var onlyMentioned = false
        if named.isEmpty {
            let mentionedToo = thinkingAloud ? NamedAgents.mentioned(in: texts, agents: agents) : []
            for agent in NamedAgents.heard(in: texts, agents: agents).map(\.agent) + [meantFor].compactMap({ $0 }) + writtenIn + mentionedToo
                where !heard.contains(agent) {
                heard.append(agent)
            }
            let asHeard = texts.map { NamedAgents.asHeard($0, agents: agents) }
            onlyMentioned = (solo || meantFor != pick.name) && NamedAgents.mentioned(in: asHeard, agents: agents).contains(pick.name)
                && !NamedAgents.find(in: asHeard, agents: agents, thinkingAloud: thinkingAloud).contains(pick.name)
        }
        let heardFirst = heard.first { $0 != pick.name }
        // Wide enough for the same thing heard within 30 minutes of this, however long ago it was decided (lane Y2).
        let recent = recentAuto(since: Date().addingTimeInterval(-AutoRules.horizon))
        let repeated = handedAlready(task: task, agent: pick.name, binder: binder, heard: payload.heard, recent: recent)
        let check = RouterRules.AutoCheck(
            mode: payload.mode.flatMap(MomentMode.init(rawValue:)), phoneAllowed: AutoPhones.allows(phone, paired: pairedDevices()),
            hold: payload.autoHold, levelNow: levelNow, startsInAuto: registry.agent(named: pick.name).map(registry.startsInAuto) ?? false,
            heard: heard, namedSomeoneElse: named.isEmpty && meantForWritten != nil && meantFor == nil, onlyMentioned: onlyMentioned,
            handedAlready: repeated != nil, lateRecently: lateRecently(besides: payload.id, recent: recent), vouched: solo,
            startsInSolo: registry.agent(named: pick.name).map(registry.startsInSolo) ?? false)
        return (check, heardFirst, heardFirst.flatMap { takers.contains($0) ? $0 : nil }, repeated)
    }

    /// The moments handed over without a tap from an iPhone that sends a mode (Auto's, and the start rule's from such an
    /// iPhone) that were decided since `since`, with when each was heard. Found by when they were heard, which is at most
    /// `AutoRules.horizon` either side of when they were decided.
    private func recentAuto(since: Date) -> [(state: State, heard: Date)] {
        let mode = "moment"
        let earliest = since.addingTimeInterval(-AutoRules.horizon - AutoRules.clockSlack)
        let records = (try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate {
            $0.mode == mode && $0.createdAt >= earliest
        }))) ?? []
        return records.compactMap { record in
            guard let state = try? JSONDecoder().decode(State.self, from: EarlierSpellings.json(Data(record.outcomeJSON.utf8))), state.handedWithoutTap,
                  let decided = state.timings?.decided, decided >= since else { return nil }
            return (state, record.createdAt)
        }
    }

    /// The paired iPhones that sent a moment in Auto in the last day, each with when it was last decided, latest first: for
    /// Settings → Agents → Sorting new cards, which names them and, with two or more paired, offers Allow.
    func autoPhones(within: TimeInterval = 86_400, now: Date = Date()) -> [(device: UUID, last: Date)] {
        let mode = "moment"
        let since = now.addingTimeInterval(-within)
        let earliest = since.addingTimeInterval(-AutoRules.horizon - AutoRules.clockSlack)
        let records = (try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate {
            $0.mode == mode && $0.createdAt >= earliest
        }))) ?? []
        var last: [UUID: Date] = [:]
        for record in records {
            guard let state = try? JSONDecoder().decode(State.self, from: EarlierSpellings.json(Data(record.outcomeJSON.utf8))), state.mode == MomentMode.auto.rawValue,
                  let device = state.device else { continue }
            let decided = state.timings?.decided ?? record.createdAt
            guard decided >= since else { continue }
            last[device] = max(last[device] ?? decided, decided)
        }
        return last.map { (device: $0.key, last: $0.value) }.sorted { $0.last > $1.last }
    }

    /// The same thing handed this agent in this binder without a tap (by Auto, or by the start rule from an iPhone that
    /// sends a mode) within `AutoRules.repeatWithin`, its card still open and not stopped: how many minutes before `heard` it was said (0 for one being decided now), or nil for none.
    private func handedAlready(task: String, agent: String, binder: UUID, heard: Date, recent: [(state: State, heard: Date)]) -> Int? {
        func minutes(since earlier: Date) -> Int { max(0, Int((heard.timeIntervalSince(earlier) / 60).rounded(.down))) }
        if let now = handing.values.first(where: { $0.agent == agent && $0.binder == binder && AutoRules.sameThing($0.task, task) }) {
            return minutes(since: now.heard)
        }
        let since = Date().addingTimeInterval(-AutoRules.repeatWithin)
        for kept in recent where kept.state.agent == agent && kept.state.binderID == binder && kept.state.stopped != true
            && kept.state.outcome.state == "acted" && AutoRules.sameThing(kept.state.task, task)
            && (AutoRules.isRepeat(decided: kept.state.timings?.decided ?? .distantPast, heard: kept.heard, now: Date(), heardNow: heard)
                || (kept.state.timings?.decided ?? .distantPast) >= since) {
            guard let card = kept.state.card.flatMap({ controller?.board.card($0) }), card.column != .done else { continue }
            return minutes(since: kept.heard)
        }
        return nil
    }

    /// Late words Auto handed over in the last `AutoRules.lateWindow`, this one not counted: from the moments' records, so
    /// a relaunch doesn't reset it, and the places being decided now.
    private func lateRecently(besides id: UUID, recent: [(state: State, heard: Date)]) -> Int {
        let since = Date().addingTimeInterval(-AutoRules.lateWindow)
        // Late words, and every hand-over from a capture (lane Y2).
        let kept = recent.filter { $0.state.auto == true && ($0.state.late == true || $0.state.fromCapture)
            && ($0.state.timings?.decided ?? .distantPast) >= since }.count
        return kept + lateTaken.subtracting([id]).count
    }

    /// Takes this moment's places, before anything is awaited: among what's being handed over now, and among late ones.
    private func take(_ id: UUID, task: String, agent: String, binder: UUID, heard: Date, late: Bool) {
        handing[id] = (task, agent, binder, heard)
        if late { lateTaken.insert(id) }
    }

    /// Gives them back: it wasn't handed over, or its record keeps it now.
    private func giveBack(_ id: UUID) {
        handing[id] = nil
        lateTaken.remove(id)
    }

    // MARK: Auto for thinking out loud (lane Y2)

    /// One thing read from a capture in which your iPhone heard only you, decided as a moment of its own (origin `.solo`):
    /// added at once, and in Auto handed over by Auto's rule, every guard and limit counted from the moment records. Its
    /// id is the same on every reading (SoloReading.itemID), so a capture read again never makes it twice.
    func decideFound(_ item: SoloReading.Item, index: Int, capture: MeetingRecord, vouch: SoloVouch, device: UUID?,
                     modeNow: @escaping @MainActor () -> MomentMode) async -> CaptureOutcome {
        let id = SoloReading.itemID(capture: capture.id, index: index, title: item.title)
        let heard = capture.createdAt.addingTimeInterval(item.offset)
        let mode = modeNow()
        let payload = MomentPayload(id: id, heard: heard, text: item.said, device: capture.appName ?? "iPhone", engine: vouch.engine, wake: false,
                                    conversation: capture.id, adds: MomentModes.everyKind, agreed: mode == .auto ? vouch.agreed : nil,
                                    mode: mode.rawValue)
        return await receive(payload, from: device, soloAuto: true,
                             solo: SoloItem(capture: capture.id, item: item, binder: capture.binderID, modeNow: modeNow))
    }

    /// The moments of a capture still being decided: what its reading waits for, so none is missed.
    func waitForMoments(in capture: UUID) async {
        for running in working.values where running.payload.conversation == capture && !items.contains(running.payload.id) {
            _ = await running.task.value
        }
    }

    /// The moments said in a capture that wait for it (`joins`), in the order heard.
    func joining(_ capture: UUID) -> [(id: UUID, heard: Date)] {
        let mode = "moment"
        let records = (try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.mode == mode }))) ?? []
        return records.compactMap { record -> (id: UUID, heard: Date)? in
            guard let state = try? JSONDecoder().decode(State.self, from: EarlierSpellings.json(Data(record.outcomeJSON.utf8))), state.joins == capture else { return nil }
            return (record.id, record.createdAt)
        }.sorted { $0.heard < $1.heard }
    }

    /// What a capture's reading made, and the moments said in it that were decided at it, in the order heard: for its
    /// outcome's `found` and the Mac's capture page.
    func found(in capture: UUID) -> [(id: UUID, heard: Date, state: State)] {
        let mode = "moment"
        let records = (try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.mode == mode }))) ?? []
        return records.compactMap { record -> (id: UUID, heard: Date, state: State)? in
            guard let state = try? JSONDecoder().decode(State.self, from: EarlierSpellings.json(Data(record.outcomeJSON.utf8))),
                  state.solo == capture || (state.joined == true && state.conversation == capture) else { return nil }
            return (record.id, record.createdAt, state)
        }.sorted { $0.heard < $1.heard }
    }

    /// A moment said in a capture in Auto, decided at its capture: handed over by Auto's rule, as `.solo`, when the capture
    /// came vouched as only you, the Mac's checks held, its own span was heard in your voice (`soloMoments`), and with its
    /// own hold, so one the iPhone held back stays held back; otherwise it stays added, and its line says why. Either order
    /// of arrival comes here.
    func rejoin(_ id: UUID, vouch: SoloVouch) async {
        guard let controller, var state = state(id), let capture = state.joins, let record = record(id) else { return }
        let base = Self.withoutJoinLine(state.outcome.line)
        state.joins = nil
        state.joined = true
        guard state.outcome.state == "acted", state.started != true else {
            save(state, id: id)
            return
        }
        func settle(_ line: String) {
            state.outcome.line = AutoText.joined(base, line)
            save(state, id: id)
        }
        guard vouch.vouched, vouch.reply != SoloPrompts.State.talking.rawValue else { return settle(AutoText.joinedNot(why: vouch.why)) }
        // Not Only Me or Stop All on its capture: it stays added, and isn't handed over.
        guard vouch.notOnlyMe != true else { return settle(AutoText.joinedNot(why: "voices")) }
        guard vouch.stoppedAll != true else { return settle(AutoText.joinedStopped) }
        guard vouch.modeNow == .auto else { return settle(AutoText.joinedAutoOff) }
        guard (vouch.soloMoments ?? []).contains(id) else { return settle(AutoText.joinedNotYours) }
        guard let kind = MomentKind(rawValue: state.kind), kind == .todo || kind == .idea, let binderID = state.binderID,
              let binder = Store.shared.binder(binderID) else { return settle("") }
        let router = controller.router
        let registry = AgentRegistry.shared
        let agents = registry.agents.filter(\.isEnabled).map(\.name)
        let device = vouch.device.flatMap(UUID.init(uuidString:))
        let payload = MomentPayload(id: id, heard: record.createdAt, text: state.said, device: record.appName, engine: record.engine, wake: state.wake,
                                    conversation: capture, agreed: vouch.agreed, mode: vouch.mode, autoHold: state.hold)
        let answer = await router.ask(state.task, binder: false, agent: true, library: router.gather())
        let routeKind: RouteKind = kind == .todo ? .todo : .idea
        let spoken = NamedAgents.find(in: [state.said, state.task], agents: agents)
        let outcome = router.agentOutcome(kind: routeKind, named: spoken, answer: answer, binder: binderID)
        guard let chosen = outcome.pick else { return settle(AutoText.notSureWhose) }
        var decision = CardRouter.Decision(origin: .solo, kind: routeKind, answer: answer, binder: BinderPick(id: binderID, how: .fallback),
                                           agent: chosen, moment: id)
        decision.mode = vouch.mode
        let levelNow = await router.models.autoLevel()
        let takers = registry.takers(for: binderID).map(\.name)
        let filled = autoCheck(payload, pick: chosen, texts: [state.said, state.task], task: state.task, named: spoken, meantFor: nil, meantForWritten: nil,
                               binder: binderID, agents: agents, takers: takers, levelNow: levelNow, phone: device, solo: true)
        var why = router.whyNotHandOver(chosen, answer: answer, binder: binderID, origin: .solo, kind: routeKind, payload: payload, named: spoken,
                                        auto: filled.check, soloAuto: true)
        if why == nil { take(id, task: state.task, agent: chosen.name, binder: binderID, heard: record.createdAt, late: true) }
        if why == nil, let answer { why = await router.models.confirm(answer, by: .now + .seconds(2)) }
        if why == nil, controller.conversations.vouch(of: capture)?.modeNow != .auto { why = .notAuto }
        state.outcome.line = base
        let handed = why == nil && handOver(&state, decision: &decision, agent: chosen.name, binder: binder, kind: kind, heard: record.createdAt,
                                            origin: .solo, named: !spoken.isEmpty, picked: false, solo: true, joined: true)
        giveBack(id)
        if !handed {
            let reason = why ?? .changedSince
            if reason == .notAuto {
                state.outcome.line = AutoText.joined(base, AutoText.joinedAutoOff)
            } else {
                let modelWhy = reason == .noAutoLevel ? await router.models.whyNoAuto() : nil
                let line = AutoText.notHandedOver(reason, agent: chosen.name, binder: binder.name, hold: state.hold, why: modelWhy,
                                                  model: DecisionModels.name(router.models.choice), heardAgent: filled.heardFirst,
                                                  clockAhead: record.createdAt > Date(), minutesAgo: filled.minutesAgo, fromCapture: true)
                state.outcome.line = AutoText.joined(base, line)
            }
            if reason == .tooManyAtOnce { state.outcome.waiting = CaptureOutcome.Waiting.give }
            decision.whyNotStarted = reason.rawValue
        }
        decision.todo = state.todo
        decision.card = state.card
        router.record(decision)
        save(state, id: id)
    }

    /// The capture a moment's card came from: the one an item was read from, or the one a moment was said in. For the
    /// card's briefing, which leaves that capture out.
    static func capture(ofMoment id: String) -> UUID? {
        guard let id = UUID(uuidString: id) else { return nil }
        var descriptor = FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = (try? Store.shared.context.fetch(descriptor))?.first, record.mode == "moment",
              let state = try? JSONDecoder().decode(State.self, from: EarlierSpellings.json(Data(record.outcomeJSON.utf8))) else { return nil }
        return state.solo ?? state.conversation
    }

    /// For the self-tests, in a throwaway folder only: every moment decided so far counts as decided `seconds` earlier, so
    /// a section starts with Auto's window of five in ten minutes empty.
    func ageForSelfTest(by seconds: TimeInterval) {
        guard AppPaths.isDemo else { return }
        let mode = "moment"
        for record in (try? Store.shared.context.fetch(FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.mode == mode }))) ?? [] {
            guard var state = try? JSONDecoder().decode(State.self, from: EarlierSpellings.json(Data(record.outcomeJSON.utf8))), let decided = state.timings?.decided else { continue }
            state.timings?.decided = decided.addingTimeInterval(-seconds)
            record.outcomeJSON = (try? JSONEncoder().encode(state)).map { String(decoding: $0, as: UTF8.self) } ?? record.outcomeJSON
        }
        Store.shared.save()
    }

    /// A moment's line without "goes with its capture", for the line that replaces it.
    static func withoutJoinLine(_ line: String) -> String {
        var text = line
        for suffix in [". " + AutoText.joinsCapture, " " + AutoText.joinsCapture, AutoText.joinsCapture] where text.hasSuffix(suffix) {
            text.removeLast(suffix.count)
            break
        }
        return text
    }

    /// An open card or to-do in the binder that's the same thing as `title`: what it is, and the card's id.
    private func alreadyThere(_ title: String, binder: UUID) -> (title: String, card: String?)? {
        guard let controller else { return nil }
        if let card = controller.board.cards(in: binder).first(where: { $0.column != .done && AutoRules.sameThing($0.title, title) }) {
            return (card.title, card.id.uuidString)
        }
        if let todo = Store.shared.commitments().first(where: { $0.binderID == binder && $0.status != "done" && AutoRules.sameThing($0.task, title) }) {
            return (todo.task, nil)
        }
        return nil
    }

    // MARK: Your taps

    /// Add, Not Now, Undo or Assign, from the phone; and, from an iPhone that sends a mode, Stop and Not Me on one whose
    /// card Binders handed over without a tap. Nil when the id isn't a moment here (the conversation path may know it).
    func act(on id: UUID, action: String, agent: String? = nil) -> (ok: Bool, message: String)? {
        guard var state = state(id), let controller else { return nil }
        let binderName = Store.shared.binder(state.binderID)?.name ?? "General"
        let result: (ok: Bool, message: String)
        switch (action, state.outcome.state) {
        case ("stop", "acted") where state.started == true && state.stopped != true:
            result = stop(&state, id: id)
        case ("undo", "acted") where state.started == true && state.mode != nil:
            // From an iPhone that shows Stop beside it: Undo takes back what you said too.
            result = takeBack(&state, id: id, binder: binderName)
        case ("not-me", "acted"):
            // Not you, or not for Binders: taken back, whatever it was, and the router's record says why.
            result = state.started == true ? takeBack(&state, id: id, binder: binderName) : undo(&state, id: id, binder: binderName)
            if result.ok { controller.router.log.outcome("not-me", card: state.card, todo: state.todo, moment: id) }
        case ("not-me", "offered"):
            state.outcome = CaptureOutcome(id: id, state: "dismissed", line: "Not added", title: "Not added", settled: true)
            controller.router.log.outcome("not-me", moment: id)
            result = (true, "")
        case ("add", "offered"):
            // Nothing made (a note, with every binder shared with your team since it was offered): not done, still offered.
            guard act(&state, id: id, heard: record(id)?.createdAt ?? Date(), device: record(id)?.appName, tapped: true) else {
                return (false, state.outcome.line)
            }
            result = (true, state.outcome.line)
        case ("add", "acted"):
            result = (true, "Already in \(binderName).")
        case ("not-now", "offered"):
            state.outcome = CaptureOutcome(id: id, state: "dismissed", line: "Not added", title: "Not added", settled: true)
            result = (true, "")
        case ("undo", "acted"):
            let started = state.started == true
            result = undo(&state, id: id, binder: binderName)
            // Taken back, for the router's record (a start's Undo is a stop, which stopStarted records).
            if result.ok, !started { controller.router.log.outcome("undone", todo: state.todo, moment: id) }
        case ("undo", "offered"):
            state.outcome = CaptureOutcome(id: id, state: "dismissed", line: "Nothing was added", title: "Nothing was added", settled: true)
            result = (true, "Nothing was added.")
        case ("assign", "acted"):
            result = assign(&state, to: agent ?? state.agent, binder: binderName, controller: controller)
        default:
            return (false, state.outcome.state == "undone" ? "It was taken back already." : "That isn't something you can do with it now.")
        }
        guard result.ok else { return result }
        save(state, id: id)
        return result
    }

    /// Stop, from the iPhone, on one whose card Binders handed over without a tap: the run Binders started stops and the
    /// card goes back to Backlog, meant for no one (CardRouter.stopStarted); what you said stays. Undo then takes it back,
    /// and Give to hands it over again.
    private func stop(_ state: inout State, id: UUID) -> (ok: Bool, message: String) {
        guard let controller else { return (false, "Binders is shutting down") }
        guard let card = state.card.flatMap(controller.board.card) else { return (false, "Its card isn't on the board any more.") }
        let name = state.agent ?? card.meantFor ?? card.assignee ?? "The agent"
        let result = controller.router.stopStarted(card, agent: name)
        guard result.changed else { return (false, result.line) }
        state.stopped = true
        state.outcome.line = result.line
        state.outcome.title = result.title
        state.outcome.actions = ["undo", "assign"]
        state.outcome.agent = name
        state.outcome.waiting = nil
        return (true, result.line)
    }

    /// Timeline events by which an agent has reported on a card or asked on it. A claim isn't one: a run Binders starts
    /// claims its card at once.
    private static let reports: Set<TaskEvent.Kind> = [.progress, .question, .comment, .completed, .approval]

    /// Undo, or Not Me, of one whose card Binders handed over without a tap, from an iPhone that sends a mode: Stop, unless
    /// it was stopped, then the card and what you said are taken back, unless the agent has reported on the card or asked
    /// on it (then they stay, and the line says so). Once the agent has finished it, nothing changes.
    private func takeBack(_ state: inout State, id: UUID, binder: String) -> (ok: Bool, message: String) {
        guard let controller else { return (false, "Binders is shutting down") }
        // Its card deleted on the Mac: what you said is taken back as anything added at once is.
        guard let cardID = state.card, let card = controller.board.card(cardID) else { return undo(&state, id: id, binder: binder) }
        let name = state.agent ?? card.meantFor ?? card.assignee ?? "The agent"
        if card.column == .review || card.column == .done {
            return (false, "\(name) has finished it: it's in \(card.column.title) on the \(binder) board.")
        }
        let idea = MomentKind(rawValue: state.kind) == .idea
        let reported = controller.board.timeline(card.id).contains { $0.authorIsAgent && Self.reports.contains($0.kind) }
        // What Stop found, before it changes that: a run going, or an agent that already has the card.
        let stoppedBefore = state.stopped == true
        let running = stoppedBefore ? state.outcome.title == "Stopped \(name)" : controller.agents.isBusy(on: card.id)
        let hadIt = !stoppedBefore && !running && controller.router.startedBy(card) != nil
        if !stoppedBefore {
            let stopped = controller.router.stopStarted(card, agent: name)
            guard stopped.changed else { return (false, stopped.line) }
            state.stopped = true
        }
        if reported {
            let line = AutoText.undoneKeptLine(binder: binder, agent: name, idea: idea)
            state.outcome = CaptureOutcome(id: id, state: "undone", line: line, title: "Stopped \(name)", settled: true)
            return (true, line)
        }
        // The card first: a to-do with a card is never taken off on its own.
        controller.board.delete(card)
        if !idea, let todo = Store.shared.commitments().first(where: { $0.id.uuidString == state.todo }), todo.status != "done" {
            controller.commitments.remove(todo)
        }
        controller.router.log.outcome("undone", card: cardID, todo: state.todo, moment: id)
        let line = hadIt ? AutoText.undoneHadItLine(task: state.task, binder: binder, agent: name)
            : running || stoppedBefore ? AutoText.undoneLine(task: state.task, binder: binder, agent: name)
            : "Took “\(state.task)” off the \(binder) board before \(name) was woken."
        state.outcome = CaptureOutcome(id: id, state: "undone", line: line, title: "Taken back", settled: true)
        return (true, line)
    }

    private func undo(_ state: inout State, id: UUID, binder: String) -> (ok: Bool, message: String) {
        guard let controller else { return (false, "Binders is shutting down") }
        // Handed to an agent without a tap: Undo stops it and puts the card back in Backlog, meant for no one, and the
        // to-do stays.
        if state.started == true, let cardID = state.card, let card = controller.board.card(cardID) {
            let name = state.agent ?? card.meantFor ?? card.assignee ?? "The agent"
            let result = controller.router.stopStarted(card, agent: name)
            guard result.changed else { return (false, result.line) }
            state.outcome = CaptureOutcome(id: id, state: "undone", line: result.line, title: result.title, settled: true)
            return (true, result.line)
        }
        switch MomentKind(rawValue: state.kind) {
        case .todo:
            if let todo = Store.shared.commitments().first(where: { $0.id.uuidString == state.todo }) {
                if todo.status == "done" { return (false, "It's done already, so it stays.") }
                // Its own card, made for it and not touched since, goes with it; one that has moved on stays, for the board.
                if let card = controller.board.card(forTodo: todo.id.uuidString) {
                    guard controller.board.isOwnUntouched(card) else { return (false, "It's on a board now: take it off there.") }
                    controller.board.delete(card)
                }
                controller.commitments.remove(todo)
            }
            state.outcome = CaptureOutcome(id: id, state: "undone", line: "Took “\(state.task)” off \(binder)", title: "Taken back", settled: true)
        case .idea:
            if let cardID = state.card, let card = controller.board.card(cardID) {
                let untouched = card.column == .backlog && card.assignee == nil && card.meantFor == nil
                    && controller.board.timeline(card.id).allSatisfy { $0.kind == .created }
                guard untouched else { return (false, "It has moved on the board since: change it there.") }
                controller.board.delete(card)
            }
            state.outcome = CaptureOutcome(id: id, state: "undone", line: "Took “\(state.task)” off the \(binder) board", title: "Taken back", settled: true)
        case .note:
            if let noteID = state.note, let note = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == noteID })))?.first {
                guard note.updatedAt.timeIntervalSince(note.createdAt) < 2 else { return (false, "You've written in it since: delete it there.") }
                NoteTrash.shared.delete(note, undoManager: nil)
            }
            state.outcome = CaptureOutcome(id: id, state: "undone", line: "Took the note back", title: "Taken back", settled: true)
        default:
            return (false, "Nothing to undo.")
        }
        return (true, state.outcome.line)
    }

    /// Assign, your tap: the to-do becomes a card in Ready, meant for the agent, which Binders then wakes. Only to an agent
    /// that takes cards from its binder, as Give to on a capture's card.
    private func assign(_ state: inout State, to agent: String?, binder: String, controller: DictationController) -> (ok: Bool, message: String) {
        guard let agent, let profile = AgentRegistry.shared.agent(named: agent) else { return (false, "No agent to give it to. Set one up in Settings → Agents.") }
        guard profile.takesCards(from: state.binderID) else {
            return (false, "\(profile.name) doesn't take cards from the \(binder) board. Change that in Settings → Agents.")
        }
        let card: TaskCard
        if let todoID = state.todo, let todo = Todos.find(todoID) {
            card = controller.board.create(from: todo, column: .ready, binderID: state.binderID, by: .you).card
        } else if let cardID = state.card, let existing = controller.board.card(cardID) {
            card = existing
        } else {
            return (false, "It's gone.")
        }
        // A hand-off you tapped: the agent is woken at once. After Stop, Undo then stops this one first.
        controller.board.give(card, to: profile.name, by: .you)
        state.card = card.id
        state.stopped = nil
        state.outcome.actions = ["undo"]
        state.outcome.card = card.id.uuidString
        state.outcome.line = "Gave “\(state.task)” to \(profile.name), in \(binder)"
        state.outcome.title = "Given to \(profile.name)"
        return (true, state.outcome.line)
    }

    // MARK: Storage

    private func record(_ id: UUID) -> TranscriptRecord? {
        var descriptor = FetchDescriptor<TranscriptRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? Store.shared.context.fetch(descriptor))?.first
    }

    private func state(_ id: UUID) -> State? {
        guard let record = record(id), record.mode == "moment", let data = record.outcomeJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(State.self, from: EarlierSpellings.json(data))
    }

    private func keep(_ state: State, payload: MomentPayload, model: String?, llmMillis: Int) {
        // Writing it down happened on the iPhone, which says how long it took.
        let record = TranscriptRecord(id: payload.id, createdAt: payload.heard, mode: "moment", rawText: payload.text,
                                      finalText: state.outcome.line.isEmpty ? "Nothing to do" : state.outcome.line, appName: payload.device ?? "iPhone",
                                      bundleID: nil, category: nil, duration: payload.seconds ?? 0, asrMillis: payload.asrMillis ?? 0, llmMillis: llmMillis,
                                      engine: payload.engine ?? "iPhone", llmModel: model, usedLLM: model != nil, fallbackReason: nil,
                                      audioFileName: nil, status: "answered")
        record.outcomeJSON = (try? JSONEncoder().encode(state)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        Store.shared.insert(record)
    }

    private func save(_ state: State, id: UUID) {
        guard let record = record(id) else { return }
        record.outcomeJSON = (try? JSONEncoder().encode(state)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        record.finalText = state.outcome.line.isEmpty ? record.finalText : state.outcome.line
        Store.shared.save()
    }
}

/// The paired iPhones Auto may hand over from without a tap, in the Mac's preferences ("autoPhones"). Another person's
/// iPhone, paired to this Mac and calibrated to their voice, would otherwise hand their words to your agents. With one
/// device paired, Auto from it may, and it's remembered, so pairing a second one later doesn't take that away; with two or
/// more, only the ones you allow. A device the link doesn't name may only while one at most is paired.
enum AutoPhones {
    static let key = "autoPhones"

    /// The devices allowed so far.
    static var allowed: Set<UUID> { Set((AppDefaults.store.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))) }

    /// Whether Auto from `device` may hand over, with `paired` the devices paired now; the only one paired is remembered.
    static func allows(_ device: UUID?, paired: [UUID]) -> Bool {
        if let device, allowed.contains(device) { return true }
        guard paired.count <= 1 else { return false }
        if let device, paired == [device] { allow(device) }
        return true
    }

    static func allow(_ device: UUID) {
        AppDefaults.store.set(allowed.union([device]).map(\.uuidString).sorted(), forKey: key)
    }

    static func forget(_ device: UUID) {
        AppDefaults.store.set(allowed.subtracting([device]).map(\.uuidString).sorted(), forKey: key)
    }
}
