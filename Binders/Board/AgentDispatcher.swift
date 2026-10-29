import AppKit
import Foundation
import BindersKit

/// Wakes the agent a card is meant for when you make the card ready for it, answer its question, comment on it while it
/// holds it in progress, or send its work back. Every board change passes BoardService.log, which tells it. Only a
/// person's change wakes anyone: nothing an agent does (its own writes, a lapse), no note by Binders itself, and nothing
/// from speech or a capture wakes an agent without your tap. Edits and comments are gathered for two seconds, while your
/// explicit hand-offs (Give to, Assign) go at once; wakes are capped per agent per hour, and each one leaves a line on the
/// card. What a wake carries of your words is read from the card's timeline when it goes (`CardConversation.wakeWords`).
/// The first time a card goes to an agent, what its binder knows goes on it first (`AgentBriefing`). It also keeps to how
/// each agent reports back: a card is held for an agent that doesn't report with Binders' tools, and a status address is
/// asked how its card is going.
@MainActor
@Observable
final class AgentDispatcher {
    let registry: AgentRegistry
    @ObservationIgnored weak var board: BoardService?
    /// Shows a line in the Flow bar: text and symbol.
    @ObservationIgnored var notify: ((String, String) -> Void)?
    /// The last wake of each card, and how it went.
    private(set) var outcomes: [UUID: AutomationService.Outcome] = [:]
    /// Cards an agent is working on in a run Binders started.
    private(set) var working: Set<UUID> = []
    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]
    /// Why each pending wake will wake its agent, for a CLI run's end: an answer that hasn't fired yet still goes first.
    @ObservationIgnored private var pendingReasons: [UUID: AgentWake.Reason] = [:]
    /// Cards whose wake is gathering for its two seconds, for the line under your words ("Sending in a moment").
    private(set) var gathering: Set<UUID> = []
    /// Each agent's wakes in the last hour. Observed, so the composer's count of wakes left follows another card's wake.
    private var woken: [UUID: [Date]] = [:]
    /// Why the newest of your words on each card didn't go to its agent, and when Binders decided so: the line under them.
    private(set) var notSent: [UUID: (at: Date, why: String)] = [:]
    /// When a card's last wake outcome was a comment of yours not sent (an iPhone that didn't ask first, the hourly cap)
    /// rather than a hand-off, so the composer never reads it as a hand-off that didn't go.
    @ObservationIgnored private var refusals: [UUID: Date] = [:]
    /// Each card's web hook post or Shortcut run on its way, and whether its wake carried comments of yours: while one is,
    /// a wake that carries them, or any wake while one that carried them is on its way, waits for it to settle (`settled`).
    @ObservationIgnored private var sending: [UUID: Bool] = [:]
    /// For the self-tests, in a throwaway folder only: stands in for a web hook's post and a Shortcut's run, given the
    /// agent and the card's JSON, and throws as they would fail. Nothing leaves this Mac.
    @ObservationIgnored var standIn: (@MainActor (AgentProfile, Data) async throws -> Void)?
    @ObservationIgnored private var runs: [UUID: Process] = [:]
    /// The folder each Claude Code run that works in the folder itself started in, by card: one card runs there at a time.
    @ObservationIgnored private var inFolderRuns: [UUID: String] = [:]
    /// Which run each card's process is, so a run that ends late can't let go of a newer one's card.
    @ObservationIgnored private var runIDs: [UUID: UUID] = [:]
    /// A wake that came while the card's run was still going, kept for when it ends: the reason, and whether you tapped.
    private var deferred: [UUID: (reason: AgentWake.Reason, tapped: Bool)] = [:]
    /// The Claude Code session of each card's run, as its hooks name it.
    @ObservationIgnored private var sessions: [UUID: UUID] = [:]
    /// How each card's Claude Code run was started: limited to Binders' tools or not, why, and whether it's the one start
    /// again without the limit after a refusal (`ClaudeCodeManaged`).
    @ObservationIgnored private var launches: [UUID: (onlyBinders: Bool, reason: AgentWake.Reason, again: Bool)] = [:]
    /// Runs whose last word is on their card (by session, lowercased), from a hook or from the run's end, so nothing says
    /// it twice; kept half a day.
    @ObservationIgnored private var runReports: [String: Date] = [:]
    /// Cards whose run you stopped, which isn't news to tell you about.
    @ObservationIgnored private var stopping: Set<UUID> = []
    /// The command-line tools' runs (Codex, OpenCode, GitHub Copilot CLI): each card's run while it goes, as its record
    /// says, and its agent. A card's run counts as going until its end steps are done.
    @ObservationIgnored private var cliRuns: [UUID: CLIRunRecord] = [:]
    /// Cards whose CLI run is being made ready (its program checked, its worktree made), before it starts.
    @ObservationIgnored private var starting: Set<UUID> = []
    /// Cards whose CLI run has ended and whose end steps (the commit among them) are under way.
    @ObservationIgnored private var finishing: Set<UUID> = []
    /// CLI runs a Binders before this one started, still going, watched by their process.
    @ObservationIgnored private var adopted: [UUID: DispatchSourceProcess] = [:]
    /// CLI runs the two-hour limit stopped.
    @ObservationIgnored private var limited: Set<UUID> = []
    /// For the self-tests: called right before a CLI run's changes are committed.
    @ObservationIgnored var beforeCommit: ((UUID) -> Void)?
    /// When each card's status address was last asked, and the cards being asked now.
    @ObservationIgnored private var asked: [UUID: Date] = [:]
    @ObservationIgnored private var asking: Set<UUID> = []
    @ObservationIgnored private var statusTimer: Timer?
    /// How a status address is asked. The self-tests answer in its place.
    @ObservationIgnored var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    /// What Binders tells the agent holding a card about the spec it came from (a section that changed after the card
    /// was made, `tell`), by card, oldest first, until a wake carries them.
    private(set) var notices: [UUID: [SectionNotice]] = [:]
    /// Whether the agent may read teammates' items, as Settings → MCP lets its tool: a teammate's changed lines reach only
    /// such an agent. The self-tests answer in its place.
    @ObservationIgnored var readsTeam: @MainActor (AgentProfile) -> Bool = { AgentBriefing.reads(for: $0.name).team }
    /// Cards a run's end moved to Blocked: the stop rang already, or you stopped it yourself, so Distill doesn't ring for
    /// them again (`takeSaidBlocked`).
    @ObservationIgnored private var blockedAtRunEnd: Set<UUID> = []

    /// A section's change, as Binders tells the agent holding the card: its line (changed lines and all) and whose change
    /// it was (`mark`), so each agent woken hears only what it may (`DistilledFrom.forAgent`). No mark: Binders' own words,
    /// told as they are (a change passed on once you looked).
    struct SectionNotice: Equatable {
        var line: String
        var mark: SectionChangeMark?

        func text(readsTeam: Bool) -> String? {
            guard let mark else { return line }
            return DistilledFrom.forAgent(line, mark: mark, readsTeam: readsTeam)
        }
    }

    /// A run's end moves the card to Blocked, and its stop rings (or you stopped it yourself).
    func saidBlocked(_ card: UUID) { blockedAtRunEnd.insert(card) }

    /// Whether a run's end moved the card to Blocked since Distill last asked: then the board already said it.
    func takeSaidBlocked(_ card: UUID) -> Bool { blockedAtRunEnd.remove(card) != nil }
    /// Teammates' cards (lane DB2) that wait for your Give to: meant for one of your agents whose Take cards from
    /// teammates, or start switch, is off.
    private(set) var waitingForYou: Set<UUID> = []

    /// A run is stopped after this long.
    static let runLimit: TimeInterval = 2 * 3_600
    /// How long Binders gathers your edits on a card before it wakes the agent: a hand-off you tap doesn't wait.
    static let editDelay: Duration = .seconds(2)
    /// How often Binders asks an agent's status address about a card it holds for it, while the card is in progress.
    static let statusInterval: TimeInterval = 3 * 60

    init(registry: AgentRegistry = .shared) {
        self.registry = registry
    }

    /// Where the runs Binders starts write what they say: outside the data folder, which they may not read. In a throwaway
    /// data folder, beside it (`AgentPlaces`), so the self-tests never write into your Logs.
    static var logs: URL { AgentPlaces.logs }

    /// Starts asking status addresses: every minute, about the cards that are due. And takes up the CLI runs a Binders
    /// before this one started: one still going is watched until it ends, and one that ended meanwhile is ended now.
    func start() {
        resumeCLIRuns()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.askStatuses() }
            }
        }
    }

    // MARK: Hearing the board

    /// A change on the board: wakes the agent the card is meant for, a moment later, when the change asks for it. One
    /// that checks the board itself is never woken: a card you make ready for it is handed over as it is. A note by
    /// Binders itself is a comment by a person named Binders: it's never yours, so it wakes no one. `wake` narrows what a
    /// phone's comment may wake (`CommentWake`). A comment that comes while a stronger wake gathers (an answer, a
    /// send-back, made ready) keeps that wake's reason, and both sets of words go with it.
    /// `cause`: whose change it is. Yours (made on this Mac) wakes as it always did; a teammate's, from the team database,
    /// or an agent's placing under Agents may place work items, wakes the agent only as its switches say
    /// (`TeamWakeRule`), and otherwise the card waits for your Give to.
    func noticed(_ card: TaskCard, _ kind: TaskEvent.Kind, by actor: BoardActor, from: BoardColumn?, to: BoardColumn?,
                 wake: CommentWake = .asTheBoardSays, cause: TeamWakeCause = .yours) {
        // Done: the cards that waited for it may be ready for their agents now.
        if to == .done, from != .done, let board {
            for other in board.waiting(on: card) { waitEnded(on: other) }
        }
        // Binders' own comments and moves (the Manager's tidying and its Undo, lane MG1) wake no one.
        let yours = !actor.isAgent && !([.comment, .moved].contains(kind) && actor.name == BoardService.binders.name)
        let commented = yours && kind == .comment
        guard let reason = AgentWake.reason(kind: kind.rawValue, from: from, to: to, column: card.column, byPerson: yours),
              let agent = target(for: card, reason: reason) else {
            if commented { noteUnsent(card) }
            return
        }
        if agent.wake == .board, reason == .ready, !registry.paused, !registry.changedOutside.contains(agent.id), let board {
            AgentBriefing.brief(card, for: agent, board: board)
        }
        guard registry.wakeable(agent) else {
            if commented { noteUnsent(card) }
            return
        }
        if cause != .yours, let waits = waitsForYou(card, agent: agent, cause: cause, reason: reason) {
            if reason != .ready { refuse(card.id, waits) }
            return
        }
        let id = card.id
        if reason == .commented {
            // A phone's comment wakes only the agent it asked you about; one from a phone that doesn't ask first, no one.
            switch wake {
            case .none:
                return refuse(id, "Not sent to \(agent.name): Binders on your iPhone needs an update before its comments wake an agent. Wake Now sends it.",
                              onTheCard: true)
            case .only(let name) where !AgentRegistry.isAgent(agent, named: name):
                return refuse(id, "Not sent to \(agent.name): your iPhone didn't ask you about \(agent.name) first. Wake Now sends it.", onTheCard: true)
            default:
                break
            }
        }
        let fires = reason == .commented ? (pendingReasons[id].flatMap { $0 == .commented ? nil : $0 } ?? reason) : reason
        pending[id]?.cancel()
        pendingReasons[id] = fires
        gathering.insert(id)
        pending[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.editDelay)
            guard !Task.isCancelled else { return }
            self?.gathering.remove(id)
            self?.fire(id, reason: fires, tapped: false)
        }
    }

    /// Your comment just now didn't wake the agent the card is meant for: why, for the line under it, as the composer
    /// said before you sent it.
    private func noteUnsent(_ card: TaskCard) {
        guard let board, let why = commentReach(for: card, events: board.timeline(card.id)).unsentLine else { return }
        refuse(card.id, why)
    }

    /// Why your words didn't go, for the line under them; `onTheCard` also puts it in the card's line about its last wake,
    /// marked as a comment not sent rather than a hand-off that didn't go.
    private func refuse(_ id: UUID, _ why: String, onTheCard: Bool = false) {
        notSent[id] = (Date(), why)
        guard onTheCard else { return }
        record(id, ok: false, why)
        refusals[id] = outcomes[id]?.at
    }

    /// Whether a change that wasn't yours may wake `agent` (TeamWakeRule): nil when it may; else why the card waits for
    /// your Give to, which a card made ready for it says once, on its timeline.
    private func waitsForYou(_ card: TaskCard, agent: AgentProfile, cause: TeamWakeCause, reason: AgentWake.Reason) -> String? {
        guard case .waits(let line) = TeamWakeRule.verdict(cause, agent: agent.name, takesTeammatesCards: agent.takesTeammatesCards,
                                                           startsOnItsOwn: registry.startsOnItsOwn(agent)) else { return nil }
        guard reason == .ready || reason == .manual else { return line }
        waitingForYou.insert(card.id)
        record(card.id, ok: false, line)
        if let board, !board.timeline(card.id).contains(where: { $0.author == BoardService.binders.name && $0.text == line }) {
            board.note(card, text: line, toTeam: true)
        }
        return line
    }

    /// A teammate's card that waits for your Give to: still in Ready, meant for one of your agents, by a person.
    func waitsForYourGiveTo(_ card: TaskCard) -> Bool {
        guard waitingForYou.contains(card.id) else { return false }
        guard card.column == .ready, !card.meantForByAgent, let meant = card.meantFor, registry.agent(named: meant) != nil else {
            waitingForYou.remove(card.id)
            return false
        }
        return true
    }

    /// What a hand-off did: woke the agent (a run started, or the card was sent or posted), or why not, in the words the
    /// card's line already uses. A web hook or a Shortcut that fails after its receipt says so on the card later.
    enum HandOff: Equatable {
        case woke
        case notWoken(String)
    }

    /// An explicit hand-off, your Give to or Assign: the agent the card is meant for is woken now, not after the moment
    /// edits wait, so the hand-off is under way within the 3 seconds Assign has. Still once, and within its hourly cap.
    @discardableResult
    func handOff(_ card: TaskCard) -> HandOff {
        guard card.column == .ready, let agent = target(for: card, reason: .ready) else { return .notWoken("It isn't in Ready for an agent that takes it.") }
        // Your tap: a teammate's card that waited for it waits no longer.
        waitingForYou.remove(card.id)
        guard registry.wakeable(agent) else { return .notWoken(registry.paused ? "Agents are paused." : "\(agent.name) can't be woken now.") }
        if let waiting = waitsLine(card, agent: agent) {
            record(card.id, ok: false, waiting)
            return .notWoken(waiting)
        }
        pending[card.id]?.cancel()
        pending[card.id] = nil
        pendingReasons[card.id] = nil
        gathering.remove(card.id)
        return fire(card.id, reason: .ready, tapped: false)
    }

    /// Whether Binders would wake this agent for a card now, before it's handed one: it may be woken (on, not changed
    /// outside, not held, not paused, not one that checks the board itself) and it's under its hourly cap. A card Binders
    /// would hand over without asking is only suggested otherwise, rather than left in Ready unannounced.
    func wouldWake(_ agent: AgentProfile, now: Date = Date()) -> Bool {
        guard registry.wakeable(agent) else { return false }
        let recent = (woken[agent.id] ?? []).filter { now.timeIntervalSince($0) < 3_600 }
        return recent.count < (agent.wakesPerHour ?? AgentProfile.defaultWakesPerHour)
    }

    /// The agent to wake: the one you meant the card for, or, for an answer, a comment or a sent-back card, that agent when
    /// it's the one holding the card (an interactive session's own card never starts a run). For a comment, its claim must
    /// still be live: one that has run out wakes no one in the minute before the sweep lets the card go, as get_task
    /// already shows no holder for it.
    private func target(for card: TaskCard, reason: AgentWake.Reason) -> AgentProfile? {
        guard let meant = card.meantFor, !card.meantForByAgent else { return nil }
        let agent: AgentProfile?
        switch reason {
        case .ready, .manual:
            agent = registry.agent(named: meant)
        case .answered, .commented, .sentBack:
            // Only the agent itself holding it: a session that goes by a name like it isn't the run Binders started.
            guard card.assigneeIsAgent, let holder = card.assignee, let found = registry.agent(named: meant),
                  AgentRegistry.isAgent(found, named: holder) else { return nil }
            if reason == .commented, !Self.holds(found, card) { return nil }
            agent = found
        }
        // Only on the boards you let it work on.
        return agent.flatMap { $0.takesCards(from: card.binderID) ? $0 : nil }
    }

    /// Still due: the card hasn't moved on since the reason to wake its agent.
    private static func isDue(_ card: TaskCard, for reason: AgentWake.Reason) -> Bool {
        switch reason {
        case .ready: card.column == .ready
        case .answered, .commented, .sentBack: card.column == .inProgress
        case .manual: card.column != .done
        }
    }

    /// The reason to wake the card's agent now: `reason` while it's still due and has its agent (for a comment's, while it
    /// has comments of yours it hasn't had), else, when it went stale meanwhile (a `ready` whose card the agent has claimed
    /// since), a comment's wake if that's due and it has such comments: a stale reason never drops your comments. Nil when
    /// nothing is due.
    private func dueReason(_ card: TaskCard, _ reason: AgentWake.Reason) -> AgentWake.Reason? {
        if Self.isDue(card, for: reason), let agent = target(for: card, reason: reason), reason != .commented || hasUnheardComments(card, agent) {
            return reason
        }
        guard reason != .commented, Self.isDue(card, for: .commented), let agent = target(for: card, reason: .commented),
              hasUnheardComments(card, agent) else { return nil }
        return .commented
    }

    /// The wake that waited for a run to end, now that it has: its reason while the card still wants it, as it always went;
    /// else, gone stale, a comment's wake when comments of yours are waiting for the agent (`dueReason`).
    private func dueAtRunEnd(_ card: TaskCard, _ reason: AgentWake.Reason) -> AgentWake.Reason? {
        Self.isDue(card, for: reason) ? reason : dueReason(card, reason)
    }

    /// Whether the card has comments of yours a comment's wake is for that the agent hasn't had
    /// (`CardConversation.unheardComments`).
    private func hasUnheardComments(_ card: TaskCard, _ agent: AgentProfile) -> Bool {
        guard let board else { return false }
        // A notice about its spec is for it as your comment would be.
        if notices[card.id] != nil { return true }
        return !CardConversation.unheardComments(board.timeline(card.id).map(\.conversation), agent: agent.name, failureLines: Self.failureLines).isEmpty
    }

    @discardableResult
    private func fire(_ id: UUID, reason asked: AgentWake.Reason, tapped: Bool) -> HandOff {
        // A comment's wake gathering for its two seconds is taken over by this one, which carries its words. A stronger wake
        // gathering (an answer, a send-back, made ready) isn't: it goes as it always has, unless this is a comment's wake
        // (a run's end firing one that waited), which then goes as that stronger wake, now, with the comment's words.
        var asked = asked
        if let gathered = pendingReasons[id], gathered == .commented || asked == .commented {
            pending[id]?.cancel()
            gathering.remove(id)
            asked = asked == .commented ? gathered : asked
        }
        pending[id] = nil
        pendingReasons[id] = nil
        guard let board, let card = board.card(id), let reason = dueReason(card, asked), let agent = target(for: card, reason: reason),
              registry.wakeable(agent) else { return .notWoken("It isn't waiting for an agent that can be woken now.") }
        // A card that still waits for others isn't handed over: its agent couldn't take it. It's woken once they're done.
        // One the agent holds already goes on.
        if reason == .ready || reason == .manual, !Self.holds(agent, card), let waiting = waitsLine(card, agent: agent) {
            record(id, ok: false, waiting)
            return .notWoken(waiting)
        }
        if runs[id]?.isRunning == true || isCLIRunGoing(id) {
            // Its run is ending (or still going): woken again once it has, if the card still wants it then.
            keepForLater(id, reason, tapped)
            record(id, ok: true, "\(agent.name) is already working on it")
            return .notWoken("\(agent.name) is already working on it")
        }
        if let carried = sending[id], carried || hasUnheardComments(card, agent) {
            // Its web hook post or Shortcut run is on its way: this wake goes once that has settled, so a failure on the card
            // is always its own wake's, and your comments reach the agent in order.
            keepForLater(id, reason, tapped)
            return .notWoken("\(agent.name) is still being sent the card")
        }
        let now = Date()
        let recent = (woken[agent.id] ?? []).filter { now.timeIntervalSince($0) < 3_600 }
        let cap = agent.wakesPerHour ?? AgentProfile.defaultWakesPerHour
        if !tapped, recent.count >= cap {
            let message = "Not woken: \(agent.name) was woken \(cap) times in the last hour. Wake Now on the card does it."
            record(id, ok: false, message)
            if reason == .commented { refusals[id] = outcomes[id]?.at }
            notSent[id] = (now, "Not sent: \(agent.name) was woken \(cap) times in the last hour. Wake Now sends it.")
            notify?(message, "hand.raised")
            return .notWoken("\(agent.name) was woken \(cap) times in the last hour")
        }
        woken[agent.id] = recent + [now]
        // Handed over: what the card's binder knows goes on it first, the first time.
        if reason == .ready || reason == .manual { AgentBriefing.brief(card, for: agent, board: board) }
        return wake(agent, card: card, reason: reason)
    }

    /// A wake for once the card's run has ended, or its post has settled: it takes the place of one already waiting, as it
    /// always has, except that a comment's never takes the place of a stronger one (an answer, a send-back, Wake Now), which
    /// goes as it was and carries the comment's words.
    private func keepForLater(_ id: UUID, _ reason: AgentWake.Reason, _ tapped: Bool) {
        if reason == .commented, let waiting = deferred[id], waiting.reason != .commented { return }
        deferred[id] = (reason, tapped)
    }

    /// The card's web hook post or Shortcut run has settled, its failure line (if any) on the card: a wake that waited for
    /// it goes now, if the card still wants it.
    private func settled(_ id: UUID) {
        sending[id] = nil
        guard runs[id]?.isRunning != true, !isCLIRunGoing(id), let (reason, tapped) = deferred.removeValue(forKey: id) else { return }
        guard let card = board?.card(id), let due = dueReason(card, reason) else { return }
        fire(id, reason: due, tapped: tapped)
    }

    // MARK: Your taps

    /// Wake Now on the card: no waiting, and past the hourly cap (it still counts). Nil when it's on its way, else why not.
    @discardableResult
    func wakeNow(_ card: TaskCard) -> String? {
        guard card.column != .done else { return "It's done." }
        guard let name = card.meantFor, !card.meantForByAgent, let agent = registry.agent(named: name) else {
            return "Give it to an agent first: For, on the card."
        }
        if registry.paused { return "Agents are paused. Resume them in Settings → Agents." }
        if registry.changedOutside.contains(agent.id) { return "\(agent.name) was changed outside Binders. Open it in Settings → Agents and save it." }
        if let why = registry.held[agent.id] { return why }
        if agent.wake == .board { return "\(agent.name) checks the board itself." }
        if !Self.holds(agent, card), let waiting = waitsLine(card, agent: agent) { return waiting + " You can take it yourself." }
        fire(card.id, reason: card.column == .ready ? .ready : .manual, tapped: true)
        return nil
    }

    // MARK: Cards that wait for others

    /// What a card still waits for, said as why its agent isn't woken: "Waits for “A”. Binders wakes Claude Code once
    /// it's done." Nil when it waits for nothing that's open.
    func waitsLine(_ card: TaskCard, agent: AgentProfile) -> String? {
        guard let board, let line = CardWaits.line(board.openWaits(of: card)) else { return nil }
        let open = board.openWaits(of: card).count
        return "\(line). Binders wakes \(agent.name) once \(open == 1 ? "it's" : "they're") done."
    }

    /// One of the cards this one waited for is done, or gone: when that was its last wait and it's in Ready for an agent
    /// you meant it for, a note by Binders says so and the agent is woken for it, as for a card you made ready.
    func waitEnded(on card: TaskCard) {
        guard let board, card.column == .ready, !card.waitsFor.isEmpty, board.openWaits(of: card).isEmpty,
              let agent = target(for: card, reason: .ready) else { return }
        let finished = board.waits(of: card).map { "“\($0.title)”" }
        let what = finished.count == 1 ? "\(finished[0]) is done" : finished.isEmpty ? "What it waited for is gone" : "What it waited for is done"
        board.note(card, text: "\(what), so this card is ready for \(agent.name).", toTeam: true)
        guard registry.wakeable(agent) else { return }
        // On the team's board, a card a teammate gave it, or an agent placed, wakes it only as its switches say.
        if let team = board.team, team.covers(card), let given = board.timeline(card.id).last(where: { $0.kind == .assigned }) {
            let cause = team.cause(of: given, incoming: false)
            if cause != .yours, waitsForYou(card, agent: agent, cause: cause, reason: .ready) != nil { return }
        }
        let id = card.id
        pending[id]?.cancel()
        pendingReasons[id] = .ready
        gathering.insert(id)
        pending[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.editDelay)
            guard !Task.isCancelled else { return }
            self?.gathering.remove(id)
            self?.fire(id, reason: .ready, tapped: false)
        }
    }

    // MARK: Telling the agent about its spec

    /// Tells the agent holding the card what changed in the spec it came from (`notice`, a section's change), the way your
    /// comment reaches it: woken now, gathered for the moment edits wait, within its hourly cap and after a run that's
    /// going, with what of it the agent woken may hear in what the wake carries. Held by no agent in progress, the notice
    /// waits for the card's next wake. Notices not yet carried go together, the last few.
    func tell(_ card: TaskCard, notice: SectionNotice) {
        let id = card.id
        notices[id, default: []].append(notice)
        if let kept = notices[id], kept.count > 5 { notices[id] = Array(kept.suffix(5)) }
        guard let agent = target(for: card, reason: .commented), registry.wakeable(agent) else { return }
        let fires = pendingReasons[id].flatMap { $0 == .commented ? nil : $0 } ?? .commented
        pending[id]?.cancel()
        pendingReasons[id] = fires
        gathering.insert(id)
        pending[id] = Task { [weak self] in
            try? await Task.sleep(for: Self.editDelay)
            guard !Task.isCancelled else { return }
            self?.gathering.remove(id)
            self?.fire(id, reason: fires, tapped: false)
        }
    }

    func isWorking(on card: UUID) -> Bool { working.contains(card) }

    /// A run Binders started for the card is going, or a CLI run for it is being made ready, adopted or ending: something
    /// Stop stops. Not a web hook, a Shortcut, a command that has rung its agent and ended, or a post to an open session.
    func isBusy(on card: UUID) -> Bool { working.contains(card) || isCLIRunGoing(card) }

    /// A CLI run is being made ready, going, adopted or ending for the card: a new one waits until it's done.
    private func isCLIRunGoing(_ id: UUID) -> Bool {
        starting.contains(id) || finishing.contains(id) || adopted[id] != nil || cliRuns[id] != nil
    }

    /// Stop, on the card while a run is going, or you taking the card over. A CLI run is asked to stop as each tool ends a
    /// turn cleanly (SIGINT, then SIGTERM), and one still being made ready doesn't start.
    func stop(_ card: UUID) {
        deferred[card] = nil
        if let record = cliRuns[card] {
            stopping.insert(card)
            if let process = runs[card], process.isRunning { CLIRuns.interrupt(process) } else { CLIRuns.interrupt(record) }
            return
        }
        if starting.contains(card) { stopping.insert(card) }
        if runs[card]?.isRunning == true { stopping.insert(card) }
        runs[card]?.terminate()
    }

    /// The card is gone: nothing more for it.
    func forget(_ card: UUID) {
        waitingForYou.remove(card)
        pending[card]?.cancel()
        pending[card] = nil
        pendingReasons[card] = nil
        gathering.remove(card)
        notSent[card] = nil
        notices[card] = nil
        refusals[card] = nil
        asked[card] = nil
        stop(card)
    }

    // MARK: Waking

    @discardableResult
    private func wake(_ agent: AgentProfile, card: TaskCard, reason: AgentWake.Reason) -> HandOff {
        let handed = wakeCarrying(agent, card: card, reason: reason)
        // Carried: the notice about its spec went with this wake.
        if handed == .woke { notices[card.id] = nil }
        return handed
    }

    @discardableResult
    private func wakeCarrying(_ agent: AgentProfile, card: TaskCard, reason: AgentWake.Reason) -> HandOff {
        let words = wakeWords(for: agent, on: card)
        let payload = AgentWakePayload(event: reason.rawValue, agent: agent.name, card: card.id, title: card.title, details: card.details,
                                       binder: Store.shared.binder(card.binderID)?.name ?? "", column: card.column, due: card.dueAt,
                                       links: card.links, answer: words.answer,
                                       context: board.map { AgentBriefing.text(on: card, for: agent, board: $0) } ?? "",
                                       mayAct: !agent.draftsFirst)
        let id = card.id
        // The self-tests run only programs they write themselves, in their throwaway folder: never a real hook, Shortcut or
        // Claude. A web hook or a Shortcut goes to the self-test's stand-in, when it has one.
        let standIn = AppPaths.isDemo ? self.standIn : nil
        if AppPaths.isDemo, !Self.isOwnProgram(agent.wake), standIn == nil || !Self.isSent(agent.wake) {
            record(id, ok: false, "Not run in a throwaway folder")
            return .notWoken("Not run in a throwaway folder")
        }
        switch agent.wake {
        case .board:
            return .notWoken("\(agent.name) checks the board itself")
        case .command(let command, let folder):
            // Never a command that turns an agent's checks off, whoever wrote it into agents.json.
            if let what = AgentCommands.refusal(command) {
                record(id, ok: false, "Not run: " + AgentCommands.message(what))
                return .notWoken(AgentCommands.message(what))
            }
            let log = Self.logFile(for: id)
            let run = UUID()
            do {
                let process = try AutomationService.launch("/bin/zsh", ["-lc", command], stdin: String(decoding: payload.json, as: UTF8.self),
                                                           environment: AutomationService.environment(payload.fields),
                                                           directory: folder.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
                                                           log: log, limit: Self.runLimit) { status in
                    Task { @MainActor [weak self] in self?.finished(id, run: run, agent: agent, status: status, log: log) }
                }
                started(id, process, run: run)
                receipt(card, agent: agent, "Woke \(agent.name) with its command (\(Self.describe(reason))).", log: log)
                handedOver(id, agent: agent)
                return .woke
            } catch {
                record(id, ok: false, "Couldn't start \(agent.name): \(error.localizedDescription)")
                return .notWoken("Couldn't start \(agent.name): \(error.localizedDescription)")
            }
        case .webhook(let address):
            let token = registry.token(for: agent.id)
            receipt(card, agent: agent, "Sent \(agent.name) the card at \(URL(string: address)?.host ?? address) (\(Self.describe(reason))).", log: nil)
            sending[id] = words.joined
            Task { [weak self] in
                do {
                    if let standIn {
                        try await standIn(agent, payload.json)
                    } else {
                        _ = try await AutomationService.post(address, body: payload.json, headers: token.map { ["Authorization": "Bearer \($0)"] } ?? [:])
                    }
                    self?.record(id, ok: true, "Sent to \(agent.name)")
                    self?.handedOver(id, agent: agent)
                } catch {
                    self?.record(id, ok: false, "\(agent.name)'s web hook: \(error.localizedDescription)")
                    // The receipt said it was sent: the card says it didn't arrive, too, if it's still there.
                    if let board = self?.board, let current = board.card(id) {
                        board.woke(current, agent: agent.name, text: "Its web hook didn't take the card: \(error.localizedDescription)", log: nil)
                    }
                }
                self?.settled(id)
            }
            return .woke
        case .shortcut(let name):
            receipt(card, agent: agent, "Ran the Shortcut “\(name)” for \(agent.name) (\(Self.describe(reason))).", log: nil)
            sending[id] = words.joined
            Task { [weak self] in
                do {
                    if let standIn {
                        try await standIn(agent, payload.json)
                    } else {
                        _ = try await AutomationService.runShortcut(name, input: String(decoding: payload.json, as: UTF8.self))
                    }
                    self?.record(id, ok: true, "Ran “\(name)”")
                    self?.handedOver(id, agent: agent)
                } catch {
                    self?.record(id, ok: false, "“\(name)”: \(error.localizedDescription)")
                    // A wake that carried comments of yours: the card says it didn't take them, as a web hook's does, so the
                    // line under them says so and the next wake carries them again.
                    if words.joined, let board = self?.board, let current = board.card(id) {
                        board.woke(current, agent: agent.name, text: "Its Shortcut didn't take the card: \(error.localizedDescription)", log: nil)
                    }
                }
                self?.settled(id)
            }
            return .woke
        case .claudeCode(let wake):
            // The session you have open in its repository, when you let Binders post to it: a run only when none is open.
            // A card the agent itself holds, taken by a run of it, goes on in a run: your session can't take it over.
            if wake.postsToOpenSession {
                guard !Self.holds(agent, card) else {
                    return wakeClaude(agent, wake, card: card, reason: reason, before: "\(agent.name) has this card from an earlier run, so it goes on in a run: an open session can't take over a run's card. ")
                }
                return postToOpenSession(agent, wake, card: card, reason: reason)
            }
            return wakeClaude(agent, wake, card: card, reason: reason)
        case .cliAgent(let wake):
            wakeCLI(agent, wake, card: card, reason: reason)
            return .woke
        case .localModel:
            // Only ever the Manager (lane MG2): `takesCards` keeps cards from it, and one that names it anyway waits.
            return .notWoken("\(agent.name) is a local model that's only the Manager: it takes no cards.")
        }
    }

    /// In a throwaway folder: a command a self-test wrote, or a stand-in for claude or a CLI tool that it put in the
    /// folder. Never the real tools.
    private static func isOwnProgram(_ wake: AgentProfile.Wake) -> Bool {
        func inFolder(_ path: String?) -> Bool { path.map { ($0 as NSString).expandingTildeInPath.hasPrefix(AppPaths.support.path + "/") } ?? false }
        switch wake {
        case .command: return true
        case .claudeCode(let claude): return inFolder(claude.executable)
        case .cliAgent(let cli): return inFolder(cli.executable)
        default: return false
        }
    }

    /// A web hook or a Shortcut: sent on its way, settling later (`settled`), and in a throwaway folder only to a stand-in.
    private static func isSent(_ wake: AgentProfile.Wake) -> Bool {
        switch wake {
        case .webhook, .shortcut: true
        default: false
        }
    }

    /// A wake went through. An agent that doesn't report with Binders' tools can't take the card itself, so Binders holds
    /// it for the agent, In progress: its status address is then asked how it's going, or, when you move its cards
    /// yourself, it's held with no time limit. As the agent, so it wakes nothing.
    private func handedOver(_ id: UUID, agent: AgentProfile) {
        let reporting = agent.reporting
        guard !reporting.usesTools, let board, let card = board.card(id), card.column == .ready || card.column == .backlog,
              !BoardRules.isClaimed(card.state, at: Date()) else { return }
        let note = switch reporting {
        case .status: "Binders holds it for \(agent.name), and asks its status address how it's going."
        default: "Binders holds it for \(agent.name), with no time limit. Move it along as the work goes."
        }
        do {
            try board.claim(card, by: BoardActor(name: agent.name, kind: .agent), note: note)
            asked[id] = Date()
        } catch {
            record(id, ok: false, error.localizedDescription)
        }
    }

    /// Claude Code, started on its own in a git worktree for the card, with its permission checks on and Binders' board
    /// tools only, under the agent's name. The card's id is all it's given; it reads the card through the tools. Its
    /// hooks report on the card when it stops (`reported`), and its environment says which card that is. Unless you let
    /// it act for you, its prompt has it ask your approval before it sends, posts, buys or deletes anything. `note` goes
    /// before its receipt: why a run started rather than a post to your open session.
    @discardableResult
    private func wakeClaude(_ agent: AgentProfile, _ wake: ClaudeCodeWake, card: TaskCard, reason: AgentWake.Reason, before note: String = "",
                            again: Bool = false) -> HandOff {
        let id = card.id
        // Paths as written in agents.json may start with "~", which nothing below would expand.
        var wake = wake
        wake.repository = (wake.repository as NSString).expandingTildeInPath
        wake.executable = wake.executable.map { ($0 as NSString).expandingTildeInPath }
        let repository = wake.repository
        // In the folder itself, one card at a time: two runs would change the same files.
        if wake.worksInFolder, let other = inFolderRuns.first(where: { $0.key != id && $0.value == repository && runs[$0.key] != nil })?.key {
            let line = "\(agent.name) is working in \((repository as NSString).abbreviatingWithTildeInPath) on another card (\(String(other.uuidString.prefix(8)).lowercased())). It works in the folder itself, so one card runs there at a time: Wake Now when that one's done."
            record(id, ok: false, line)
            return .notWoken(line)
        }
        let worktree = wake.worksInFolder ? repository : ClaudeCodeLaunch.worktree(repository: repository, card: id)
        let worktreeExists = !wake.worksInFolder && FileManager.default.fileExists(atPath: worktree)
        // Your comment or answer to a run that's over carries on its session (lane LS1), in the folder it ran in.
        let earlier = (reason == .commented || reason == .answered) && !again && (worktreeExists || wake.worksInFolder)
            ? lastClaudeSession(card, agent: agent) : nil
        let session = earlier ?? UUID()
        // Limited to Binders' tools, unless this Mac's Claude Code is managed in a way that refuses that.
        let onlyBinders = !again && Self.asksOnlyBinders
        // Your team's shared folder and other runs' logs are as private to it as Binders' own data.
        let launch = ClaudeCodeLaunch.make(card: id, reason: reason, boardName: agent.name, wake: wake, binders: MCPHost.executable,
                                           dataFolder: AppPaths.support.path, home: NSHomeDirectory(),
                                           alsoPrivate: [Self.logs.path] + [AppSettings.shared.teamFolderPath].compactMap { $0 },
                                           worktreeExists: worktreeExists, session: session,
                                           draftsFirst: agent.draftsFirst, strictMCP: onlyBinders, resuming: earlier != nil)
        let log = Self.logFile(for: id, suffix: "jsonl")
        let run = UUID()
        do {
            // The login shell finds claude on your PATH; the script is fixed, and everything else goes in as arguments.
            let environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, added in added }
            let process = try AutomationService.launch("/bin/zsh", ["-lc", "exec \"$@\"", "binders", wake.executable ?? "claude"] + launch.arguments,
                                                       stdin: launch.prompt, environment: environment, directory: URL(fileURLWithPath: launch.directory),
                                                       log: log, limit: Self.runLimit) { status in
                Task { @MainActor [weak self] in self?.finished(id, run: run, agent: agent, status: status, log: log) }
            }
            started(id, process, run: run)
            sessions[id] = session
            launches[id] = (onlyBinders, reason, again)
            if wake.worksInFolder { inFolderRuns[id] = repository } else { inFolderRuns[id] = nil }
            receipt(card, agent: agent, note + (earlier != nil ? "Carried on its session. " : "") + "Started Claude Code in \(worktree)\(wake.worksInFolder ? ", the folder itself" : "") (\(wake.safeMode), \(Self.describe(reason))). To look in: claude --resume \(session.uuidString.lowercased()) there.",
                    log: log)
            return .woke
        } catch {
            record(id, ok: false, "Couldn't start Claude Code: \(error.localizedDescription)")
            return .notWoken("Couldn't start Claude Code: \(error.localizedDescription)")
        }
    }

    /// The session of the card's last Claude Code run for this agent, from its wake receipt, when there was one.
    private func lastClaudeSession(_ card: TaskCard, agent: AgentProfile) -> UUID? {
        guard let receipt = board?.timeline(card.id).last(where: { $0.kind == .woke && AgentRegistry.isAgent(agent, named: $0.author) }),
              receipt.text.contains("Started Claude Code"), let session = AgentDoing.session(inReceipt: receipt.text) else { return nil }
        return UUID(uuidString: session)
    }

    private func started(_ id: UUID, _ process: Process, run: UUID) {
        runs[id] = process
        runIDs[id] = run
        working.insert(id)
    }

    /// A run ended. A command only rings the agent, which works elsewhere: how it went is noted. A Claude Code run is the
    /// agent itself: if it still holds the card unfinished, failed or stopped, the card waits in Blocked with why, rather
    /// than going back to Ready as if nothing happened, and with what it said last unless a hook already put that on the
    /// card. That's the agent's own move, so it wakes nothing.
    private func finished(_ id: UUID, run: UUID, agent: AgentProfile, status: Int32, log: URL) {
        // A newer run for the card started before this one's end came through: that one is the card's now.
        guard runIDs[id] == run else { return record(id, ok: status == 0, status == 0 ? "An earlier run finished" : "An earlier run stopped (exit \(status))") }
        runs[id] = nil
        runIDs[id] = nil
        working.remove(id)
        let stoppedByYou = stopping.remove(id) != nil
        let launched = launches.removeValue(forKey: id)
        // The run is over: what its hooks said stands, and a hook that reports after this is one too many.
        let session = sessions.removeValue(forKey: id)?.uuidString.lowercased()
        let hooksSaid = session.map { runReports[$0] != nil } ?? false
        if let session { noteReport(session) }
        // Answered, commented or sent back while the run was ending: that comes first, rather than letting the card go.
        if let (reason, tapped) = deferred.removeValue(forKey: id), let card = board?.card(id), let due = dueAtRunEnd(card, reason) {
            record(id, ok: status == 0, status == 0 ? "Finished" : "Stopped (exit \(status))")
            fire(id, reason: due, tapped: tapped)
            return
        }
        let result = Self.lastResult(in: log)
        let summary = [status == 0 ? "Finished" : "Stopped (exit \(status))", result.cost.map { String(format: "$%.2f", $0) }, result.turns.map { "\($0) turns" }]
            .compactMap { $0 }.joined(separator: ", ")
        record(id, ok: status == 0, summary)
        guard case .claudeCode(let wake) = agent.wake, let board, let card = board.card(id) else { return }
        // This Mac's Claude Code, managed by an organization: a run limited to Binders' tools that it refused starts again
        // once without that, saying why; one whose tools it kept out says so, and what to do. Never more than one start again.
        let managed = stoppedByYou ? nil : ClaudeCodeManaged.finding(in: Self.startAndEnd(of: log))
        if managed == .refusedOnlyBinders, let launched, launched.onlyBinders, !launched.again {
            AppDefaults.store.set(Date(), forKey: Self.refusedOnlyBindersKey)
            record(id, ok: false, "Claude Code wouldn't start limited to Binders' tools")
            wakeClaude(agent, wake, card: card, reason: launched.reason, before: ClaudeCodeManaged.startedAgainLine + " ", again: true)
            return
        }
        if managed != nil { board.comment(card, text: ClaudeCodeManaged.keptOutLine, by: BoardService.binders) }
        if managed == nil, status != 0, !stoppedByYou, wake.safeMode == "auto", !Self.holds(agent, card) {
            // Stopped before it took the card, in auto mode: Claude Code may not offer that mode on this sign-in or
            // version. Say so on the card rather than leave it looking untouched.
            board.comment(card, text: Self.autoModeStopped(status: status, said: Self.lastError(in: log)), by: BoardService.binders)
        }
        if card.column == .inProgress, card.assigneeIsAgent, let holder = card.assignee, AgentRegistry.isAgent(agent, named: holder) {
            // Failed, in A2A's words: Blocked with a reason, still its card, so you can look, answer to send it back to work,
            // or move it on.
            let why = stoppedByYou ? "You stopped its run before it finished."
                : status == 0 ? "Its run ended before it finished." : "Its run stopped (exit \(status)) before it finished."
            let said = hooksSaid ? "" : result.text.map { " It said: \(AgentRunReport.trimmed($0, limit: 300))" } ?? ""
            saidBlocked(card.id)
            try? board.move(card, to: .blocked, by: BoardActor(name: holder, kind: .agent), note: why + said)
            if !stoppedByYou { MacNotifications.shared.post(status: .stopped, on: card, by: agent.name, summary: why) }
        } else if status != 0, !stoppedByYou, card.assignee == nil || !card.assigneeIsAgent {
            MacNotifications.shared.post(status: .stopped, on: card, by: agent.name, summary: summary)
        }
    }

    // MARK: The session you have open

    /// Whether the agent itself holds the card now, as a run of it does once it has claimed it: only a run, as that agent,
    /// can go on with it. A session you have open works under its own name ("Claude Code"), so it can't take it over.
    private static func holds(_ agent: AgentProfile, _ card: TaskCard) -> Bool {
        card.assigneeIsAgent && BoardRules.isClaimed(card.state, at: Date()) && AgentRegistry.isAgent(agent, named: card.assignee ?? "")
    }

    /// "Post to the Claude Code session open in this repository": the card goes to a Claude Code session you have open on
    /// this Mac in the agent's repository, with Binders' tools, as one message into its inbox socket (Claude Code's own
    /// cross-session messaging, which on one Mac never goes through Anthropic), in place of a run. The message has the
    /// card's title, id and link and says Binders' board tools have it; nothing else from your binders. Never a session
    /// Binders started for a card. With none open, or only ones without Binders' tools, the run starts as before and the
    /// card says why; when the post fails, the card says why and nothing starts. That session works with its own
    /// permissions and its own Binders tools, not the run's worktree and deny list.
    @discardableResult
    private func postToOpenSession(_ agent: AgentProfile, _ wake: ClaudeCodeWake, card: TaskCard, reason: AgentWake.Reason) -> HandOff {
        let id = card.id
        let repository = (wake.repository as NSString).expandingTildeInPath
        let place = (repository as NSString).abbreviatingWithTildeInPath
        let ours = Set(sessions.values.map { $0.uuidString.lowercased() })
        let found = ClaudeSessionInbox.sessions(in: repository, excluding: ours)
        guard !found.ready.isEmpty else {
            let note = found.withoutTools.isEmpty ? "No Claude Code session was open in \(place). "
                : "The Claude Code session open in \(place) doesn't have Binders' tools to read the card: Settings → MCP adds them to Claude Code, then start that session again. "
            return wakeClaude(agent, wake, card: card, reason: reason, before: note)
        }
        let open = found.ready
        let line = ClaudeSessions.line(ClaudeSessions.message(card: id, title: card.title, agent: agent.name, reason: reason, draftsFirst: agent.draftsFirst))
        Task { [weak self] in
            for session in open {
                do {
                    try await ClaudeSessionInbox.post(line, to: session.socket)
                    self?.posted(id, agent: agent, to: session, in: place, reason: reason)
                    return
                } catch ClaudeSessionInbox.Failure.closed {
                    // It closed after its file was written: the next one, or a run.
                    continue
                } catch {
                    self?.postFailed(id, agent: agent, in: place, why: error.localizedDescription)
                    return
                }
            }
            self?.closedSince(id, reason: reason, in: place)
        }
        return .woke
    }

    private func posted(_ id: UUID, agent: AgentProfile, to session: ClaudeSession, in place: String, reason: AgentWake.Reason) {
        let named = session.name.isEmpty ? "" : " (“\(ClaudeSessions.oneLine(session.name, limit: 60))”)"
        guard let card = board?.card(id) else { return record(id, ok: true, "Posted to the Claude Code session open in \(place)") }
        // Claude Code doesn't say what it did with the message: what each setting does with it, and what to do if nothing.
        receipt(card, agent: agent, "Posted the card to the Claude Code session open in \(place)\(named) instead of starting a run (\(Self.describe(reason))). "
                + "Binders can't see whether it took it: a session that skips permission prompts asks you there first and drops it after a few minutes unanswered, "
                + "and one set to hold or refuse messages from your other sessions doesn't take it. If nothing happens, Wake Now on the card posts it again.", log: nil)
    }

    private func postFailed(_ id: UUID, agent: AgentProfile, in place: String, why: String) {
        let message = "Couldn't post the card to the Claude Code session open in \(place): \(why). Nothing was started. Wake Now on the card tries again."
        record(id, ok: false, message)
        notify?(message, "exclamationmark.triangle")
        if let board, let card = board.card(id) { board.woke(card, agent: agent.name, text: message, log: nil) }
    }

    /// Each session that seemed open had closed by the time Binders posted: the run starts as if none were, if the card
    /// still wants it and the agent may still be woken.
    private func closedSince(_ id: UUID, reason: AgentWake.Reason, in place: String) {
        guard let board, let card = board.card(id), let agent = target(for: card, reason: reason), registry.wakeable(agent),
              Self.isDue(card, for: reason), runs[id]?.isRunning != true, case .claudeCode(let wake) = agent.wake else { return }
        wakeClaude(agent, wake, card: card, reason: reason, before: "No Claude Code session was open in \(place). ")
    }

    // MARK: A Claude Code run's hooks

    /// The Stop or SessionEnd hook of a Claude Code run Binders started (`Binders --agent-hook`, through the inbox): what
    /// it said last, or that its session ended, as a line on its card by the agent. Once a run: whichever of its hooks
    /// comes first says it, and when the run ends Binders doesn't say it again. Only on a card meant for that agent or
    /// held by it, and it keeps no claim alive. True when the card has it.
    @discardableResult
    func reported(_ card: TaskCard, session: String, text: String, by actor: BoardActor) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actor.isAgent, !text.isEmpty, let board else { return false }
        func same(_ name: String?) -> Bool { name.map { $0.localizedCaseInsensitiveCompare(actor.name) == .orderedSame } ?? false }
        guard (card.assigneeIsAgent && same(card.assignee)) || (!card.meantForByAgent && same(card.meantFor)) else { return false }
        let run = session.isEmpty ? sessions[card.id]?.uuidString.lowercased() ?? "" : session.lowercased()
        if !run.isEmpty {
            guard runReports[run] == nil else { return false }
            noteReport(run)
        }
        // Already its summary, or its last report: said once is enough.
        if board.timeline(card.id).last(where: { $0.authorIsAgent && same($0.author) })?.text.trimmingCharacters(in: .whitespacesAndNewlines) == text {
            return true
        }
        board.report(card, progress: text, by: actor, renewing: false)
        return true
    }

    private func noteReport(_ session: String) {
        let now = Date()
        runReports = runReports.filter { now.timeIntervalSince($0.value) < 12 * 3_600 }
        runReports[session] = now
    }

    // MARK: Status addresses

    /// Asks the status address of each agent that reports through one about the cards Binders holds for it in progress,
    /// those not asked in the last `statusInterval`, and moves each card to match. Returns once they've all answered.
    /// While agents are paused no address is asked, and the cards wait where they are: Binders keeps their claims alive in
    /// the agents' place, so none lapses back to Ready and each is asked about again once you resume.
    func askStatuses(now: Date = Date()) async {
        guard let board else { return }
        var due: [(card: UUID, agent: AgentProfile, address: String)] = []
        for card in board.cards(in: nil) where card.column == .inProgress && card.assigneeIsAgent {
            guard let holder = card.assignee, let agent = registry.agent(named: holder), !registry.changedOutside.contains(agent.id),
                  case .status(let address) = agent.reporting else { continue }
            if registry.paused {
                // Renewed as it nears its end rather than every minute, which would tell your iPhone the board changed.
                if let end = card.claimExpiresAt, end <= now.addingTimeInterval(Self.statusInterval) {
                    board.keepAlive(card, by: BoardActor(name: holder, kind: .agent), at: now)
                }
                continue
            }
            guard !asking.contains(card.id), now.timeIntervalSince(asked[card.id] ?? .distantPast) >= Self.statusInterval else { continue }
            due.append((card.id, agent, address))
        }
        await withTaskGroup(of: Void.self) { group in
            for item in due {
                group.addTask { await self.ask(item.card, agent: item.agent, address: item.address, at: now) }
            }
        }
    }

    private func ask(_ id: UUID, agent: AgentProfile, address: String, at now: Date) async {
        asking.insert(id)
        defer { asking.remove(id) }
        asked[id] = now
        guard let request = AgentStatusReply.request(address, card: id, token: registry.statusToken(for: agent.id)) else {
            return record(id, ok: false, "\(agent.name)'s status address needs http or https.")
        }
        do {
            let (data, response) = try await fetch(request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw AutomationService.Failure.http(code) }
            guard let reply = AgentStatusReply(data) else {
                return record(id, ok: false, "\(agent.name)'s status address didn't give a state Binders knows, such as {\"state\": \"working\"}.")
            }
            apply(reply, to: id, agent: agent)
        } catch {
            record(id, ok: false, "\(agent.name)'s status address: \(error.localizedDescription)")
        }
    }

    /// Moves the card to match what its agent's status address said, as the agent: still at it (its claim is kept, and a
    /// new note is its progress), a question for you (Blocked until you answer), finished (Review, or Done where agents may
    /// finish), failed (Blocked, with why) or canceled (back to Backlog). A status the card's timeline already has from it,
    /// in the same words, changes nothing: the agent hasn't caught up with your answer or your send-back yet.
    private func apply(_ reply: AgentStatusReply, to id: UUID, agent: AgentProfile) {
        guard let board, let card = board.card(id), card.column == .inProgress, card.assigneeIsAgent,
              let holder = card.assignee, AgentRegistry.isAgent(agent, named: holder) else { return }
        let actor = BoardActor(name: holder, kind: .agent)
        let timeline = board.timeline(id).filter { $0.authorIsAgent && $0.author == holder }
        func already(_ kind: TaskEvent.Kind, _ text: String, to column: BoardColumn? = nil) -> Bool {
            timeline.contains { $0.kind == kind && $0.text == text && (column == nil || $0.toColumn == column?.rawValue) }
        }
        record(id, ok: true, "\(agent.name)'s status address: \(reply.state.rawValue)")
        do {
            switch reply.state {
            case .submitted, .working:
                if !reply.note.isEmpty, timeline.last(where: { $0.kind == .progress })?.text != reply.note {
                    board.report(card, progress: reply.note, by: actor)
                } else {
                    board.keepAlive(card, by: actor)
                }
            case .inputRequired:
                let question = reply.note.isEmpty ? "\(agent.name) needs your input to go on." : reply.note
                guard !already(.question, question) else { return board.keepAlive(card, by: actor) }
                try board.ask(card, question: question, by: actor)
            case .completed:
                let summary = reply.note.isEmpty ? "\(agent.name) says it's finished." : reply.note
                guard !already(.completed, summary) else { return board.keepAlive(card, by: actor) }
                try board.complete(card, summary: summary, by: actor)
            case .failed:
                let why = reply.note.isEmpty ? "\(agent.name) says it failed." : reply.note
                guard !already(.moved, why, to: .blocked) else { return board.keepAlive(card, by: actor) }
                try board.move(card, to: .blocked, by: actor, note: why)
            case .canceled:
                let why = reply.note.isEmpty ? "\(agent.name) stopped working on it." : reply.note
                guard !already(.moved, why, to: .backlog) else { return board.keepAlive(card, by: actor) }
                try board.move(card, to: .backlog, by: actor, note: why)
            }
        } catch {
            record(id, ok: false, error.localizedDescription)
        }
    }

    // MARK: Receipts

    private func receipt(_ card: TaskCard, agent: AgentProfile, _ text: String, log: URL?) {
        record(card.id, ok: true, "Woke \(agent.name)")
        board?.woke(card, agent: agent.name, text: text, log: log)
    }

    private func record(_ card: UUID, ok: Bool, _ message: String) {
        outcomes[card] = AutomationService.Outcome(at: Date(), ok: ok, message: message)
    }

    /// What the card's hand-off waits for, said where its last wake is (lane DS8: "Writing the brief for Echo…"); nil
    /// takes it away.
    func say(_ card: UUID, _ message: String?) {
        outcomes[card] = message.map { AutomationService.Outcome(at: Date(), ok: true, message: $0) }
    }

    /// Your words for the agent woken now (`AgentWakePayload.answer`), as `CardConversation.wakeWords` says: your newest
    /// answer or comment, as every wake has always carried; or, while comments of yours a comment's wake is for haven't
    /// reached the agent, every word of yours it hasn't had, oldest first, never a note by Binders. Read from the timeline
    /// as the wake goes, so nothing is kept in memory to lose: comments a capped or failed wake didn't take go with the next.
    func wakeAnswer(for agent: AgentProfile, on card: TaskCard) -> String {
        wakeWords(for: agent, on: card).answer
    }

    /// `wakeAnswer`, and whether it carries comments of yours the agent hasn't had (`joined`).
    private func wakeWords(for agent: AgentProfile, on card: TaskCard) -> (answer: String, joined: Bool) {
        let events = board?.timeline(card.id) ?? []
        let words = CardConversation.wakeWords(events.map(\.conversation), agent: agent.name, failureLines: Self.failureLines)
        let texts = words.words.map { events[$0].text }
        // What changed in its spec goes after your words, as one of them: only what this agent may hear of each change.
        let told = (notices[card.id] ?? []).compactMap { $0.text(readsTeam: readsTeam(agent)) }
        if !told.isEmpty {
            let yours = words.joined ? texts : events.lastIndex { CardConversation.isYours($0.conversation) }.map { [events[$0].text] } ?? []
            return (AgentWakePayload.answer(yours + told), true)
        }
        return (words.joined ? AgentWakePayload.answer(texts) : texts.last ?? "", words.joined)
    }

    /// The openings of the failure lines a wake leaves by the agent after its receipt, so the card can tell a receipt whose
    /// words didn't arrive: a web hook's, and a Shortcut's for a wake that carried your comments.
    static let failureLines = ["Its web hook didn't take the card", "Its Shortcut didn't take the card"]
    /// The opening of the line a post to your open session leaves when it fails: it has no receipt before it, so it's no
    /// receipt's failure, but it's a hand-off that didn't go.
    static let unsentLines = ["Couldn't post the card to the Claude Code session"]

    private static func describe(_ reason: AgentWake.Reason) -> String {
        switch reason {
        case .ready: "made ready for it"
        case .answered: "you answered"
        case .commented: "you commented"
        case .sentBack: "you sent it back"
        case .manual: "Wake Now"
        }
    }

    private static func logFile(for card: UUID, suffix: String = "log") -> URL {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        return logs.appendingPathComponent("\(card.uuidString.prefix(8).lowercased())-\(stamp).\(suffix)")
    }

    // MARK: Claude Code managed by an organization

    /// Where this Mac's Claude Code finds its organization's managed settings; in a throwaway folder, one under it. Binders
    /// only looks: nothing there is ever written.
    static var managedFolder: String { AgentPlaces.managedClaudeFolder }
    /// When a run here was refused for being limited to Binders' tools: for a week after, runs start without that limit,
    /// as they do where the organization's managed-mcp.json is. Then they ask for it again, in case the organization's
    /// settings changed.
    static let refusedOnlyBindersKey = "claudeCodeRefusedOnlyBinders"

    /// Whether a run asks for only Binders' tools: not where the organization's managed-mcp.json is, nor for a week after a
    /// run here was refused for it.
    static var asksOnlyBinders: Bool {
        if FileManager.default.fileExists(atPath: (managedFolder as NSString).appendingPathComponent(ClaudeCodeManaged.mcpFile)) { return false }
        if let refused = AppDefaults.store.object(forKey: refusedOnlyBindersKey) as? Date, Date().timeIntervalSince(refused) < 7 * 86_400 { return false }
        return true
    }

    /// Whether an organization manages this Mac's Claude Code: its managed MCP config or settings are here (a file, its
    /// drop-ins or a configuration profile), or a run was refused for being limited to Binders' tools.
    static var claudeCodeIsManaged: Bool {
        FileManager.default.fileExists(atPath: (managedFolder as NSString).appendingPathComponent(ClaudeCodeManaged.mcpFile))
            || !AgentPlaces.managedClaudeSettings.isEmpty || !asksOnlyBinders
    }

    /// The start and the end of a run's log: what Claude Code printed as it started (where a managed Claude Code says what
    /// it refused or left out), and how the run ended.
    nonisolated static func startAndEnd(of log: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
        defer { try? handle.close() }
        // The start event lists every tool, server and skill the run has: with an organization's many, it runs long.
        let start = (try? handle.read(upToCount: 2 * 1024 * 1024)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return start + "\n" + (CLIRuns.tail(log, bytes: 64 * 1024) ?? "")
    }

    /// What a Claude run said last (its result line in stream-json), what it cost and how many turns it took.
    static func lastResult(in log: URL) -> (text: String?, cost: Double?, turns: Int?) {
        guard let tail = CLIRuns.tail(log, bytes: 256 * 1024) else { return (nil, nil, nil) }
        for line in tail.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["type"] as? String == "result" else { continue }
            return (object["result"] as? String, object["total_cost_usd"] as? Double, object["num_turns"] as? Int)
        }
        return (nil, nil, nil)
    }

    /// Whether a Claude run's last result is an error (`is_error`), such as an API error it printed as its result.
    static func resultIsError(in log: URL) -> Bool {
        guard let tail = CLIRuns.tail(log, bytes: 256 * 1024) else { return false }
        for line in tail.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], object["type"] as? String == "result" else { continue }
            return object["is_error"] as? Bool == true
        }
        return false
    }

    /// What the card says when a run in auto mode stopped before it took the card.
    static func autoModeStopped(status: Int32, said: String?) -> String {
        let quoted = said.map { " It said: \(AgentRunReport.trimmed($0, limit: 200))" } ?? ""
        return "Claude Code stopped (exit \(status)) before it took the card, in auto mode.\(quoted) If your Claude Code doesn't "
            + "offer auto mode, update it, or choose another mode under Permissions in Settings → Agents."
    }

    /// The last line of a run's log that isn't one of Claude Code's JSON events: what it printed when it refused to start.
    static func lastError(in log: URL) -> String? {
        guard let tail = CLIRuns.tail(log, bytes: 64 * 1024) else { return nil }
        return tail.split(separator: "\n").reversed()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("{") }
    }

    /// Logs older than two weeks go, with the rest of the six-hourly tidying. Never a folder, and never a CLI run's record,
    /// which carries a run's end across a quit.
    static func pruneLogs(olderThanDays days: Int = 14) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: Array(keys))) ?? []
        for file in files {
            let values = try? file.resourceValues(forKeys: keys)
            guard values?.isDirectory != true, !file.lastPathComponent.hasSuffix(".run.json"), !file.lastPathComponent.hasSuffix(".ending.json"),
                  (values?.contentModificationDate ?? .distantFuture) < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}

