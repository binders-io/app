import Foundation

// The agent board: one per binder, where people and AI agents pick up work, report progress and hand it back. These are
// the rules every surface shares (the Mac, the MCP tools, the phone); the app stores cards and their timelines.

public enum BoardColumn: String, CaseIterable, Codable, Sendable {
    case backlog
    case ready
    case inProgress = "in_progress"
    case blocked
    case review
    case done

    public var title: String {
        switch self {
        case .backlog: "Backlog"
        case .ready: "Ready"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .review: "Review"
        case .done: "Done"
        }
    }

    /// "in progress", "In Progress", "doing" and the like, as agents and people write them.
    public init?(loose text: String) {
        let key = text.lowercased().filter { $0.isLetter }
        switch key {
        case "backlog", "todo", "later": self = .backlog
        case "ready", "next", "up next": self = .ready
        case "inprogress", "doing", "started", "wip": self = .inProgress
        case "blocked", "waiting", "stuck": self = .blocked
        case "review", "inreview", "readyforreview": self = .review
        case "done", "finished", "complete", "completed", "closed": self = .done
        default: return nil
        }
    }
}

/// A card's state in the words A2A 1.0 and the MCP Tasks extension share, for agents that speak them. Ready is submitted,
/// In progress working, Blocked input_required while a question or a request for your approval waits on you and failed
/// otherwise (blocked with a reason, such as a run that stopped), Review and Done completed, and Backlog canceled.
public enum TaskState: String, CaseIterable, Sendable {
    case submitted
    case working
    case inputRequired = "input_required"
    case completed
    case failed
    case canceled

    public init(column: BoardColumn, questionWaiting: Bool) {
        switch column {
        case .backlog: self = .canceled
        case .ready: self = .submitted
        case .inProgress: self = .working
        case .blocked: self = questionWaiting ? .inputRequired : .failed
        case .review, .done: self = .completed
        }
    }

    /// The state of a card in `column` whose timeline, oldest first, is `events`: see `BoardRules.waitingAsk`.
    public init(column: BoardColumn, timeline events: [(kind: String, to: String)]) {
        self.init(column: column, questionWaiting: column == .blocked && BoardRules.waitingAsk(in: events) != nil)
    }

    /// As an agent's status writes it: "input-required", "INPUT_REQUIRED", "Cancelled"… A2A's rejected reads as failed, and
    /// its auth-required as input_required. Nil for anything else.
    public init?(loose text: String) {
        switch text.lowercased().filter(\.isLetter) {
        case "submitted": self = .submitted
        case "working": self = .working
        case "inputrequired", "authrequired": self = .inputRequired
        case "completed": self = .completed
        case "failed", "rejected": self = .failed
        case "canceled", "cancelled": self = .canceled
        default: return nil
        }
    }
}

/// Who is acting on the board: you, a teammate, or an AI agent such as "Claude Code · binders-io/app".
public struct BoardActor: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case person, agent
    }

    public var name: String
    public var kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    public static let you = BoardActor(name: "You", kind: .person)
    public var isAgent: Bool { kind == .agent }
}

/// The part of a card the rules care about.
public struct CardState: Equatable, Sendable {
    public var column: BoardColumn
    public var assignee: String?
    public var assigneeIsAgent: Bool
    /// When an agent's claim lapses unless it reports in. People's claims don't lapse.
    public var claimExpires: Date?

    public init(column: BoardColumn, assignee: String? = nil, assigneeIsAgent: Bool = false, claimExpires: Date? = nil) {
        self.column = column
        self.assignee = assignee
        self.assigneeIsAgent = assigneeIsAgent
        self.claimExpires = claimExpires
    }
}

public enum BoardError: Error, Equatable, LocalizedError {
    case claimedBy(String, until: Date?)
    case agentsCannotFinish
    case notYours(String)
    case finished
    /// It waits for other cards that aren't Done yet: their titles.
    case waitsFor([String])

