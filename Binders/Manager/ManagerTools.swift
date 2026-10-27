import Foundation
import SwiftData
import BindersKit

/// The Manager's own MCP tools (lane MG1), offered only to a run of the Manager (`MCPConfinement.manager`): its request,
/// its reply, the board's tidying, and suggested note edits. The writes go to the app as the rest do, which checks they come
/// from the Manager's run for the request running now (`ManagerService.refusal`) and keeps each change for Undo.
@MainActor
enum ManagerMCP {
    static let tools: [MCPTool] = [
        MCPTool(name: "get_request", readOnly: true, description: "The request you were woken for: what the user asked in their words (or the tidy Binders asks for them), where it came from (mac, iphone or schedule), the binder a tidy keeps to, and the conversation it's part of, oldest first, with your earlier replies.", parameters: []),
        MCPTool(name: "reply", description: "Your answer to the request, which the user reads on their iPhone or Mac: short, plain, with what you changed and anything left for them. It ends the request; Binders lists your changes with an Undo.", parameters: [
            MCPToolParameter(name: "text", description: "The answer.", required: true),
        ]),
        MCPTool(name: "edit_task", description: "Change a card's title or description: a clearer title starting with a verb, a description that says what done looks like. Not a card an agent holds, one waiting on the user, or one on a team's board. Undo puts it back.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "title", description: "Its new title."),
            MCPToolParameter(name: "details", description: "Its new description, in full."),
            MCPToolParameter(name: "why", description: "Why, in a few words, for its timeline.", required: true),
        ]),
        MCPTool(name: "close_task", description: "Move a card in Backlog or Ready to Done: work that's done already, or long untouched and no longer wanted. Not one other cards wait for, or one on a team's board. Undo puts it back where it was.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "why", description: "Why, for its timeline: \"done in 0.11.0\", \"no change in 90 days\".", required: true),
        ]),
        MCPTool(name: "merge_tasks", description: "Merge cards that are the same work into one: the others' descriptions and links go into it, and they move to Done, saying where they went. Every card must be in Backlog or Ready, on the same board, and not on a team's board; none of the others may have cards waiting for it. Undo puts them all back.", parameters: [
            MCPToolParameter(name: "into", description: "The card that stays.", required: true),
            MCPToolParameter(name: "ids", type: "array", description: "The cards that merge into it.", required: true),
            MCPToolParameter(name: "why", description: "Why they're the same work.", required: true),
        ]),
        MCPTool(name: "propose_note_edit", description: "Suggest an edit to a note, for the user to accept or not: nothing changes until they do, and then it's their edit. Give find and replace to change a passage (exactly as get_note shows it, there once), or text for the whole note.", parameters: [
            MCPToolParameter(name: "id", description: "The note's id.", required: true),
            MCPToolParameter(name: "find", description: "The passage to change, exactly as it is."),
            MCPToolParameter(name: "replace", description: "What it becomes."),
            MCPToolParameter(name: "text", description: "The whole new note, instead of find and replace."),
            MCPToolParameter(name: "why", description: "Why, in a sentence the user reads beside it.", required: true),
        ]),
    ]

    static let names: Set<String> = Set(tools.map(\.name))

    /// The words a run of the Manager reads about Binders, after the rest.
    static let instructions = """
        You are the user's Manager: Binders woke you for one request, which get_request shows. You read across their \
        binders; you tidy their boards with edit_task, close_task, merge_tasks, create_task and comment_task, and their \
        folders with create_folder, rename_folder and move_item; you distill notes with distill_note; and you suggest note \
        edits with propose_note_edit, which wait for the user. Every change is kept with the request, and the user can undo \
        them all at once. Finish with reply.
        """

    /// Runs one of its tools for the run's request. The writes say which request they're for.
    static func call(_ name: String, _ arguments: [String: Any], request: UUID, write: MCPServer.Writer, actor: BoardActor) async throws -> String {
        func string(_ key: String) -> String { (arguments[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let who = ["actor": actor.name, "actor_kind": actor.kind.rawValue]
        switch name {
        case "get_request":
            let file = ManagerService.readFile()
            guard let asked = file.requests.first(where: { $0.id == request }) else { throw MCPCore.ToolFailure("Binders has no request \(request.uuidString).") }
            var reply: [String: Any] = ["id": asked.id.uuidString, "kind": asked.kind.rawValue, "text": asked.text, "from": asked.from.rawValue,
                                        "at": AutomationPayload.iso(asked.at)]
            if let binder = asked.binder {
                reply["binder"] = ["id": binder.uuidString, "name": Store.shared.binder(binder)?.name ?? ""]
            }
            let earlier = file.requests.filter { $0.thread == asked.thread && $0.id != asked.id && $0.at <= asked.at }.suffix(10)
            if !earlier.isEmpty {
                reply["conversation"] = earlier.map { item -> [String: Any] in
                    var entry: [String: Any] = ["text": item.text, "at": AutomationPayload.iso(item.at), "status": item.status.rawValue]
                    if let answer = item.reply { entry["your_reply"] = answer }
                    return entry
                }
            }
            return json(reply)
        case "reply":
            guard !string("text").isEmpty else { throw MCPCore.ToolFailure("text is required") }
            return try await write("manager_reply", who.merging(["text": string("text")]) { a, _ in a })
        case "edit_task":
            guard !string("id").isEmpty else { throw MCPCore.ToolFailure("id is required") }
            guard arguments["title"] != nil || arguments["details"] != nil else { throw MCPCore.ToolFailure("Give title, details or both") }
            var fields = who.merging(["id": string("id"), "why": string("why")]) { a, _ in a }
            if arguments["title"] != nil { fields["title"] = string("title") }
            if let details = arguments["details"] as? String { fields["details"] = details }
            return try await write("edit_task", fields)
        case "close_task":
            guard !string("id").isEmpty else { throw MCPCore.ToolFailure("id is required") }
            guard !string("why").isEmpty else { throw MCPCore.ToolFailure("why is required: it goes on the card") }
            return try await write("close_task", who.merging(["id": string("id"), "why": string("why")]) { a, _ in a })
        case "merge_tasks":
            let ids: [String]
            if let list = arguments["ids"] as? [Any] {
                ids = list.compactMap { $0 as? String }
            } else {
                ids = string("ids").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            guard !string("into").isEmpty, !ids.isEmpty else { throw MCPCore.ToolFailure("into and ids are required") }
            return try await write("merge_tasks", who.merging(["into": string("into"), "ids": ids.joined(separator: ","), "why": string("why")]) { a, _ in a })
        case "propose_note_edit":
            guard !string("id").isEmpty else { throw MCPCore.ToolFailure("id is required") }
            var fields = who.merging(["id": string("id"), "why": string("why")]) { a, _ in a }
            if let find = arguments["find"] as? String, !find.isEmpty {
                fields["find"] = find
                fields["replace"] = arguments["replace"] as? String ?? ""
            } else if let text = arguments["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fields["text"] = text
            } else {
                throw MCPCore.ToolFailure("Give find and replace, to change a passage, or text, for the whole note")
            }
            return try await write("propose_note_edit", fields)
        default:
            throw MCPCore.ToolFailure("No tool named \(name)")
        }
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