// MARK: - The command-line coding tools

/// What a CLI run needs before it starts: its program and the version it says, its worktree, and what's in it.
private struct CLIReady: Sendable {
    var program: CLIProgram.Found
    var version: String
    var worktree: AgentWorktreeRecord
    var agentsFile: Bool
}

extension AgentDispatcher {
    /// Codex, OpenCode, GitHub Copilot CLI or Antigravity, started on its own for the card in a git worktree Binders makes
    /// for the card and tool, with Binders' board tools for that card only and the tool's own checks on. The card's id is
    /// all it's given. First, off the main thread: its program and version, Codex's settings from an administrator,
    /// Copilot's settings folder, Antigravity's settings and its worktree's .agents folder, the worktree and the run's temp
    /// folder. Any of those that fails says why on the card and starts
    /// nothing. The run outlives Binders if it must: its record beside its log carries its end across a quit.
    fileprivate func wakeCLI(_ agent: AgentProfile, _ wake: CLIAgentWake, card: TaskCard, reason: AgentWake.Reason) {
        let id = card.id
        var wake = wake
        // Paths as written in agents-cli.json may start with "~".
        wake.repository = (wake.repository as NSString).expandingTildeInPath
        wake.executable = wake.executable.map { ($0 as NSString).expandingTildeInPath }
        starting.insert(id)
        working.insert(id)
        stopping.remove(id)
        let stem = CLIRuns.newStem(for: id)
        let temporary = CLIRuns.temporary(stem)
        let team = AppSettings.shared.teamFolderPath
        Task { [weak self] in
            let prepared = await Self.prepareCLI(wake, card: id, temporary: temporary, team: team)
            self?.startCLI(agent, wake, card: id, reason: reason, stem: stem, temporary: temporary, team: team, prepared: prepared)
        }
    }

