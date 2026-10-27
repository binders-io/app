import Foundation

/// What `Binders --mcp` offers, from what started it (BINDERS_TOOLS, BINDERS_RUN, BINDERS_CARD, BINDERS_AGENT), read once.
/// Every run Binders starts for a card sets BINDERS_TOOLS=board and BINDERS_RUN: that card's board tools as that agent, or
/// no tools at all when the card or the agent's name didn't arrive, so a tool that passes the values on badly gets nothing
/// rather than every card on every board. BINDERS_TOOLS stays "board" because a Binders before this one (Mac 0.8.0, say,
/// put back in /Applications while a run goes on) reads any other value as your own host, with every tool; it ignores
/// BINDERS_RUN and still offers that card's board tools only.
public enum MCPConfinement: Equatable, Sendable {
    /// Your own hosts: every tool.
    case everything
    /// An agent you set up its own server for (`AgentMCPEntry`): the board tools, one card's when BINDERS_CARD is set.
    case board(card: UUID?)
    /// A run Binders started: the board tools but create_task, for this card only.
    case card(UUID)
    /// A run Binders started that didn't get its card or its name: no tools at all.
    case nothing
    /// A run of the Manager, the agent you gave that role in Settings → Agents, for one request (BINDERS_MANAGER): reads
    /// across your binders and the Manager's tools (`ManagerTools.offered`), as that agent. Its BINDERS_CARD is the
    /// request's id, which no card has, so a Binders before this one offers it one card's board tools for no card at all.
    case manager(request: UUID)

    public static func read(_ environment: [String: String]) -> MCPConfinement {
        let card = environment["BINDERS_CARD"].flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }
        // A run Binders started, whatever BINDERS_TOOLS says ("card" was this build's first way of saying so).
        if environment["BINDERS_RUN"] != nil || environment["BINDERS_TOOLS"] == "card" {
            let agent = (environment["BINDERS_AGENT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The Manager's run: its request, and the same id as its card, or nothing.
            if let asked = environment["BINDERS_MANAGER"] {
                guard let request = UUID(uuidString: asked.trimmingCharacters(in: .whitespaces)), request == card,
                      !agent.isEmpty, !BoardRules.isReserved(agent) else { return .nothing }
                return .manager(request: request)
            }
            guard let card, !agent.isEmpty, !BoardRules.isReserved(agent) else { return .nothing }
            return .card(card)
        }
        return environment["BINDERS_TOOLS"] == "board" ? .board(card: card) : .everything
    }

    /// The one card it may see and change, if it's confined to one.
    public var card: UUID? {
        switch self {
        case .board(let card): card
        case .card(let card): card
        case .everything, .nothing, .manager: nil
        }
    }

    /// The Manager's request, for a run of the Manager.
    public var managerRequest: UUID? {
        if case .manager(let request) = self { return request }
        return nil
    }

    /// Whether it offers the board's tools alone (or none), as an agent. Not the Manager, which reads your binders.
    public var boardOnly: Bool {
        switch self {
        case .everything, .manager: false
        case .board, .card, .nothing: true
        }
    }

    /// Whether it acts as the one agent its host pinned, whatever the agent calls itself: a run Binders started, or a server
    /// set up for one of your agents.
    public var pinsAgent: Bool { self != .everything }

    /// What the server says about itself when it offers nothing.
    public static let nothingInstructions = "Binders started this server for one card but didn't say which, so it offers no tools."
}
