import Foundation
import BindersKit

/// Chats with your agents (lane AC1), over the link: from a Mac that lists `LinkFeatures.chats`. A chat is a conversation
/// of its own, never a card; Claude Code answers in a session the Mac starts for it, and an agent that checks the board
/// itself answers with its tools. Replies are the agent's words, shown as its.
enum ChatLink {
    struct Message: Decodable, Identifiable, Hashable {
        let id: String
        /// "you" or "agent".
        let from: String
        let text: String
        let at: String
        var via: String? = nil
        var delivered: Bool? = nil

        var isYours: Bool { from == "you" }
        var date: Date? { Date(iso: at) }
    }

    struct Last: Decodable, Hashable {
        let from: String
        let text: String
        let at: String
    }

    struct Chat: Decodable, Identifiable, Hashable {
        let id: String
        let agent: String
        let title: String
        let startedAt: String
        let updatedAt: String
        /// idle, running or waiting.
        let status: String
        let count: Int
        var why: String? = nil
        var last: Last? = nil
        var messages: [Message]? = nil
        /// What its run has written so far, while it works.
        var live: String? = nil

        var updated: Date? { Date(iso: updatedAt) }
    }

    private struct List: Decodable { let chats: [Chat] }

    /// Whether chat reaches an agent of this kind, from this Mac.
    @MainActor
    static func chats(_ agent: AgentList.Agent?, over connection: MacConnection) -> Bool {
        guard let agent, connection.macFeatures.contains(LinkFeatures.chats) else { return false }
        return AgentChatReach.chats(agent.wakes)
    }

    /// An agent's chats, the latest first; nil when the Mac is out of reach.
    @MainActor
    static func list(agent: String, over connection: MacConnection) async -> [Chat]? {
        guard let reply = try? await connection.request(LinkFeatures.chatListMethod, ["agent": agent]) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: reply) else { return nil }
        return (try? decoder.decode(List.self, from: data))?.chats
    }

    /// One chat with its messages; nil when the Mac is out of reach or doesn't have it.
    @MainActor
    static func chat(_ id: String, over connection: MacConnection) async -> Chat? {
        guard let reply = try? await connection.request(LinkFeatures.chatMethod, ["id": id]) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: reply) else { return nil }
        return try? decoder.decode(Chat.self, from: data)
    }

    enum Sent {
        case sent(Chat)
        case refused(String)
        /// The Mac is out of reach: nothing went.
        case unreached
    }

    /// Your message, to `agent`, in `chat` (a new chat when nil). `id` is this message's own, so one sent again is one.
    @MainActor
    static func send(_ text: String, to agent: String, chat: String?, id: UUID, over connection: MacConnection) async -> Sent {
        var params: [String: Any] = ["text": text, "agent": agent, "id": id.uuidString]
        if let chat { params["chat"] = chat }
        do {
            guard let reply = try await connection.request(LinkFeatures.chatSendMethod, params) as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: reply), let chat = try? decoder.decode(Chat.self, from: data) else { return .unreached }
            return .sent(chat)
        } catch LinkClient.Failure.rejected(let message) {
            return .refused(message)
        } catch {
            return .unreached
        }
    }

    /// Stops a chat's run. Why not, or nil.
    @MainActor
    static func stop(_ id: String, over connection: MacConnection) async -> String? {
        do {
            return try await connection.request(LinkFeatures.chatActMethod, ["id": id, "action": "stop"]) == nil ? ManagerLink.unreached : nil
        } catch LinkClient.Failure.rejected(let message) {
            return message
        } catch {
            return ManagerLink.unreached
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