    /// Everything a CLI run needs before it starts, in order, stopping at the first that fails.
    nonisolated private static func prepareCLI(_ wake: CLIAgentWake, card: UUID, temporary: URL, team: String?) async -> Result<CLIReady, AgentWorktrees.Failure> {
        let tool = wake.tool
        let program: CLIProgram.Found
        switch await CLIProgram.find(tool, executable: wake.executable) {
        case .success(let found): program = found
        case .failure(let failure): return .failure(failure)
        }
        guard let version = await CLIProgram.version(tool, at: program) else {
            return .failure(AgentWorktrees.Failure("Couldn't start \(tool.name): \(AgentWorktrees.display(program.path)) didn't answer its version as \(tool.name) does, so it may not be \(tool.name)."))
        }
        if let problem = CLIProgram.versionProblem(tool, version: version) { return .failure(AgentWorktrees.Failure(problem)) }
        if tool == .codex {
            let managed = CLIProgram.managedCodex()
            if let problem = CodexManaged.problem(existing: managed.existing, forced: managed.forced) { return .failure(AgentWorktrees.Failure(problem)) }
        }
        if tool == .copilot, let problem = CLIProgram.prepareCopilotHome() { return .failure(AgentWorktrees.Failure(problem)) }
        // Your Antigravity settings, which Binders can't set for a run: checked before any worktree is made for it.
        if tool == .antigravity {
            let path = AgentWorktree.path(root: AgentPlaces.root.path, repository: AgentPlaces.real(wake.repository), card: card, tool: tool)
            if let problem = AntigravityFiles.settingsProblem(worktree: path, team: team) { return .failure(AgentWorktrees.Failure(problem)) }
        }
        // The run's own temp folder, for git too.
        AgentPlaces.ensure(temporary)
        if tool == .codex { AgentPlaces.ensure(temporary.appendingPathComponent("zsh", isDirectory: true)) }
        switch await AgentWorktrees.prepare(repository: wake.repository, card: card, tool: tool, path: program.searchPath, temporary: temporary.path) {
        case .success(let worktree):
            // OpenCode checks a path by its text, then follows any link in it: a link in the worktree to somewhere outside
            // it would take its file tools there, past the only check it has.
            if tool == .opencode, let link = AgentWorktrees.outwardLink(in: worktree.path) {
                try? FileManager.default.removeItem(at: temporary)
                return .failure(AgentWorktrees.Failure(AgentWorktree.outwardLinkProblem(link, tool: tool)))
            }
            // Antigravity loads hooks, servers and plugins from the worktree's .agents folder, outside its sandbox.
            if tool == .antigravity, let problem = AntigravityFiles.workspaceProblem(worktree: worktree.path) {
                try? FileManager.default.removeItem(at: temporary)
                return .failure(AgentWorktrees.Failure(problem))
            }
            let agentsFile = tool == .opencode && FileManager.default.fileExists(atPath: (worktree.path as NSString).appendingPathComponent("AGENTS.md"))
            return .success(CLIReady(program: program, version: version, worktree: worktree, agentsFile: agentsFile))
        case .failure(let failure):
            try? FileManager.default.removeItem(at: temporary)
            return .failure(failure)
        }
    }

