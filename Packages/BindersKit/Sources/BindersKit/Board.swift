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

    public var errorDescription: String? {
        switch self {
        case .claimedBy(let name, let until):
            if let until { return "\(name) has this until \(until.formatted(date: .omitted, time: .shortened)). Pick another card, or ask them to release it." }
            return "\(name) has this. Pick another card, or ask them to release it."
        case .agentsCannotFinish:
            return "Agents can't move cards to Done in this binder. Use complete_task to hand it over for review."
        case .notYours(let name):
            return "\(name) has this card, so only they, or a person, can release it."
        case .finished:
            return "This card is done. Move it back to Ready first to work on it again."
        }
    }
}

public enum BoardRules {
    /// How long an agent's claim lasts without a word from it.
    public static let lease: TimeInterval = 30 * 60

    /// Whether someone holds the card right now.
    public static func isClaimed(_ card: CardState, at now: Date) -> Bool {
        guard card.assignee != nil, card.column != .done else { return false }
        return card.claimExpires.map { $0 > now } ?? true
    }

    /// Grabbing a card: it moves to In progress if it was waiting, and an agent's claim starts its lease.
    public static func claim(_ card: CardState, by actor: BoardActor, at now: Date) throws -> CardState {
        guard card.column != .done else { throw BoardError.finished }
        if isClaimed(card, at: now), card.assignee != actor.name {
            throw BoardError.claimedBy(card.assignee ?? "Someone", until: card.assigneeIsAgent ? card.claimExpires : nil)
        }
        var next = card
        next.assignee = actor.name
        next.assigneeIsAgent = actor.isAgent
        next.claimExpires = actor.isAgent ? now.addingTimeInterval(lease) : nil
        if card.column == .backlog || card.column == .ready { next.column = .inProgress }
        return next
    }

    /// Moving a card. People can move anything; agents only cards that are free or theirs, and not to Done unless the
    /// binder allows it. Back to Backlog or Ready lets go of the claim; Done keeps who did it but ends the lease.
    public static func move(_ card: CardState, to column: BoardColumn, by actor: BoardActor, agentsMayFinish: Bool, at now: Date) throws -> CardState {
        if actor.isAgent {
            if column == .done, !agentsMayFinish { throw BoardError.agentsCannotFinish }
            if isClaimed(card, at: now), card.assignee != actor.name {
                throw BoardError.claimedBy(card.assignee ?? "Someone", until: card.assigneeIsAgent ? card.claimExpires : nil)
            }
        }
        var next = card
        next.column = column
        switch column {
        case .backlog, .ready:
            next.assignee = nil
            next.assigneeIsAgent = false
            next.claimExpires = nil
        case .done:
            next.claimExpires = nil
        case .inProgress where next.assignee == nil || !isClaimed(card, at: now):
            // Starting work means taking it.
            next.assignee = actor.name
            next.assigneeIsAgent = actor.isAgent
            next.claimExpires = actor.isAgent ? now.addingTimeInterval(lease) : nil
        default:
            if actor.isAgent, card.assignee == actor.name { next.claimExpires = now.addingTimeInterval(lease) }
        }
        return next
    }

    /// Reporting in keeps an agent's claim alive.
    public static func renew(_ card: CardState, by actor: BoardActor, at now: Date) -> CardState {
        guard actor.isAgent, card.assignee == actor.name, card.column != .done else { return card }
        var next = card
        next.claimExpires = now.addingTimeInterval(lease)
        return next
    }

    /// Asking for help: the card waits in Blocked until someone answers.
    public static func ask(_ card: CardState, by actor: BoardActor, at now: Date) throws -> CardState {
        guard card.column != .done else { throw BoardError.finished }
        var next = renew(card, by: actor, at: now)
        next.column = .blocked
        return next
    }

    /// A person's answer to a blocked card sends it back to work.
    public static func answered(_ card: CardState, by actor: BoardActor) -> CardState {
        guard !actor.isAgent, card.column == .blocked else { return card }
        var next = card
        next.column = card.assignee == nil ? .ready : .inProgress
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

    /// Finishing: a person's card is done; an agent's goes to Review unless the binder lets agents finish.
    public static func complete(_ card: CardState, by actor: BoardActor, agentsMayFinish: Bool, at now: Date) throws -> CardState {
        if actor.isAgent, isClaimed(card, at: now), card.assignee != actor.name {
            throw BoardError.claimedBy(card.assignee ?? "Someone", until: card.claimExpires)
        }
        var next = card
        next.column = (actor.isAgent && !agentsMayFinish) ? .review : .done
        if next.assignee == nil {
            next.assignee = actor.name
            next.assigneeIsAgent = actor.isAgent
        }
        next.claimExpires = nil
        return next
    }

    /// An agent that went quiet loses the card: it goes back to Ready for someone else. Nil when nothing lapsed.
    public static func expire(_ card: CardState, at now: Date) -> CardState? {
        guard card.assigneeIsAgent, let expires = card.claimExpires, expires <= now, card.column != .done, card.column != .review else { return nil }
        var next = card
        next.assignee = nil
        next.assigneeIsAgent = false
        next.claimExpires = nil
        if [.inProgress, .blocked].contains(card.column) { next.column = .ready }
        return next
    }

    /// "claude-code" → "Claude Code": an MCP client's name as a person would say it.
    public static func agentName(fromClient client: String) -> String {
        let words = client.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
        guard !words.isEmpty else { return "AI agent" }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