    /// Read by agents, as only agents are refused: "You" on the board is the user.
    public var errorDescription: String? {
        func who(_ name: String) -> String { name == BoardActor.you.name ? "The user" : name }
        switch self {
        case .claimedBy(let name, let until):
            if let until { return "\(who(name)) has this until \(until.formatted(date: .omitted, time: .shortened)). Pick another card, or ask them to release it." }
            return "\(who(name)) has this. Pick another card, or ask them to release it."
        case .agentsCannotFinish:
            return "Agents can't move cards to Done in this binder. Use complete_task to hand it over for review."
        case .notYours(let name):
            return "\(who(name)) has this card, so only they, or a person, can release it."
        case .finished:
            return "This card is done. Move it back to Ready first to work on it again."
        case .waitsFor(let titles):
            let quoted = titles.prefix(3).map { "“\($0)”" }
            let list = quoted.count > 1 ? quoted.dropLast().joined(separator: ", ") + " and " + quoted.last! : quoted.first ?? "another card"
            let more = titles.count > 3 ? " and \(titles.count - 3) more" : ""
            return "This card waits for \(list)\(more), which \(titles.count == 1 ? "isn't" : "aren't") done yet, so it can't be taken yet. Pick another card."
        }
    }
}

public enum BoardRules {
    /// How long an agent's claim lasts without a word from it.
    public static let lease: TimeInterval = 30 * 60

    /// Whether someone holds the card right now. A card waiting on you, for an answer in Blocked or a look in Review, keeps
    /// its agent.
    public static func isClaimed(_ card: CardState, at now: Date) -> Bool {
        guard card.assignee != nil, card.column != .done else { return false }
        if card.column == .blocked || card.column == .review { return true }
        return card.claimExpires.map { $0 > now } ?? true
    }

    /// When an agent's claim runs out, as said in a refusal or a listing: only work in progress has a lease.
    public static func leaseEnd(_ card: CardState) -> Date? {
        card.assigneeIsAgent && card.column == .inProgress ? card.claimExpires : nil
    }

    /// The wait rule: an agent can't take a card while it waits for others that aren't Done (`waitingOn`, their titles),
    /// unless it holds the card already. A person always can.
    static func checkWaits(_ card: CardState, by actor: BoardActor, waitingOn: [String], at now: Date) throws {
        guard actor.isAgent, !waitingOn.isEmpty else { return }
        if isClaimed(card, at: now), card.assignee == actor.name { return }
        throw BoardError.waitsFor(waitingOn)
    }

    /// Grabbing a card: it moves to In progress if it was waiting, and an agent's claim on work in progress starts its
    /// lease. A person can take a card over from anyone; an agent only takes one that's free or its own, and not one that
    /// still waits for other cards (`waitingOn`: the titles of those that aren't Done).
    public static func claim(_ card: CardState, by actor: BoardActor, at now: Date, waitingOn: [String] = []) throws -> CardState {
        guard card.column != .done else { throw BoardError.finished }
        if actor.isAgent, isClaimed(card, at: now), card.assignee != actor.name {
            throw BoardError.claimedBy(card.assignee ?? "Someone", until: leaseEnd(card))
        }
        try checkWaits(card, by: actor, waitingOn: waitingOn, at: now)
        var next = card
        next.assignee = actor.name
        next.assigneeIsAgent = actor.isAgent
        // A person taking a blocked card over works on it rather than waiting for an answer.
        if card.column == .backlog || card.column == .ready || (!actor.isAgent && card.column == .blocked) { next.column = .inProgress }
        next.claimExpires = actor.isAgent && next.column == .inProgress ? now.addingTimeInterval(lease) : nil
        return next
    }