    /// What a run is given, from the card, the agent, its worktree (and the repository's top folder, as its record has it)
    /// and its stem. The self-test builds the same.
    nonisolated static func cliRun(card: UUID, run: UUID, session: UUID, reason: AgentWake.Reason, agent: AgentProfile, wake: CLIAgentWake,
                                   worktree: String, repository: String?, stem: String, path: String, agentsFile: Bool, team: String?,
                                   conversation: String? = nil) -> CLIAgentRun {
        CLIAgentRun(card: card, run: run, reason: reason, boardName: agent.name, wake: wake, binders: MCPHost.executable, worktree: worktree,
                    temporary: CLIRuns.temporary(stem).path, places: AgentPlaces.root.path, bindersTemp: AgentPlaces.real(NSTemporaryDirectory()),
                    dataFolder: AppPaths.support.path, home: NSHomeDirectory(), alsoPrivate: [AgentPlaces.logs.path] + [team].compactMap { $0 },
                    runStem: stem, session: session, draftsFirst: agent.draftsFirst, path: path, base: ProcessInfo.processInfo.environment,
                    throwawayData: AppPaths.isDemo ? AppPaths.support.path : nil, copilotHome: AgentPlaces.copilotHome.path, agentsFile: agentsFile,
                    repository: repository, conversation: conversation)
    }

