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
        MCPTool(name: "edit_task", description: "Change a card's title or description: a clearer title starting with a verb, a description that says what done looks like. Undo puts it back.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "title", description: "Its new title."),
            MCPToolParameter(name: "details", description: "Its new description, in full."),
            MCPToolParameter(name: "why", description: "Why, in a few words, for its timeline.", required: true),
        ]),
        MCPTool(name: "close_task", description: "Move a card to Done: work that's done already, or no longer wanted. A card an agent is working on stops there. On a team's board the move goes to the team's database, which may refuse it while it's out of reach. Undo puts it back where it was.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "why", description: "Why, for its timeline: \"done in 0.11.0\", \"no change in 90 days\".", required: true),
        ]),
        MCPTool(name: "merge_tasks", description: "Merge cards that are the same work into one: the others' descriptions and links go into it, and they move to Done, saying where they went. Every card must be open and on the same board. Undo puts them all back.", parameters: [
            MCPToolParameter(name: "into", description: "The card that stays.", required: true),
            MCPToolParameter(name: "ids", type: "array", description: "The cards that merge into it.", required: true),
            MCPToolParameter(name: "why", description: "Why they're the same work.", required: true),
        ]),
        MCPTool(name: "move_task", description: "Move a card to another column: backlog, ready, in_progress, review, blocked or done. Ready hands a card meant for an agent to it. A card an agent is working on stops there when it leaves In progress. Undo puts it back.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "column", description: "backlog, ready, in_progress, review, blocked or done.", required: true),
            MCPToolParameter(name: "why", description: "Why, for its timeline."),
        ]),
        MCPTool(name: "assign_task", description: "Give a card to someone: an agent (list_agents), which Binders starts on it as Give to does, moving it from Backlog to Ready; a person; or no one (leave to empty). Undo gives it back to whoever had it, but can't stop a run it started.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "to", description: "The agent's or person's name, as list_agents or the board writes it; empty for no one."),
            MCPToolParameter(name: "why", description: "Why, for its timeline."),
        ]),
        MCPTool(name: "delete_task", description: "Delete a card: a duplicate, a test card, or noise. Prefer close_task for work that's done or no longer wanted, which keeps its history. Undo makes it again, with its title, description, links, column and who it was for.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "why", description: "Why, for your reply.", required: true),
        ]),
        MCPTool(name: "list_proposals", readOnly: true, description: "Distill's proposals still waiting for review: for one note (id), or for every note (no id). Each proposal with when and who read it, and its waiting items: id, title, brief, section, whether that section is still in the note, size and who it's for.", parameters: [
            MCPToolParameter(name: "id", description: "The note's id. Leave it out for every note with a proposal waiting."),
        ]),
        MCPTool(name: "review_proposals", description: "Review a note's waiting proposals as the user would: place their items on the board as cards (place), or put them aside (dismiss). Without proposals, every waiting proposal of the note; without items, every waiting item of those. Dismissing items drops only them; dismissing whole proposals puts aside what's left of each. Placed cards go to Backlog unless column is ready, which hands the ones meant for agents to them. Undo takes it back.", parameters: [
            MCPToolParameter(name: "id", description: "The note's id.", required: true),
            MCPToolParameter(name: "action", description: "place or dismiss.", required: true),
            MCPToolParameter(name: "proposals", type: "array", description: "The proposals' ids, from list_proposals."),
            MCPToolParameter(name: "items", type: "array", description: "The items' ids, from list_proposals."),
            MCPToolParameter(name: "column", description: "For place: backlog (the default) or ready."),
        ]),
        MCPTool(name: "delete_note", description: "Delete a note of the user's. Not a teammate's, one shared with the team, or one on the hub in a linked binder (that deletes it for everyone: the user does that). Undo puts it back with the same id.", parameters: [
            MCPToolParameter(name: "id", description: "The note's id.", required: true),
            MCPToolParameter(name: "why", description: "Why, for your reply.", required: true),
        ]),
        MCPTool(name: "edit_binder", description: "Rename a binder, change its colour, or archive it (or bring it back). Undo puts it back as it was.", parameters: [
            MCPToolParameter(name: "id", description: "The binder's id or name.", required: true),
            MCPToolParameter(name: "name", description: "Its new name."),
            MCPToolParameter(name: "color", type: "integer", description: "Its colour: 0 to 7, as list_binders gives them."),
            MCPToolParameter(name: "archived", type: "boolean", description: "true to archive it, false to bring it back."),
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
        You are the user's Manager: Binders woke you for one request, which get_request shows. You manage their binders \
        for them: their boards (create_task, edit_task, move_task, assign_task, close_task, merge_tasks, delete_task, \
        comment_task), Distill (distill_note, propose_work_items, list_proposals, review_proposals), their notes (add_note, update_note, \
        append_to_note, delete_note, propose_note_edit), folders (create_folder, rename_folder, move_item) and binders \
        (create_binder, edit_binder). Every change is kept with the request, and the user can undo them all at once. \
        Finish with reply.
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
        case "move_task":
            guard !string("id").isEmpty, !string("column").isEmpty else { throw MCPCore.ToolFailure("id and column are required") }
            return try await write("move_task", who.merging(["id": string("id"), "column": string("column"), "why": string("why")]) { a, _ in a })
        case "assign_task":
            guard !string("id").isEmpty else { throw MCPCore.ToolFailure("id is required") }
            return try await write("assign_task", who.merging(["id": string("id"), "to": string("to"), "why": string("why")]) { a, _ in a })
        case "delete_task", "delete_note":
            guard !string("id").isEmpty else { throw MCPCore.ToolFailure("id is required") }
            guard !string("why").isEmpty else { throw MCPCore.ToolFailure("why is required") }
            return try await write(name, who.merging(["id": string("id"), "why": string("why")]) { a, _ in a })
        case "list_proposals":
            return json(ManagerProposals.list(note: UUID(uuidString: string("id"))))
        case "review_proposals":
            guard !string("id").isEmpty else { throw MCPCore.ToolFailure("id is required") }
            guard ["place", "dismiss"].contains(string("action")) else { throw MCPCore.ToolFailure("action is place or dismiss") }
            func ids(_ key: String) -> String {
                if let list = arguments[key] as? [Any] { return list.compactMap { $0 as? String }.joined(separator: ",") }
                return string(key)
            }
            return try await write("review_proposals", who.merging(["id": string("id"), "action": string("action"), "proposals": ids("proposals"),
                                                                    "items": ids("items"), "column": string("column")]) { a, _ in a })
        case "edit_binder":
            guard !string("id").isEmpty else { throw MCPCore.ToolFailure("id is required") }
            var fields = who.merging(["id": string("id"), "name": string("name")]) { a, _ in a }
            if let color = arguments["color"] { fields["color"] = "\(color)" }
            if let archived = arguments["archived"] {
                fields["archived"] = (archived as? Bool).map { $0 ? "true" : "false" } ?? "\(archived)"
            }
            return try await write("edit_binder", fields)
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