    /// Moving a card. People can move anything; agents only cards that are free or theirs, and not to Done unless the
    /// binder allows it. Back to Backlog or Ready lets go of the claim; Review and Done keep who did it but end the lease.
    /// An agent moving a card that still waits for others (`waitingOn`) into In progress, Review or Done takes it, so the
    /// wait rule holds there too.
    public static func move(_ card: CardState, to column: BoardColumn, by actor: BoardActor, agentsMayFinish: Bool, at now: Date,
                            waitingOn: [String] = []) throws -> CardState {
        if actor.isAgent {
            if column == .done, !agentsMayFinish { throw BoardError.agentsCannotFinish }
            if isClaimed(card, at: now), card.assignee != actor.name {
                throw BoardError.claimedBy(card.assignee ?? "Someone", until: leaseEnd(card))
            }
            if [.inProgress, .review, .done].contains(column) { try checkWaits(card, by: actor, waitingOn: waitingOn, at: now) }
        }
        var next = card
        next.column = column
        switch column {
        case .backlog, .ready:
            next.assignee = nil
            next.assigneeIsAgent = false
            next.claimExpires = nil
        case .review, .done:
            next.claimExpires = nil
        case .inProgress where next.assignee == nil || !isClaimed(card, at: now):
            // Starting work means taking it.
            next.assignee = actor.name
            next.assigneeIsAgent = actor.isAgent
            next.claimExpires = actor.isAgent ? now.addingTimeInterval(lease) : nil
        case .blocked:
            // Waiting for an answer: an agent's claim holds until then.
            if next.assigneeIsAgent { next.claimExpires = nil }
        default:
            if actor.isAgent, card.assignee == actor.name {
                next.claimExpires = now.addingTimeInterval(lease)
            } else if !actor.isAgent, column == .inProgress, card.assigneeIsAgent {
                // Sent back to the agent that has it: its claim starts over, so the card lapses to Ready if the agent
                // doesn't pick it up again.
                next.claimExpires = now.addingTimeInterval(lease)
            }
        }
        return next
    }

    /// Reporting in keeps an agent's claim on work in progress alive. A card waiting on you has no lease to keep.
    public static func renew(_ card: CardState, by actor: BoardActor, at now: Date) -> CardState {
        guard actor.isAgent, card.assignee == actor.name, card.column == .inProgress else { return card }
        var next = card
        next.claimExpires = now.addingTimeInterval(lease)
        return next
    }

    /// Asking for help: the card waits in Blocked until someone answers. An agent's claim holds while it waits, however
    /// long that is; the answer starts its lease again. An agent asks only about a card that's free or its own.
    public static func ask(_ card: CardState, by actor: BoardActor, at now: Date) throws -> CardState {
        guard card.column != .done else { throw BoardError.finished }
        if actor.isAgent, isClaimed(card, at: now), card.assignee != actor.name {
            throw BoardError.claimedBy(card.assignee ?? "Someone", until: leaseEnd(card))
        }
        var next = card
        next.column = .blocked
        if next.assigneeIsAgent { next.claimExpires = nil }
        return next
    }

    /// A person's answer to a blocked card sends it back to work, and the agent that has it gets a fresh lease.
    public static func answered(_ card: CardState, by actor: BoardActor, at now: Date) -> CardState {
        guard !actor.isAgent, card.column == .blocked else { return card }
        var next = card
        next.column = card.assignee == nil ? .ready : .inProgress
        if next.assigneeIsAgent { next.claimExpires = now.addingTimeInterval(lease) }
        return next
    }

    /// Handing work back. An agent can only let go of its own card; a person can release anyone's.
    public static func release(_ card: CardState, by actor: BoardActor, at now: Date) throws -> CardState {
        if actor.isAgent, isClaimed(card, at: now), card.assignee != actor.name { throw BoardError.notYours(card.assignee ?? "Someone") }
        var next = card
        next.assignee = nil
        next.assigneeIsAgent = false
        next.claimExpires = nil
        if [.inProgress, .blocked].contains(card.column) { next.column = .ready }
        return next
    }

    /// Finishing: a person's card is done; an agent's goes to Review unless the binder lets agents finish. An agent that
    /// doesn't hold a card that still waits for others (`waitingOn`) can't finish it either.
    public static func complete(_ card: CardState, by actor: BoardActor, agentsMayFinish: Bool, at now: Date,
                                waitingOn: [String] = []) throws -> CardState {
        if actor.isAgent, isClaimed(card, at: now), card.assignee != actor.name {
            throw BoardError.claimedBy(card.assignee ?? "Someone", until: leaseEnd(card))
        }
        try checkWaits(card, by: actor, waitingOn: waitingOn, at: now)
        var next = card
        next.column = (actor.isAgent && !agentsMayFinish) ? .review : .done
        if next.assignee == nil {
            next.assignee = actor.name
            next.assigneeIsAgent = actor.isAgent
        }
        next.claimExpires = nil
        return next
    }