    /// Back on the main actor: starts the run, writes its record and posts its receipt; or says why it didn't start.
    private func startCLI(_ agent: AgentProfile, _ wake: CLIAgentWake, card id: UUID, reason: AgentWake.Reason, stem: String, temporary: URL,
                          team: String?, prepared: Result<CLIReady, AgentWorktrees.Failure>) {
        starting.remove(id)
        let ready: CLIReady
        switch prepared {
        case .success(let value): ready = value
        case .failure(let failure): return cliFailed(id, failure.message, temporary: temporary)
        }
        guard let board, let card = board.card(id) else { return cliFailed(id, "The card is gone. Nothing was started.", temporary: temporary) }
        if stopping.remove(id) != nil {
            try? FileManager.default.removeItem(at: temporary)
            working.remove(id)
            return record(id, ok: true, "Stopped before it started")
        }
        let runID = UUID()
        let inputs = Self.cliRun(card: id, run: runID, session: UUID(), reason: reason, agent: agent, wake: wake, worktree: ready.worktree.path,
                                 repository: ready.worktree.repository, stem: stem, path: ready.program.searchPath, agentsFile: ready.agentsFile, team: team,
                                 conversation: wake.tool == .antigravity ? AntigravityFiles.conversation(for: id) : nil)
        let launch: CLIAgentLaunch
        do {
            launch = try CLIAgentLaunches.make(inputs)
        } catch {
            return cliFailed(id, "Couldn't start \(wake.tool.name): \((error as? CLIAgentLaunches.Refusal)?.message ?? error.localizedDescription) Nothing was started.",
                             temporary: temporary)
        }
        let log = CLIRuns.log(stem), errors = CLIRuns.errors(stem)
        let process: Process
        do {
            try FileManager.default.createDirectory(at: Self.logs, withIntermediateDirectories: true)
            for (path, contents) in launch.files {
                // Antigravity's server for the run goes in the worktree's .agents folder, which may not be there yet.
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try AgentPlaces.write(Data(contents.utf8), to: url)
            }
            // Started directly, not through a shell, so no profile touches its environment.
            process = try AutomationService.launch(ready.program.path, launch.arguments, stdin: launch.stdin, environment: launch.environment,
                                                   directory: URL(fileURLWithPath: launch.directory), log: log, errors: errors, limit: Self.runLimit,
                                                   interruptFirst: true) { status in
                Task { @MainActor [weak self] in self?.cliExited(id, run: runID, status: status) }
            }
        } catch {
            if wake.tool == .antigravity { AntigravityFiles.takeOut(worktree: ready.worktree.path) }
            return cliFailed(id, "Couldn't start \(wake.tool.name): \(error.localizedDescription)", temporary: temporary)
        }
        let pid = process.processIdentifier
        let runRecord = CLIRunRecord(card: id, run: runID, agent: agent.id, agentName: agent.name, tool: wake.tool, mode: launch.mode,
                                     worktree: ready.worktree.path, stem: stem, session: launch.session, pid: pid,
                                     processStart: CLIRuns.startTime(of: pid) ?? Date().timeIntervalSince1970, startedAt: Date(),
                                     worktreeRecord: ready.worktree)
        CLIRuns.write(runRecord)
        cliRuns[id] = runRecord
        started(id, process, run: runID)
        receipt(card, agent: agent, Self.startReceipt(wake, worktree: ready.worktree, mode: launch.mode, version: ready.version, reason: reason,
                                                      lookIn: launch.lookIn), log: log)
    }

