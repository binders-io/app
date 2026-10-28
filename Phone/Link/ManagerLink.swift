import Foundation
import BindersKit

/// The Manager (lane MG3), over the link: its requests and the note edits it suggests, as the Mac's
/// `binders/manager-requests` gives them, and what you ask or do (`binders/manager`, `binders/manager-act`). Only from a Mac
/// that lists `LinkFeatures.manager`. Its replies are the Manager's words, shown as its.
enum ManagerLink {
    /// One request and what came of it (`ManagerRequest.jsonObject` on the Mac), read with snake-case keys.
    struct Request: Decodable, Identifiable, Hashable {
        struct Change: Decodable, Hashable {
            let kind: String
            let line: String
        }
        let id: String
        let thread: String
        /// "ask" or "tidy".
        let kind: String
        let text: String
        /// "mac", "iphone" or "schedule".
        let from: String
        let at: String
        /// waiting, running, answered, failed or stopped.
        let status: String
        let canUndo: Bool
        let changes: [Change]
        var binder: String? = nil
        var agent: String? = nil
        var reply: String? = nil
        var repliedAt: String? = nil
        var why: String? = nil
        var undoneAt: String? = nil

        var isOver: Bool { ["answered", "failed", "stopped"].contains(status) }
        var date: Date? { Date(iso: at) }
    }

    /// A note edit it suggests, for you to accept or dismiss: the lines it adds ("+ …") and takes away ("- …"), or
    /// `outdated` when the note changed since.
    struct Suggestion: Decodable, Identifiable, Hashable {
        let id: String
        let note: String
        let title: String
        let agent: String
        let why: String
        let at: String
        /// waiting, accepted or dismissed.
        let status: String
        var request: String? = nil
        var changes: [String]? = nil
        var outdated: Bool? = nil
    }

    /// What the Mac says: its latest requests, newest first; the edits waiting; who has the role; and why it can't
    /// start now, if it can't.
    struct Feed: Decodable, Equatable {
        var requests: [Request]
        var suggestions: [Suggestion]
        var agent: String? = nil
        /// The Manager is a local model, which stays on the Mac: nothing you ask goes anywhere else.
        var local: Bool? = nil
        var problem: String? = nil

        /// The latest, oldest first, as a conversation reads.
        var conversation: [Request] { requests.reversed() }
        var waiting: [Suggestion] { suggestions.filter { $0.status == "waiting" } }
        var running: Request? { requests.first { $0.status == "running" } }
    }

    /// How many of its latest requests the iPhone shows.
    static let shown = 30
    /// Where the last feed is kept, to show at once next time: one for each Mac you pair.
    @MainActor
    static func cacheKey(_ connection: MacConnection) -> String? {
        connection.mac.map { "manager-feed-\($0.device.uuidString)" }
    }

    @MainActor
    static func cached(_ connection: MacConnection) -> Feed? {
        guard let key = cacheKey(connection), let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? decoder.decode(Feed.self, from: data)
    }

    /// The Mac's feed, or nil when it's out of reach or doesn't have the Manager.
    @MainActor
    static func load(_ connection: MacConnection) async -> Feed? {
        guard connection.macFeatures.contains(LinkFeatures.manager),
              let reply = try? await connection.request(LinkFeatures.managerListMethod, ["limit": shown]) as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: reply),
              let feed = try? decoder.decode(Feed.self, from: data) else { return nil }
        if let key = cacheKey(connection) { UserDefaults.standard.set(data, forKey: key) }
        return feed
    }

    enum Sent: Equatable {
        case asked
        case refused(String)
        /// The Mac is out of reach: nothing went.
        case unreached
    }

    /// Something you ask, or a tidy (`kind` "tidy", `binder` by name, or every binder). `id` is this message's own, so
    /// one sent again is one request. `thread`: a request whose conversation it goes on. `agent`: the Manager you were
    /// asked about, or that's a local model; the Mac refuses it, then or before it starts, once another has the role.
    @MainActor
    static func ask(_ text: String, kind: String = "ask", binder: String? = nil, thread: String?, id: UUID, agent: String?,
                    over connection: MacConnection) async -> Sent {
        var params: [String: Any] = ["text": text, "id": id.uuidString, "kind": kind]
        if let agent { params["agent"] = agent }
        if let thread { params["thread"] = thread }
        if let binder { params["binder"] = binder }
        do {
            return try await connection.request(LinkFeatures.managerMethod, params) == nil ? .unreached : .asked
        } catch LinkClient.Failure.rejected(let message) {
            return .refused(message)
        } catch {
            return .unreached
        }
    }

    /// Stop or undo a request (`id`), or accept or dismiss a suggestion (`suggestion`). What the Mac says, or why not.
    @MainActor
    static func act(_ action: String, request id: String? = nil, suggestion: String? = nil, over connection: MacConnection) async -> Result<String, Problem> {
        var params: [String: Any] = ["action": action]
        if let id { params["id"] = id }
        if let suggestion { params["suggestion"] = suggestion }
        do {
            guard let reply = try await connection.request(LinkFeatures.managerActMethod, params) as? [String: Any] else {
                return .failure(Problem(unreached))
            }
            return .success(reply["message"] as? String ?? "")
        } catch LinkClient.Failure.rejected(let message) {
            return .failure(Problem(message))
        } catch {
            return .failure(Problem(unreached))
        }
    }

    /// What a tap says when the Mac is out of reach: nothing was done.
    static let unreached = "Your Mac is out of reach, so nothing was done. Try again once it's back."

    struct Problem: Error, Equatable {
        let words: String
        init(_ words: String) { self.words = words }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