    /// An agent that went quiet loses the card: it goes back to Ready for someone else. Nil when nothing lapsed. A card
    /// waiting for an answer in Blocked, or for you in Review, doesn't lapse.
    public static func expire(_ card: CardState, at now: Date) -> CardState? {
        guard card.assigneeIsAgent, let expires = card.claimExpires, expires <= now,
              ![.done, .review, .blocked].contains(card.column) else { return nil }
        var next = card
        next.assignee = nil
        next.assigneeIsAgent = false
        next.claimExpires = nil
        if card.column == .inProgress { next.column = .ready }
        return next
    }

    /// Where in a card's timeline, oldest first, is what it waits on you for: an agent's last question or request for your
    /// approval, as long as the card hasn't left Blocked since (answered, decided, taken over, moved). One answered before
    /// the card went back to Blocked by hand isn't asking again. Nil when nothing waits.
    public static func waitingAsk(in events: [(kind: String, to: String)]) -> Int? {
        guard let index = events.lastIndex(where: { $0.kind == "question" || $0.kind == "approval" }) else { return nil }
        let since = events[events.index(after: index)...]
        return since.allSatisfy { $0.to.isEmpty || $0.to == BoardColumn.blocked.rawValue } ? index : nil
    }

    /// The question a card waits on, when what it waits on is a question: see `waitingAsk`.
    public static func waitingQuestion(in events: [(kind: String, to: String)]) -> Int? {
        waitingAsk(in: events).flatMap { events[$0].kind == "question" ? $0 : nil }
    }

    /// The request for your approval a card waits on (`AgentApproval`), when that's what it waits on: see `waitingAsk`.
    public static func waitingApproval(in events: [(kind: String, to: String)]) -> Int? {
        waitingAsk(in: events).flatMap { events[$0].kind == "approval" ? $0 : nil }
    }

    /// A question's key, the same however the Mac's time zone writes the time: its card, and the second it was asked.
    public static func questionKey(card: String, asked when: String) -> String {
        let instant = isoParser.date(from: when).map { String(Int($0.timeIntervalSince1970)) } ?? when
        return "\(card)|\(instant)"
    }

    /// One parser for the timestamps cards carry (ISO 8601, as the Mac writes them), made once: making one is the slow
    /// part, and parsing with it is safe to share. The iPhone's own dates use it too (`Date(iso:)`), so it has one
    /// parser. Never change its options: everything that shares it reads by them.
    nonisolated(unsafe) public static let isoParser = ISO8601DateFormatter()

    /// "claude-code" → "Claude Code": an MCP client's name as a person would say it.
    public static func agentName(fromClient client: String) -> String {
        let words = client.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        guard !words.isEmpty else { return "AI agent" }
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return isReserved(name) ? "AI agent" : name
    }

    /// Whether `name` is `agent`, or a more particular form of it: "Claude Code · binders-io/app" is Claude Code. Case
    /// doesn't matter.
    public static func isNamed(_ name: String, as agent: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased(), agent = agent.trimmingCharacters(in: .whitespaces).lowercased()
        guard !agent.isEmpty else { return false }
        return name == agent || name.hasPrefix(agent + " ")
    }

    /// A name no agent may act under: the user's own. Every rule here tells people and agents apart by name.
    public static func isReserved(_ name: String) -> Bool { isNamed(name, as: BoardActor.you.name) }
}

/// Word of a card that's worth a quiet notification.
public enum BoardNews: String, Sendable {
    /// An agent took a card you had handed it.
    case pickedUp
    /// An agent put a card in Review for you to check.
    case review
}

extension BoardRules {
    /// What's worth telling you about a card that went from `before` (nil when it wasn't seen before) to `now`. Review,
    /// when an agent put it there. Picked up, when an agent took it from Backlog or Ready into In progress and you had
    /// meant it for someone (`confirmed`: your choice, not an agent's suggestion). Nil for anything else, your own moves
    /// included.
    public static func news(before: BoardColumn?, now: BoardColumn, byAgent: Bool, meantFor: String?, confirmed: Bool) -> BoardNews? {
        guard byAgent, before != now else { return nil }
        if now == .review { return .review }
        let handedOff = confirmed && !(meantFor ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        guard now == .inProgress, handedOff, before == nil || before == .backlog || before == .ready else { return nil }
        return .pickedUp
    }
}