    /// A CLI run that couldn't start: the card says why, by Binders, and nothing more happens.
    private func cliFailed(_ id: UUID, _ message: String, temporary: URL) {
        try? FileManager.default.removeItem(at: temporary)
        starting.remove(id)
        stopping.remove(id)
        working.remove(id)
        record(id, ok: false, message)
        notify?(message, "exclamationmark.circle")
        if let board, let card = board.card(id) { board.note(card, text: message) }
    }

    /// The start's receipt: what was started, where, in which mode, why, and what happens when it stops. It starts with
    /// "Started <tool> in ", which is how the card's line knows the run.
    private static func startReceipt(_ wake: CLIAgentWake, worktree: AgentWorktreeRecord, mode: String, version: String, reason: AgentWake.Reason,
                                     lookIn: String?) -> String {
        let tool = wake.tool
        var parts = [tool == .opencode ? [mode, wake.launchModel].compactMap { $0 }.joined(separator: ", ") : mode]
        if let note = tool.versionNote(version) { parts.append(note) }
        parts.append(describe(reason))
        let start = "Started \(tool.name) in \(AgentWorktrees.display(worktree.path)) (\(parts.joined(separator: "; ")))."
        switch tool {
        case .codex:
            return start + " When it stops, Binders commits its changes on \(worktree.branch) and adds the command that resumes its session."
        case .opencode:
            return start + " Your own OpenCode MCP servers start with it, but it can't use their tools. When it stops, Binders commits its changes on \(worktree.branch) and adds the command that resumes its session."
        case .copilot:
            return start + " When it stops, Binders commits its changes on \(worktree.branch). To look in, with your own answers to Copilot's prompts rather than the run's limits (Binders sets its run settings back before the next run): \(lookIn ?? "")"
        case .antigravity:
            return start + " Your own Antigravity hooks, plugins and MCP servers load with it, but it can use only Binders' tools for this card. When it stops, Binders commits its changes on \(worktree.branch) and adds the command that carries on its conversation."
        }
    }

    /// A CLI run's process ended: its end steps, once.
    private func cliExited(_ id: UUID, run: UUID, status: Int32) {
        guard runIDs[id] == run, let runRecord = cliRuns[id], runRecord.run == run else {
            return record(id, ok: status == 0, status == 0 ? "An earlier run finished" : "An earlier run stopped (exit \(status))")
        }
        runs[id] = nil
        runIDs[id] = nil
        guard CLIRuns.claimEnd(runRecord) else {
            // Another path ended it already.
            cliRuns[id] = nil
            working.remove(id)
            return
        }
        finishCLI(runRecord, status: status)
    }

