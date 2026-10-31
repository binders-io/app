import Foundation

/// Why a change on a card might wake one of this Mac's agents: made by you, or an agent's placing under Agents may place
/// work items.
public enum AgentWakeCause: Equatable, Sendable {
    case yours
    case placedByAgent
}

/// The dispatcher's rule for what didn't come from you: an agent's placing starts an agent only when its start switch
/// allows. Otherwise the card waits for your Give to, with why.
public enum AgentWakeRule {
    public enum Verdict: Equatable, Sendable {
        case wake
        /// It waits for your Give to: the line that says why.
        case waits(String)
    }

    public static func verdict(_ cause: AgentWakeCause, agent: String, startsOnItsOwn: Bool) -> Verdict {
        switch cause {
        case .yours:
            return .wake
        case .placedByAgent:
            if !startsOnItsOwn {
                return .waits("Waits for your Give to: \(agent) starts on cards an agent placed only once it may start on cards on its own (Settings → Agents).")
            }
            return .wake
        }
    }
}
