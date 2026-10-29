import Foundation
import BindersKit

/// An agent's sessions over the link (lane AC2), from a Mac that lists `LinkFeatures.sessions`: its cards and chats, and
/// one as its terminal, as the Mac's Agents page shows them. What a run says and does is the agent's: data, shown as its.
enum SessionLink {
    @MainActor
    static func available(_ connection: MacConnection) -> Bool { connection.macFeatures.contains(LinkFeatures.sessions) }

    /// The agent and its sessions; nil when the Mac is out of reach.
    @MainActor
    static func list(agent: String, over connection: MacConnection) async -> AgentSessionList? {
        guard let reply = try? await connection.request(LinkFeatures.sessionListMethod, ["agent": agent]) as? [String: Any] else { return nil }
        return AgentSessionLink.decode(AgentSessionList.self, from: reply)
    }

    enum Shown {
        case shown(AgentSessionShown)
        /// The Mac doesn't have it any more, and says why.
        case gone(String)
        case unreached
    }

    /// One session as its terminal.
    @MainActor
    static func shown(_ session: AgentSessionSummary.Kind, id: String, agent: String, over connection: MacConnection) async -> Shown {
        do {
            guard let reply = try await connection.request(LinkFeatures.sessionMethod, ["kind": session.rawValue, "id": id, "agent": agent]) as? [String: Any],
                  let shown = AgentSessionLink.decode(AgentSessionShown.self, from: reply) else { return .unreached }
            return .shown(shown)
        } catch LinkClient.Failure.rejected(let message) {
            return .gone(message)
        } catch {
            return .unreached
        }
    }

    /// Your words into a card's session, for `agent`, the one you said yes to. `id` is theirs, so words sent again go once.
    /// Why they didn't go, or nil.
    @MainActor
    static func send(_ text: String, card: String, agent: String, id: UUID, over connection: MacConnection) async -> String? {
        do {
            return try await connection.request(LinkFeatures.sessionSendMethod, ["card": card, "agent": agent, "text": text, "id": id.uuidString]) == nil
                ? ManagerLink.unreached : nil
        } catch LinkClient.Failure.rejected(let message) {
            return message
        } catch {
            return ManagerLink.unreached
        }
    }

    /// Stops a card's run. Why not, or nil.
    @MainActor
    static func stop(card: String, over connection: MacConnection) async -> String? {
        do {
            return try await connection.request(LinkFeatures.sessionActMethod, ["card": card, "action": "stop"]) == nil ? ManagerLink.unreached : nil
        } catch LinkClient.Failure.rejected(let message) {
            return message
        } catch {
            return ManagerLink.unreached
        }
    }
}