    /// When a CLI run ends, in this order: read its output; put its last words on the card (now, or in the Blocked note);
    /// record how it went; commit what it changed; and only then decide. A wake that came while it ran or while Binders
    /// committed goes first: the card goes back to work. Otherwise a card it still holds unfinished waits in Blocked with
    /// why, one it never took says why it didn't, and the end line says what was committed and how to look in. `status`
    /// is nil for a run that ended while Binders was closed, or that a Binders before this one started.
    private func finishCLI(_ runRecord: CLIRunRecord, status: Int32?) {
        let id = runRecord.card
        cliRuns[id] = runRecord
        finishing.insert(id)
        working.insert(id)
        let stoppedByYou = stopping.remove(id) != nil
        let wasLimited = limited.remove(id) != nil || (status != nil && Date().timeIntervalSince(runRecord.startedAt) >= Self.runLimit - 5)
        let wake: CLIAgentWake? = registry.agents.first { $0.id == runRecord.agent }.flatMap { agent in
            if case .cliAgent(let wake) = agent.wake { return wake } else { return nil }
        }
        let tool = runRecord.tool
        Task { [weak self] in
            // Read: the whole log, a line at a time, off the main thread.
            let (out, said, errors) = await Task.detached(priority: .utility) { CLIRuns.read(runRecord) }.value
            guard let self else { return }
            let actor = BoardActor(name: runRecord.agentName, kind: .agent)
            func holdsIt(_ card: TaskCard?) -> Bool {
                guard let card, card.column == .inProgress, card.assigneeIsAgent, let holder = card.assignee else { return false }
                return BoardRules.isNamed(holder, as: runRecord.agentName) && BoardRules.isNamed(runRecord.agentName, as: holder)
            }
            // Last words: now, unless the card is still in progress and held by it, when they may go in the Blocked note.
            let key = (out.session ?? runRecord.session ?? runRecord.run.uuidString).lowercased()
            let words = out.lastText.map { AgentRunReport.trimmed($0) }
            var wordsSaid = false
            if let words, let card = self.board?.card(id), !holdsIt(card) {
                wordsSaid = self.reported(card, session: key, text: words, by: actor)
            }
            // How it went.
            // Copilot and Antigravity say how the turn ended: without that, it didn't end normally.
            let finished = status == 0 && (tool != .copilot && tool != .antigravity || out.completed)
            let head = status.map { finished ? "Finished" : $0 == 0 ? "Stopped before its result" : "Stopped (exit \($0))" } ?? "Ended while Binders was closed"
            let summary = ([head, out.cost.map { String(format: "$%.2f", $0) }, tool == .opencode ? out.turns.map { "\($0) turns" } : nil,
                            out.premiumRequests.map(CLIAgentOutput.premiumRequests)]
                .compactMap { $0 }).joined(separator: ", ")
            self.record(id, ok: finished, summary)
            if tool == .antigravity {
                AntigravityFiles.remember(out.session, for: id)
                // What it wasn't allowed to do, with no one there to approve it, from its stderr and its result.
                let refused = out.denied + AntigravityDenials.inErrors(errors).map(\.text).filter { !out.denied.contains($0) }
                if let line = AntigravityDenials.line(refused), let card = self.board?.card(id) { self.board?.note(card, text: line) }
            }
            // Commit what it changed, before anything is decided.
            self.beforeCommit?(id)
            let recorded = AgentWorktrees.records().first { $0.path == runRecord.worktree && $0.card == id && $0.tool == tool }
            // The run carries its worktree's record, so the commit never depends on worktrees.json alone; one lost from there
            // is put back, so the next wake finds the worktree as Binders made it.
            let carried = runRecord.worktreeRecord.flatMap { $0.path == runRecord.worktree && $0.card == id && $0.tool == tool ? $0 : nil }
            if recorded == nil, let carried { AgentWorktrees.restore(carried) }
            let worktree = recorded ?? carried
            let path = AppPaths.isDemo ? "" : await CLIProgram.loginPath() ?? ""
            let committed: AgentWorktrees.Committed
            if let worktree {
                // Antigravity's server for the run comes out first; something there it would run outside its sandbox stays
                // uncommitted.
                let refused = tool == .antigravity ? AntigravityFiles.commitProblem(worktree: worktree.path) : nil
                if let refused {
                    committed = .refused(refused)
                } else {
                    committed = await Task.detached(priority: .utility) {
                        await AgentWorktrees.commit(worktree, agentName: runRecord.agentName, path: path, temporary: nil)
                    }.value
                }
            } else {
                committed = .nothing
            }
            try? FileManager.default.removeItem(at: CLIRuns.temporary(runRecord.stem))
            // Decide, now that the commit is done: an answer, a comment or a Wake Now that came meanwhile goes first.
            var next: (reason: AgentWake.Reason, tapped: Bool)?
            if let (reason, tapped) = self.deferred.removeValue(forKey: id), let card = self.board?.card(id), let due = self.dueAtRunEnd(card, reason) {
                next = (due, tapped)
            }
            // An answer gathered for its two seconds hasn't fired yet: it starts the next run once this one is done.
            let gathering = self.pending[id] != nil && self.pendingReasons[id].map { reason in self.board?.card(id).map { Self.isDue($0, for: reason) } ?? false } == true
            if let board = self.board, let card = board.card(id) {
                if next != nil || gathering {
                    if let words, !wordsSaid { self.reported(card, session: key, text: words, by: actor) }
                } else if holdsIt(card) {
                    let why: String
                    if stoppedByYou {
                        why = "You stopped its run before it finished."
                    } else if wasLimited {
                        why = "It ran for 2 hours, the most a run may, and was stopped."
                    } else if status == nil {
                        why = "Its run ended while Binders was closed, before it finished."
                    } else if status == 0 {
                        // It said why, when it did: an approval no one can give, its steps used up, a policy.
                        why = "Its run ended before it finished" + (out.failure.map { ": " + Self.sentence($0) } ?? ".")
                    } else {
                        why = "Its run stopped (exit \(status ?? 0)) before it finished" + (out.failure.map { ": " + Self.sentence($0) } ?? ".")
                    }
                    let saidLine = wordsSaid ? "" : words.map { " It said: \(AgentRunReport.trimmed($0, limit: 300))" } ?? ""
                    self.saidBlocked(card.id)
                    try? board.move(card, to: .blocked, by: actor, note: why + saidLine)
                    if !stoppedByYou { MacNotifications.shared.post(status: .stopped, on: card, by: runRecord.agentName, summary: why) }
                } else if !stoppedByYou, card.column == .ready || card.column == .backlog,
                          let why = Self.notTaken(tool, status: status, out: out, said: said, errors: errors, model: wake?.launchModel) {
                    // Stopped before it took the card: the card says why, rather than look untouched.
                    board.note(card, text: why)
                    MacNotifications.shared.post(status: .stopped, on: card, by: runRecord.agentName, summary: why)
                }
                board.note(card, text: Self.endLine(runRecord, committed: committed, out: out))
            }
            self.cliRuns[id] = nil
            self.finishing.remove(id)
            self.adopted.removeValue(forKey: id)?.cancel()
            self.working.remove(id)
            CLIRuns.endDone(runRecord)
            if let next { self.fire(id, reason: next.reason, tapped: next.tapped) }
        }
    }

    /// Why a run stopped before it took the card, for the card, or nil when nothing says it didn't work. `errors` is the
    /// end of its stderr, where Copilot says over several lines that it isn't signed in.
    private static func notTaken(_ tool: CLIAgent, status: Int32?, out: CLIAgentResult, said: String?, errors: String, model: String?) -> String? {
        // Antigravity's own way of saying why: its error: line, or its AGY_ERROR line's message.
        let said = tool == .antigravity ? AntigravityOutput.reason(inErrors: errors) ?? said : said
        let reason = out.failure ?? said
        let words = [out.failure, said] + (tool == .copilot || tool == .antigravity ? [errors] : [])
        if let signIn = CLIAgentOutput.signIn(tool, said: words.compactMap { $0 }.joined(separator: "\n"), model: model) { return signIn }
        if tool == .codex, status == 2 {
            return "Codex didn't take Binders' options (exit 2)" + (said.map { ": " + sentence($0) } ?? ".")
                + " Binders starts it with options checked against Codex \(tool.checkedVersion)."
        }
        if let status, status != 0 { return "\(tool.name) stopped (exit \(status)) before it took the card" + (reason.map { ": " + sentence($0) } ?? ".") }
        // It ended normally, but said why it stopped: an approval no one can give, its steps used up, an organization's policy.
        if let failure = out.failure { return "\(tool.name) stopped before it took the card: \(sentence(failure))" }
        guard !out.usedBoard else { return nil }
        // Binders' server is required for Codex, which fails the run (exit 1) when it doesn't start: it was there, unused.
        if tool == .codex { return "Codex ended its run without taking the card or using Binders' board tools. Wake Now on the card starts it again." }
        return "\(tool.name) ran without Binders' board tools: its MCP server didn't start."
    }

    /// The end line: what Binders committed, and how to look in with your own settings, when the run's id is in its shape.
    private static func endLine(_ runRecord: CLIRunRecord, committed: AgentWorktrees.Committed, out: CLIAgentResult) -> String {
        let tool = runRecord.tool
        var line: String
        switch committed {
        case .committed(let sha, let files):
            line = "Committed \(tool.name)'s changes on \(AgentWorktree.branch(card: runRecord.card, tool: tool)): \(sha), \(files == 1 ? "1 file" : "\(files) files")."
        case .nothing:
            line = "\(tool.name) changed no files."
        case .refused(let why):
            line = why
        }
        let home = NSHomeDirectory()
        switch tool {
        case .codex:
            if let look = CodexLaunch.lookIn(thread: out.session, worktree: runRecord.worktree, home: home) {
                line += " To look in, with your own Codex settings: \(look)"
            }
        case .opencode:
            if let look = OpenCodeLaunch.lookIn(session: out.session, worktree: runRecord.worktree, home: home) {
                line += " To look in, with your own OpenCode settings, whose build agent runs commands without asking: \(look)"
            }
        case .copilot:
            break
        case .antigravity:
            if let look = AntigravityLaunch.lookIn(conversation: out.session, worktree: runRecord.worktree, home: home) {
                line += " To look in, with your own Antigravity settings: \(look)"
            }
        }
        return line
    }

    /// Words ending in a full stop, once.
    private static func sentence(_ text: String) -> String {
        let text = AgentRunReport.trimmed(text, limit: 200)
        return text.hasSuffix(".") || text.hasSuffix("…") ? text : text + "."
    }

    // MARK: Runs a Binders before this one started

    /// The CLI runs whose records are beside their logs: an end that was interrupted is done again (quietly: the commit
    /// finds nothing new, and the last words aren't said twice); a run still going is adopted; one that ended while Binders
    /// was closed is ended now. Temp folders no record names go.
    private func resumeCLIRuns() {
        let saved = CLIRuns.saved()
        // Every record's run, read or not, still has its temp folder in use.
        let named = saved.stems
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        for folder in (try? FileManager.default.contentsOfDirectory(at: AgentPlaces.temporary, includingPropertiesForKeys: Array(keys))) ?? []
        where !named.contains(folder.lastPathComponent)
            && ((try? folder.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantFuture) < Date().addingTimeInterval(-600) {
            try? FileManager.default.removeItem(at: folder)
        }
        for saved in saved.ending where cliRuns[saved.card] == nil && !starting.contains(saved.card) {
            finishCLI(saved, status: nil)
        }
        for saved in saved.running where cliRuns[saved.card] == nil && !starting.contains(saved.card) {
            if CLIRuns.isAlive(saved) {
                adopt(saved)
            } else if CLIRuns.claimEnd(saved) {
                finishCLI(saved, status: nil)
            }
        }
    }

    /// Watches a run a Binders before this one started until its process exits, with its two-hour limit kept from when
    /// it started. Wakes for its card wait meanwhile.
    private func adopt(_ saved: CLIRunRecord) {
        let id = saved.card
        cliRuns[id] = saved
        working.insert(id)
        let source = DispatchSource.makeProcessSource(identifier: saved.pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.adoptedExited(saved) } }
        adopted[id] = source
        source.resume()
        // One that exited just before its source was made never fires it.
        if !CLIRuns.isAlive(saved) { return adoptedExited(saved) }
        let left = saved.startedAt.addingTimeInterval(Self.runLimit).timeIntervalSinceNow
        guard left > 0 else {
            limited.insert(id)
            return CLIRuns.interrupt(saved)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.adopted[id] != nil, self.cliRuns[id]?.run == saved.run else { return }
                self.limited.insert(id)
                CLIRuns.interrupt(saved)
            }
        }
    }

    private func adoptedExited(_ saved: CLIRunRecord) {
        let id = saved.card
        guard let source = adopted.removeValue(forKey: id) else { return }
        source.cancel()
        guard CLIRuns.claimEnd(saved) else {
            cliRuns[id] = nil
            working.remove(id)
            return
        }
        finishCLI(saved, status: nil)
    }

    /// For the self-tests: forgets the CLI runs this dispatcher started without stopping them, as a quit would, so another
    /// dispatcher can take them up from their records.
    func abandonCLIRuns() {
        for id in cliRuns.keys {
            runs[id] = nil
            runIDs[id] = nil
            working.remove(id)
        }
        cliRuns = [:]
    }
}

// MARK: - What your words on a card would do

/// What your words on a card would do, before you send them: worked out by the dispatcher with its own rules (`target`,
/// `wakeable`, a run going, the hourly cap), so the composer never says one thing while the dispatcher does another.
enum CommentReach: Equatable {
    /// Why a card meant for an agent Binders wakes isn't that agent's to hold now, where Wake Now would still reach it.
    enum NotHeld: Equatable {
        /// Handed over, and the agent hasn't taken it.
        case notTaken
        /// The agent took it and went quiet: back in Ready, or its claim has run out.
        case wentQuiet
        /// The hand-off didn't go, and why when Binders knows.
        case didntGo(String?)
        /// You hold it yourself.
        case youHoldIt
    }

    /// Wakes left in the hour, of the agent's most.
    struct Left: Equatable {
        let left: Int
        let cap: Int
    }

    /// Binders wakes `agent`: `.commented` (In progress), `.answered` (Blocked, back to work) or `.ready` (Blocked, nobody
    /// held it: back to Ready, handed over). `left`: its wakes left this hour, when two or fewer.
    case wakes(agent: String, reason: AgentWake.Reason, left: Left?)
    /// A comment alone doesn't reach the agent the card is meant for, but Wake Now would: the composer offers Send to.
    case sendsWithWakeNow(agent: String, NotHeld)
    /// It wakes once the run going for the card ends.
    case afterRun(String, AgentWake.Reason)
    /// In Ready, a run Binders started for it is starting and hasn't taken the card yet.
    case startingRun(String)
    /// It was woken this many times in the last hour, its most.
    case atCap(String, Int)
    case paused
    case changedOutside(String)
    case held(String, why: String)
    case checksBoard(String)
    case notThisBoard(String)
    case turnedOff(String)
    /// An agent's finished work in Review: a comment stays on the card, and Send Back sends it back (waking it or not).
    case finished(String, sendBackWakes: Bool)
    /// Done, by an agent (its name) or not.
    case done(String?)
    /// Meant for an agent, not given to it yet: Give to does that.
    case notGiven(String)
    /// Held by a name that isn't one of your agents in Settings → Agents (an MCP tool, your own session).
    case notOneOfYours(String)
    /// Held by one of your agents, not the one it's meant for.
    case heldByOther(holder: String, meant: String)
    /// Held by one of your agents you didn't give it to.
    case notGivenToHolder(String)
    /// Nobody, you or a person, and no agent meant.
    case nobody

    /// The agent your words are for, now or with Send to.
    var agent: String? {
        switch self {
        case .wakes(let agent, _, _), .sendsWithWakeNow(let agent, _): agent
        case .afterRun(let agent, _), .startingRun(let agent), .atCap(let agent, _), .changedOutside(let agent), .held(let agent, _),
             .checksBoard(let agent), .notThisBoard(let agent), .turnedOff(let agent), .finished(let agent, _), .notGiven(let agent):
            agent
        case .done(let agent): agent
        case .notOneOfYours, .heldByOther, .notGivenToHolder, .paused, .nobody: nil
        }
    }

    /// Why words like these didn't go to the agent, for the line under them on the card; nil where none is said.
    var unsentLine: String? {
        func short(_ name: String) -> String { name.components(separatedBy: " · ").first ?? name }
        switch self {
        case .sendsWithWakeNow(_, .youHoldIt): return "Not sent: you have the card."
        case .sendsWithWakeNow(let agent, .notTaken): return "Not sent: \(short(agent)) hasn't taken the card."
        case .sendsWithWakeNow(let agent, .wentQuiet): return "Not sent: \(short(agent)) went quiet."
        case .sendsWithWakeNow(let agent, .didntGo): return "Not sent: \(short(agent)) doesn't have the card."
        case .atCap(let agent, let cap): return "Not sent: \(short(agent)) was woken \(cap) times in the last hour. Wake Now sends it."
        case .paused: return "Not sent: agents are paused."
        case .changedOutside(let agent): return "Not sent: \(short(agent)) was changed outside Binders."
        case .held(let agent, _): return "Not sent: Binders holds \(short(agent)) back."
        case .turnedOff(let agent): return "Not sent: \(short(agent)) is turned off."
        case .notThisBoard(let agent): return "Not sent: \(short(agent)) doesn't take this board's cards."
        case .startingRun(let agent): return "Not sent: \(short(agent)) hadn't taken the card yet."
        default: return nil
        }
    }
}

extension AgentDispatcher {
    /// What your words on `card` would do now (`events`, its timeline oldest first): its state after them goes through
    /// `BoardRules.answered`, as `BoardService.comment` takes it, and then through `fire`'s checks in `fire`'s order. Where
    /// they wake no one, why, from the card.
    func commentReach(for card: TaskCard, events: [TaskEvent], now: Date = Date()) -> CommentReach {
        switch card.column {
        case .done:
            return .done(card.assigneeIsAgent ? card.assignee : nil)
        case .review:
            guard card.assigneeIsAgent, let holder = card.assignee else { return .nobody }
            return .finished(holder, sendBackWakes: target(for: card, reason: .sentBack).map(registry.wakeable) ?? false)
        default:
            break
        }
        // In Blocked your words are its answer, and the card goes back to work.
        let after = BoardRules.answered(card.state, by: .you, at: now)
        let answering = card.column == .blocked && after.column != .blocked
        if let reason = AgentWake.reason(kind: answering ? "answer" : "comment", from: answering ? .blocked : nil, to: answering ? after.column : nil,
                                         column: after.column, byPerson: true),
           let agent = target(for: card, reason: reason) {
            if let why = notWakeable(agent) { return why }
            if isBusy(on: card.id) { return .afterRun(agent.name, reason) }
            let left = wakesLeft(agent, now: now)
            guard left > 0 else { return .atCap(agent.name, Self.cap(agent)) }
            return .wakes(agent: agent.name, reason: reason, left: left <= 2 ? .init(left: left, cap: Self.cap(agent)) : nil)
        }
        let holder = BoardRules.isClaimed(card.state, at: now) ? card.assignee : nil
        let meant = card.meantForByAgent ? nil : card.meantFor
        // Held by an agent that isn't the one you meant it for, or isn't one of yours.
        if let holder, card.assigneeIsAgent {
            guard let held = registry.agents.first(where: { AgentRegistry.isAgent($0, named: holder) }) else { return .notOneOfYours(holder) }
            if !held.isEnabled { return .turnedOff(held.name) }
            guard let meant else { return .notGivenToHolder(holder) }
            guard AgentRegistry.isAgent(held, named: meant) else { return .heldByOther(holder: holder, meant: meant) }
            return held.takesCards(from: card.binderID) ? (notWakeable(held) ?? .nobody) : .notThisBoard(held.name)
        }
        guard let meant else {
            // An agent's suggestion waits for your Give to.
            if let suggested = card.meantFor, card.column == .backlog || card.column == .ready { return .notGiven(suggested) }
            return .nobody
        }
        guard let agent = registry.agents.first(where: { AgentRegistry.isAgent($0, named: meant) }) else { return .nobody }
        if !agent.isEnabled { return .turnedOff(agent.name) }
        if card.column == .backlog { return .notGiven(agent.name) }
        if !agent.takesCards(from: card.binderID) { return .notThisBoard(agent.name) }
        if let why = notWakeable(agent) { return why }
        if let holder, holder != BoardActor.you.name { return .nobody }
        if card.column == .ready, isBusy(on: card.id) { return .startingRun(agent.name) }
        // Wake Now would reach it, past nothing but the hourly cap, which the composer leaves to the header's Wake Now.
        guard wakesLeft(agent, now: now) > 0 else { return .atCap(agent.name, Self.cap(agent)) }
        if holder != nil { return .sendsWithWakeNow(agent: agent.name, .youHoldIt) }
        return .sendsWithWakeNow(agent: agent.name, notHeld(card, agent: agent, events: events))
    }

    /// Why a card meant for `agent` that it doesn't hold isn't with it: it went quiet, the hand-off didn't go (and why), or
    /// it was handed over and not taken.
    private func notHeld(_ card: TaskCard, agent: AgentProfile, events: [TaskEvent]) -> CommentReach.NotHeld {
        if card.column == .inProgress, card.assigneeIsAgent, AgentRegistry.isAgent(agent, named: card.assignee ?? "") { return .wentQuiet }
        let wakes = events.filter { $0.kind == .woke && AgentRegistry.isAgent(agent, named: $0.author) }
        let receipt = wakes.last { !Self.isFailureLine($0.text) }
        let failure = wakes.last { Self.isFailureLine($0.text) }
        if let lapse = events.last(where: { $0.kind == .lapsed && AgentRegistry.isAgent(agent, named: $0.author) }),
           lapse.createdAt >= (receipt?.createdAt ?? .distantPast) { return .wentQuiet }
        // The last wake's outcome, when it was a hand-off: a comment of yours not sent (an iPhone that didn't ask first, the
        // hourly cap) isn't one, and the agent had the card then.
        if let outcome = outcomes[card.id], !outcome.ok, refusals[card.id] != outcome.at { return .didntGo(Self.reason(outcome.message)) }
        if let failure, failure.createdAt >= (receipt?.createdAt ?? .distantPast) { return .didntGo(Self.reason(failure.text)) }
        return receipt == nil ? .didntGo(nil) : .notTaken
    }

    /// Why a wake didn't go, in a few words: a failure line or a last wake's outcome, without what it says to do next.
    private static func reason(_ message: String) -> String {
        var why = message
        for opening in ["Not woken: ", "Its web hook didn't take the card: ", "Its Shortcut didn't take the card: ", "Not run: "] where why.hasPrefix(opening) {
            why.removeFirst(opening.count)
        }
        for ending in [" Wake Now on the card does it.", " Wake Now on the card tries again.", " Nothing was started."] where why.hasSuffix(ending) {
            why.removeLast(ending.count)
        }
        return why.trimmingCharacters(in: .whitespaces)
    }

    /// A line a wake that didn't go leaves on the card: a receipt's failure, or a post to your open session that failed.
    static func isFailureLine(_ text: String) -> Bool { (failureLines + unsentLines).contains { text.hasPrefix($0) } }

    /// Why Binders won't wake it, in the composer's words; nil when it would.
    private func notWakeable(_ agent: AgentProfile) -> CommentReach? {
        if registry.paused { return .paused }
        if !agent.isEnabled { return .turnedOff(agent.name) }
        if registry.changedOutside.contains(agent.id) { return .changedOutside(agent.name) }
        if let why = registry.held[agent.id] { return .held(agent.name, why: why) }
        if agent.wake == .board { return .checksBoard(agent.name) }
        return nil
    }

    /// The most wakes an hour for the agent.
    static func cap(_ agent: AgentProfile) -> Int { agent.wakesPerHour ?? AgentProfile.defaultWakesPerHour }

    /// The agent's wakes left in the hour to `now`, shared by all its cards.
    func wakesLeft(_ agent: AgentProfile, now: Date = Date()) -> Int {
        Self.cap(agent) - (woken[agent.id] ?? []).filter { now.timeIntervalSince($0) < 3_600 }.count
    }

    /// Why the newest of your words on the card hasn't gone to its agent, while Binders runs: gathering for its two seconds
    /// or waiting for the card's last post to settle, waiting behind a run, or what stopped it, with when (nil for the
    /// first two, which are about now). Nil when nothing is known, as after a relaunch.
    func unsent(for card: TaskCard) -> (why: String, at: Date?)? {
        let name = (card.assignee ?? card.meantFor ?? "the agent").components(separatedBy: " · ").first ?? "the agent"
        if gathering.contains(card.id) || deferred[card.id] != nil && sending[card.id] != nil { return ("Sending in a moment", nil) }
        if deferred[card.id] != nil { return ("Not sent yet: it goes when \(name)'s run ends", nil) }
        return notSent[card.id].map { ($0.why, $0.at) }
    }

    /// For the drawings, in a throwaway folder only: what the header shows for a run that's going and for the last wake, and
    /// why the newest of your words on a card wasn't sent.
    func drawing(working: Set<UUID>, outcomes: [UUID: AutomationService.Outcome], unsent: [UUID: String] = [:]) {
        guard AppPaths.isDemo else { return }
        self.working.formUnion(working)
        self.outcomes.merge(outcomes) { _, new in new }
        for (id, why) in unsent { notSent[id] = (Date(), why) }
    }
}
