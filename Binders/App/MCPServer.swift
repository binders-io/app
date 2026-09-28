import AppKit
import Foundation
import SwiftData
import BindersKit

/// `Binders --mcp`: a Model Context Protocol server on standard input and output, for Claude Code, Claude Desktop and any
/// other host that wants this Mac's knowledge base. It reads the same database the app uses. The two things it can add
/// go through binders:// links, so the running app does the writing and its windows update.
@MainActor
enum MCPServer {
    static let instructions = """
        Binders is the user's private, local knowledge base on this Mac: meeting notes, notes, dictations and writing they \
        chose to keep. Nothing here leaves the machine. Use search_knowledge for facts and quotes, ask_knowledge for a \
        written answer with sources, and the list/get tools to read whole items. Dates are ISO 8601, local time.

        Each binder also has a board of cards that people and agents pick up. To work on one: list_tasks (column ready), \
        claim_task, report with update_task as you go (it keeps your claim; a claim lapses after 30 minutes of silence), \
        ask_on_task if you need the user, and complete_task with a summary when you're done. Say who you are with `agent`.
        """

    static let tools: [MCPTool] = [
        MCPTool(name: "search_knowledge", description: "Search meetings, notes, dictations and captured writing by keywords and meaning. Returns the best-matching passages with their source.", parameters: [
            MCPToolParameter(name: "query", description: "What to look for.", required: true),
            MCPToolParameter(name: "limit", type: "integer", description: "How many passages, up to 30. Default 10."),
            MCPToolParameter(name: "kind", description: "Only this kind of source.", options: ["meeting", "note", "writing", "dictation"]),
        ]),
        MCPTool(name: "ask_knowledge", description: "Answer a question from the knowledge base, with the passages the answer drew on. Uses the user's local language model, so it can take several seconds.", parameters: [
            MCPToolParameter(name: "question", description: "The question, in plain words.", required: true),
        ]),
        MCPTool(name: "list_binders", description: "The user's binders: one per project or area, each holding meetings and notes."),
        MCPTool(name: "list_meetings", description: "Recent meetings, newest first, with a preview of their notes.", parameters: [
            MCPToolParameter(name: "limit", type: "integer", description: "How many, up to 50. Default 20."),
            MCPToolParameter(name: "binder", description: "Only meetings in the binder with this name."),
        ]),
        MCPTool(name: "get_meeting", description: "One meeting in full: notes, the user's own notes, attendees, and the transcript if asked.", parameters: [
            MCPToolParameter(name: "id", description: "The meeting's id, from list_meetings or a search result.", required: true),
            MCPToolParameter(name: "include_transcript", type: "boolean", description: "Also return the transcript with speakers and timestamps."),
        ]),
        MCPTool(name: "list_notes", description: "Recent notes, newest first.", parameters: [
            MCPToolParameter(name: "limit", type: "integer", description: "How many, up to 50. Default 20."),
            MCPToolParameter(name: "binder", description: "Only notes in the binder with this name."),
        ]),
        MCPTool(name: "get_note", description: "One note in full.", parameters: [
            MCPToolParameter(name: "id", description: "The note's id.", required: true),
        ]),
        MCPTool(name: "list_todos", description: "The user's to-dos: promises they made in messages, asks they made of others, to-dos they added, and the checklist items in meeting notes, notes and note digests. Each has an id for set_todo_status and create_task; card_id and card_column say when one is already on a board.", parameters: [
            MCPToolParameter(name: "status", description: "Which ones. Default open.", options: ["open", "done", "dismissed", "all"]),
        ]),
        MCPTool(name: "recent_dictations", description: "What the user dictated recently, newest first.", parameters: [
            MCPToolParameter(name: "limit", type: "integer", description: "How many, up to 50. Default 20."),
        ]),
        MCPTool(name: "add_todo", description: "Add a to-do to the user's board. A time at the end (\"tomorrow at 3 pm\", \"by Friday\") becomes its due date. Returns its id. Opens the Binders app if it isn't running.", parameters: [
            MCPToolParameter(name: "text", description: "The to-do, as a person would say it.", required: true),
            MCPToolParameter(name: "binder", description: "The binder it belongs to; see list_binders. Default: the user's current binder."),
        ]),
        MCPTool(name: "set_todo_status", description: "Mark a to-do done or reopen it; the checkbox in a note or meeting is ticked to match. Promises can also be dismissed.", parameters: [
            MCPToolParameter(name: "id", description: "The to-do's id, from list_todos or add_todo.", required: true),
            MCPToolParameter(name: "status", description: "The new status.", required: true, options: ["open", "done", "dismissed"]),
        ]),
        MCPTool(name: "list_tasks", description: "Cards on the binders' boards, where people and agents pick up work: what's ready, in progress, blocked or waiting for review. Everything but Done unless you ask for a column.", parameters: [
            MCPToolParameter(name: "binder", description: "Only this binder's board; see list_binders."),
            MCPToolParameter(name: "column", description: "Only this column.", options: ["backlog", "ready", "in_progress", "blocked", "review", "done"]),
            MCPToolParameter(name: "mine", type: "boolean", description: "Only the cards you (the agent named in `agent`) hold."),
            MCPToolParameter(name: "agent", description: "Your name on the board, as used with claim_task."),
        ]),
        MCPTool(name: "get_task", description: "One card in full: its description, links, who has it, and its timeline of moves, progress reports, questions and answers.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id, from list_tasks or create_task.", required: true),
        ]),
        MCPTool(name: "create_task", description: "Put a new card on a binder's board, or turn a to-do into one. Returns its id.", parameters: [
            MCPToolParameter(name: "title", description: "What needs doing, in a few words. Required unless you give todo."),
            MCPToolParameter(name: "todo", description: "A to-do's id from list_todos. The card goes to the to-do's binder, takes its words unless you give a title, and stays linked: the to-do is ticked off when the card is done. A to-do that already has a card returns that card."),
            MCPToolParameter(name: "details", description: "More about it, in Markdown if you like."),
            MCPToolParameter(name: "binder", description: "The binder's name; see list_binders. Default: the user's current binder."),
            MCPToolParameter(name: "column", description: "Where it starts. Default backlog.", options: ["backlog", "ready"]),
            MCPToolParameter(name: "agent", description: "Your name on the board."),
        ]),
        MCPTool(name: "claim_task", description: "Grab a card to work on it. One owner at a time; a Ready or Backlog card moves to In progress. Your claim lasts 30 minutes and every update extends it.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "agent", description: "Your name on the board, such as \"Claude Code · binders-io/app\". Default: the app you run in."),
        ]),
        MCPTool(name: "update_task", description: "Report progress on a card you hold (it keeps your claim), add links such as pull requests or files, or move it to another column.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "progress", description: "What you did or found since the last update."),
            MCPToolParameter(name: "links", description: "URLs or file paths, one per line or comma-separated."),
            MCPToolParameter(name: "column", description: "Move it here.", options: ["backlog", "ready", "in_progress", "blocked", "review", "done"]),
            MCPToolParameter(name: "agent", description: "Your name on the board."),
        ]),
        MCPTool(name: "ask_on_task", description: "Ask the user a question about a card. It moves to Blocked until they answer; get_task shows the answer.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "question", description: "What you need to know.", required: true),
            MCPToolParameter(name: "agent", description: "Your name on the board."),
        ]),
        MCPTool(name: "comment_task", description: "Add a comment to a card's timeline.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "text", description: "The comment.", required: true),
            MCPToolParameter(name: "agent", description: "Your name on the board."),
        ]),
        MCPTool(name: "release_task", description: "Let go of a card you hold, with a note for whoever picks it up next. It goes back to Ready.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "note", description: "Where you got to, and what's left."),
            MCPToolParameter(name: "agent", description: "Your name on the board."),
        ]),
        MCPTool(name: "complete_task", description: "Finish a card with a summary of what was done. It goes to Review for the user, unless they let agents finish cards in that binder.", parameters: [
            MCPToolParameter(name: "id", description: "The card's id.", required: true),
            MCPToolParameter(name: "summary", description: "What was done, and anything the user should check.", required: true),
            MCPToolParameter(name: "agent", description: "Your name on the board."),
        ]),
        MCPTool(name: "add_to_calendar", description: "Add an event to the user's calendar from a phrase such as \"lunch with Sam tomorrow at noon\". Opens the Binders app if it isn't running.", parameters: [
            MCPToolParameter(name: "text", description: "What and when.", required: true),
        ]),
        MCPTool(name: "add_to_knowledge", description: "Put something into the knowledge base so it can be searched and asked about: a fact learned, a document's text, a web page, an email. Kept under the title with its source, in the named binder or the user's current one. Returns its id.", parameters: [
            MCPToolParameter(name: "title", description: "What it is, in a few words.", required: true),
            MCPToolParameter(name: "text", description: "The content, in Markdown if you like.", required: true),
            MCPToolParameter(name: "source", description: "Where it came from: a URL, a file name, a person, a tool."),
            MCPToolParameter(name: "binder", description: "The binder's name; see list_binders."),
        ]),
        MCPTool(name: "add_note", description: "Add a note to the knowledge base. The first line is its title. Goes into the named binder, or the user's current one. Returns its id.", parameters: [
            MCPToolParameter(name: "text", description: "The note, in Markdown if you like.", required: true),
            MCPToolParameter(name: "binder", description: "The binder's name; see list_binders."),
        ]),
        MCPTool(name: "append_to_note", description: "Add text to the end of an existing note.", parameters: [
            MCPToolParameter(name: "id", description: "The note's id, from list_notes or add_note.", required: true),
            MCPToolParameter(name: "text", description: "What to add.", required: true),
        ]),
        MCPTool(name: "create_binder", description: "Create a binder, one per project or area. Returns its id, or the existing binder's if the name is taken.", parameters: [
            MCPToolParameter(name: "name", description: "The binder's name.", required: true),
        ]),
        MCPTool(name: "add_meeting", description: "Add a meeting that happened elsewhere, from its notes or transcript, so it is searchable alongside the rest. Returns its id.", parameters: [
            MCPToolParameter(name: "title", description: "The meeting's title.", required: true),
            MCPToolParameter(name: "notes", description: "The notes, summary or transcript, in Markdown if you like.", required: true),
            MCPToolParameter(name: "date", description: "When it took place, ISO 8601. Default now."),
            MCPToolParameter(name: "attendees", description: "Names, comma-separated."),
            MCPToolParameter(name: "duration_minutes", type: "integer", description: "How long it ran."),
            MCPToolParameter(name: "app", description: "Where it took place, such as Zoom. Default Imported."),
            MCPToolParameter(name: "binder", description: "The binder's name; see list_binders."),
        ]),
    ]

    private static let knowledge = KnowledgeService()
    /// The host that connected ("claude-code"), from its initialize message: an agent's default name on the board.
    private static var clientName = "AI agent"
    private static let writeLock = NSLock()
    /// Requests still being answered; when the host closes the pipe, the server leaves once they are done.
    private static var pending = 0
    private static var closing = false

    static func start() {
        let reader = Thread {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                Task { @MainActor in await respond(to: trimmed) }
            }
            Task { @MainActor in
                closing = true
                if pending == 0 { exit(0) }
            }
        }
        reader.name = "io.binders.mac.mcp-stdin"
        reader.start()
        Log.app.notice("MCP server ready")
    }

    private static func respond(to line: String) async {
        pending += 1
        defer {
            pending -= 1
            if closing, pending == 0 { exit(0) }
        }
        guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            write(MCPCore.parseError())
            return
        }
        if message["method"] as? String == "initialize",
           let info = (message["params"] as? [String: Any])?["clientInfo"] as? [String: Any] {
            clientName = (info["title"] as? String) ?? BoardRules.agentName(fromClient: info["name"] as? String ?? "")
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let agent = BoardActor(name: clientName, kind: .agent)
        guard let reply = await MCPCore.handle(message, serverName: "binders", serverVersion: version, instructions: instructions, tools: tools,
                                               call: { name, arguments in try await call(name, arguments, knowledge: knowledge, write: handOff, actor: agent) }) else { return }
        write(reply)
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        writeLock.withLock {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    // MARK: Tools

    /// Carries out a write (add a note, tick a to-do…) and returns the tool's reply. `Binders --mcp` hands writes to the
    /// running app; the app's own phone link performs them directly.
    typealias Writer = (_ action: String, _ fields: [String: String]) async throws -> String

    /// Runs one tool. Shared by `Binders --mcp` and the phone link, which differ only in how they write.
    static func call(_ name: String, _ arguments: [String: Any], knowledge: KnowledgeService, write: Writer,
                     actor: BoardActor = BoardActor(name: "AI agent", kind: .agent)) async throws -> String {
        func string(_ key: String) -> String { (arguments[key] as? String ?? "").trimmed }
        /// Who is acting on the board: the agent's own name if it gave one, else the app it runs in; a person as themselves.
        func acting() -> BoardActor {
            guard actor.isAgent else { return actor }
            let named = string("agent")
            return named.isEmpty ? actor : BoardActor(name: String(named.prefix(80)), kind: .agent)
        }
        func boardWrite(_ action: String, _ fields: [String: String]) async throws -> String {
            guard !string("id").isEmpty || action == "create_task" else { throw MCPCore.ToolFailure("id is required") }
            let who = acting()
            return try await write(action, fields.merging(["id": string("id"), "actor": who.name, "actor_kind": who.kind.rawValue]) { a, _ in a })
        }
        func integer(_ key: String, default value: Int, max cap: Int) -> Int {
            let asked = (arguments[key] as? Int) ?? (arguments[key] as? Double).map(Int.init) ?? value
            return min(max(1, asked), cap)
        }
        switch name {
        case "search_knowledge":
            let query = string("query")
            guard !query.isEmpty else { throw MCPCore.ToolFailure("query is required") }
            let kinds: Set<KnowledgeKind>? = KnowledgeKind(rawValue: string("kind")).map { [$0] }
            let hits = await knowledge.search(query, kinds: kinds, limit: integer("limit", default: 10, max: 30))
            return json(hits.map(describe))
        case "ask_knowledge":
            let question = string("question")
            guard !question.isEmpty else { throw MCPCore.ToolFailure("question is required") }
            let answer = await knowledge.ask(question)
            return json(["answer": answer.text, "sources": answer.sources.map(describe)])
        case "list_binders":
            return json(Store.shared.binders(includeArchived: true).map { binder in
                let counts = Store.shared.counts(in: binder.id)
                return ["id": binder.id.uuidString, "name": binder.name, "archived": binder.archived, "shared": binder.sharedWithTeam || binder.isTeamCopy,
                        "meetings": counts.meetings, "notes": counts.notes, "color": binder.colorIndex] as [String: Any]
            })
        case "list_meetings":
            let binder = binderID(named: string("binder"))
            var descriptor = FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchLimit = integer("limit", default: 20, max: 50) * (binder == nil ? 1 : 4)
            let meetings = ((try? Store.shared.context.fetch(descriptor)) ?? [])
                .filter { binder == nil || $0.binderID == binder }
                .prefix(integer("limit", default: 20, max: 50))
            return json(meetings.map { meeting in
                ["id": meeting.id.uuidString, "title": meeting.title, "date": AutomationPayload.iso(meeting.createdAt),
                 "duration_minutes": Int(meeting.duration / 60), "attendees": meeting.attendees, "app": meeting.appName ?? "",
                 "binder": Store.shared.binder(meeting.binderID)?.name ?? "", "status": meeting.status,
                 "preview": String(meeting.summary.prefix(300))] as [String: Any]
            })
        case "get_meeting":
            guard let id = UUID(uuidString: string("id")) else { throw MCPCore.ToolFailure("id must be a meeting id") }
            guard let meeting = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })))?.first else {
                throw MCPCore.ToolFailure("No meeting with that id")
            }
            var result: [String: Any] = ["id": meeting.id.uuidString, "title": meeting.title, "date": AutomationPayload.iso(meeting.createdAt),
                                         "duration_minutes": Int(meeting.duration / 60), "attendees": meeting.attendees, "app": meeting.appName ?? "",
                                         "binder": Store.shared.binder(meeting.binderID)?.name ?? "",
                                         "notes": meeting.isTeamCopy ? TeamSyncService.shown(meeting.summary, by: meeting.teamAuthorName) : meeting.summary,
                                         "own_notes": meeting.userNotes]
            if arguments["include_transcript"] as? Bool == true {
                let names = meeting.speakerNames
                result["transcript"] = Store.shared.segments(for: meeting.id).map { segment in
                    let who = names[segment.speaker] ?? segment.speaker
                    return "[\(TranscriptFormatter.timestamp(segment.start))] \(who): \(segment.text)"
                }.joined(separator: "\n")
            }
            return json(result)
        case "list_notes":
            let binder = binderID(named: string("binder"))
            var descriptor = FetchDescriptor<NoteItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            descriptor.fetchLimit = integer("limit", default: 20, max: 50) * (binder == nil ? 1 : 4)
            let notes = ((try? Store.shared.context.fetch(descriptor)) ?? [])
                .filter { binder == nil || $0.binderID == binder }
                .prefix(integer("limit", default: 20, max: 50))
            return json(notes.map { note in
                ["id": note.id.uuidString, "title": note.title, "updated": AutomationPayload.iso(note.updatedAt),
                 "binder": Store.shared.binder(note.binderID)?.name ?? "", "preview": String(note.text.prefix(300))] as [String: Any]
            })
        case "get_note":
            guard let id = UUID(uuidString: string("id")) else { throw MCPCore.ToolFailure("id must be a note id") }
            guard let note = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })))?.first else {
                throw MCPCore.ToolFailure("No note with that id")
            }
            return json(["id": note.id.uuidString, "title": note.title, "created": AutomationPayload.iso(note.createdAt),
                         "updated": AutomationPayload.iso(note.updatedAt), "binder": Store.shared.binder(note.binderID)?.name ?? "",
                         "text": note.text, "digest": note.digest])
        case "list_todos":
            let wanted = string("status").isEmpty ? "open" : string("status")
            let todos = Store.shared.commitments().filter { wanted == "all" || $0.status == wanted }
            var items: [[String: Any]] = todos.map { todo in
                ["id": todo.id.uuidString, "task": todo.task, "owner": todo.owner, "kind": todo.kind, "status": todo.status,
                 "due": todo.dueAt.map(AutomationPayload.iso) ?? "", "due_as_said": todo.dueText ?? "", "to": todo.to ?? "",
                 "source": todo.sourceTitle, "binder": Store.shared.binder(todo.binderID)?.name ?? "",
                 "created": AutomationPayload.iso(todo.createdAt)] as [String: Any]
            }
            if wanted != "dismissed" { items += checklistItems(status: wanted) }
            // Which ones are already on a board.
            let linked = ((try? Store.shared.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.sourceRef != nil }))) ?? [])
                .reduce(into: [String: TaskCard]()) { cards, card in if let todo = card.sourceRef { cards[todo] = card } }
            for index in items.indices {
                let card = (items[index]["id"] as? String).flatMap { linked[$0] }
                items[index]["card_id"] = card?.id.uuidString ?? ""
                items[index]["card_column"] = card?.column.rawValue ?? ""
            }
            return json(items)
        case "recent_dictations":
            let records = Store.shared.recentTranscripts(limit: integer("limit", default: 20, max: 50) * 2)
                .filter { $0.mode == "dictation" && $0.status == "inserted" && !$0.finalText.trimmed.isEmpty }
                .prefix(integer("limit", default: 20, max: 50))
            return json(records.map { record in
                ["id": record.id.uuidString, "date": AutomationPayload.iso(record.createdAt), "app": record.appName ?? "", "text": record.finalText] as [String: Any]
            })
        case "add_todo", "add_to_calendar":
            guard !string("text").isEmpty else { throw MCPCore.ToolFailure("text is required") }
            return try await write(name, ["text": string("text"), "binder": string("binder")])
        case "add_note":
            guard !string("text").isEmpty else { throw MCPCore.ToolFailure("text is required") }
            return try await write(name, ["text": string("text"), "binder": string("binder")])
        case "add_to_knowledge":
            guard !string("title").isEmpty, !string("text").isEmpty else { throw MCPCore.ToolFailure("title and text are required") }
            let source = string("source").isEmpty ? "" : "Source: \(string("source"))\n\n"
            return try await write("add_note", ["text": "\(string("title"))\n\n\(source)\(string("text"))", "binder": string("binder")])
        case "append_to_note":
            guard !string("id").isEmpty, !string("text").isEmpty else { throw MCPCore.ToolFailure("id and text are required") }
            return try await write(name, ["id": string("id"), "text": string("text")])
        case "create_binder":
            guard !string("name").isEmpty else { throw MCPCore.ToolFailure("name is required") }
            return try await write(name, ["name": string("name")])
        case "add_meeting":
            guard !string("title").isEmpty, !string("notes").isEmpty else { throw MCPCore.ToolFailure("title and notes are required") }
            let minutes = (arguments["duration_minutes"] as? Int) ?? (arguments["duration_minutes"] as? Double).map(Int.init)
            return try await write(name, ["title": string("title"), "notes": string("notes"), "date": string("date"), "attendees": string("attendees"),
                                            "duration_minutes": minutes.map(String.init) ?? "", "app": string("app"), "binder": string("binder")])
        case "set_todo_status":
            guard !string("id").isEmpty, !string("status").isEmpty else { throw MCPCore.ToolFailure("id and status are required") }
            return try await write(name, ["id": string("id"), "status": string("status")])
        case "list_tasks":
            let binder = binderID(named: string("binder"))
            if !string("binder").isEmpty, binder == nil { throw MCPCore.ToolFailure("No binder named “\(string("binder"))”. list_binders shows the names.") }
            let column = BoardColumn(loose: string("column"))
            let me = acting().name
            let now = Date()
            let cards = ((try? Store.shared.context.fetch(FetchDescriptor<TaskCard>(sortBy: [SortDescriptor(\.position, order: .reverse)]))) ?? [])
                .filter { binder == nil || $0.binderID == binder }
                .filter { card in column.map { card.column == $0 } ?? (card.column != .done) }
                .filter { arguments["mine"] as? Bool != true || ($0.assignee == me && BoardRules.isClaimed($0.state, at: now)) }
            return json(cards.prefix(100).map { describe($0, now: now) })
        case "get_task":
            guard let id = UUID(uuidString: string("id")),
                  let card = (try? Store.shared.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.id == id })))?.first else {
                throw MCPCore.ToolFailure("No card with that id. list_tasks shows them.")
            }
            let events = (try? Store.shared.context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.taskID == id }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            var result = describe(card, now: Date())
            result["details"] = card.details
            result["links"] = card.links
            result["source"] = card.sourceTitle ?? ""
            result["timeline"] = events.suffix(60).map { event in
                ["when": AutomationPayload.iso(event.createdAt), "who": event.author, "agent": event.authorIsAgent, "kind": event.kindRaw,
                 "text": event.text, "to": event.toColumn ?? ""] as [String: Any]
            }
            return json(result)
        case "create_task":
            guard !string("title").isEmpty || !string("todo").isEmpty else { throw MCPCore.ToolFailure("Give a title, or a todo id from list_todos") }
            return try await boardWrite(name, ["title": string("title"), "todo": string("todo"), "details": string("details"), "binder": string("binder"),
                                               "column": string("column")])
        case "claim_task":
            return try await boardWrite(name, [:])
        case "update_task":
            guard !string("progress").isEmpty || !string("links").isEmpty || !string("column").isEmpty else {
                throw MCPCore.ToolFailure("Give progress, links or a column")
            }
            if !string("column").isEmpty, BoardColumn(loose: string("column")) == nil { throw MCPCore.ToolFailure("column must be one of backlog, ready, in_progress, blocked, review, done") }
            return try await boardWrite(name, ["progress": string("progress"), "links": string("links"), "column": string("column")])
        case "ask_on_task":
            guard !string("question").isEmpty else { throw MCPCore.ToolFailure("question is required") }
            return try await boardWrite(name, ["text": string("question")])
        case "comment_task":
            guard !string("text").isEmpty else { throw MCPCore.ToolFailure("text is required") }
            return try await boardWrite(name, ["text": string("text")])
        case "release_task":
            return try await boardWrite(name, ["text": string("note")])
        case "complete_task":
            guard !string("summary").isEmpty else { throw MCPCore.ToolFailure("summary is required") }
            return try await boardWrite(name, ["text": string("summary")])
        default:
            throw MCPCore.ToolFailure("No tool named \(name)")
        }
    }

    private static func describe(_ card: TaskCard, now: Date) -> [String: Any] {
        let held = BoardRules.isClaimed(card.state, at: now)
        return ["id": card.id.uuidString, "title": card.title, "column": card.column.rawValue,
                "assignee": held || card.column == .done || card.column == .review ? (card.assignee ?? "") : "",
                "assignee_is_agent": card.assigneeIsAgent, "claim_expires": held ? card.claimExpiresAt.map(AutomationPayload.iso) ?? "" : "",
                "binder": Store.shared.binder(card.binderID)?.name ?? "", "due": card.dueAt.map(AutomationPayload.iso) ?? "",
                "links": card.links.count, "updated": AutomationPayload.iso(card.updatedAt), "preview": String(card.details.prefix(200)),
                "todo": card.sourceRef ?? ""]
    }

    /// Hands a write to the running app through the inbox and waits for its answer. The app is the only writer, so its
    /// windows update and the index picks the item up; launching it takes a few seconds if it isn't running.
    /// Performs a write in this process, for the running app itself: the same reply `handOff` gives.
    static func writeInApp(controller: DictationController) -> Writer {
        { action, fields in
            let result = await InboxCommands.perform(InboxRequest(action: action, fields: fields), controller: controller)
            guard result.ok else { throw MCPCore.ToolFailure(result.error ?? "The app couldn't do that") }
            var reply: [String: Any] = ["message": result.message]
            if let id = result.id { reply["id"] = id }
            return json(reply)
        }
    }

    private static func handOff(_ action: String, _ fields: [String: String]) async throws -> String {
        let name = UUID().uuidString
        let directory = InboxCommands.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requestURL = directory.appendingPathComponent(Inbox.requestFile(name))
        let resultURL = directory.appendingPathComponent(Inbox.resultFile(name))
        try JSONEncoder().encode(InboxRequest(action: action, fields: fields)).write(to: requestURL, options: .atomic)
        var components = URLComponents()
        components.scheme = "binders"
        components.host = "apply"
        components.queryItems = [URLQueryItem(name: "file", value: name)]
        guard let url = components.url else { throw MCPCore.ToolFailure("Couldn't build the link") }
        NSWorkspace.shared.open(url)
        for _ in 0..<300 {
            if let data = try? Data(contentsOf: resultURL), let result = try? JSONDecoder().decode(InboxResult.self, from: data) {
                try? FileManager.default.removeItem(at: resultURL)
                guard result.ok else { throw MCPCore.ToolFailure(result.error ?? "The app couldn't do that") }
                var reply: [String: Any] = ["message": result.message]
                if let id = result.id { reply["id"] = id }
                return json(reply)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: requestURL)
        throw MCPCore.ToolFailure("Binders didn't answer within 30 seconds. Is the app running?")
    }

    /// The checklist items the board shows from meeting notes, note digests and notes, newest sources first.
    private static func checklistItems(status wanted: String) -> [[String: Any]] {
        let context = Store.shared.context
        var meetingsQuery = FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        meetingsQuery.fetchLimit = 60
        var notesQuery = FetchDescriptor<NoteItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        notesQuery.fetchLimit = 120
        var items: [[String: Any]] = []
        let reader = TeamSyncService.myName
        /// `author` is the teammate who shared it, whose "You" is them; nil for your own.
        func scan(_ markdown: String, place: BoardTaskReference.Place, id: UUID, kind: String, title: String, date: Date, binderID: UUID?,
                  author: String?) {
            for line in markdown.components(separatedBy: "\n") {
                guard let task = NotesEditing.task(from: line), !task.text.isEmpty else { continue }
                let owner = NotesEditing.owner(task.owner, author: author, reader: reader)
                let status = task.done ? "done" : "open"
                guard wanted == "all" || wanted == status else { continue }
                items.append(["id": BoardTaskReference(place: place, id: id, text: task.text).string, "task": task.text,
                              "owner": owner ?? "", "kind": kind, "status": status, "source": title, "source_id": id.uuidString,
                              "binder": Store.shared.binder(binderID)?.name ?? "", "created": AutomationPayload.iso(date)])
            }
        }
        for meeting in (try? context.fetch(meetingsQuery)) ?? [] {
            scan(meeting.summary, place: .meeting, id: meeting.id, kind: "meeting", title: meeting.title, date: meeting.createdAt, binderID: meeting.binderID,
                 author: meeting.isTeamCopy ? meeting.teamAuthorName : nil)
        }
        for note in (try? context.fetch(notesQuery)) ?? [] {
            let author = note.isTeamCopy ? note.teamAuthorName : nil
            scan(note.digest, place: .digest, id: note.id, kind: "note digest", title: note.title, date: note.updatedAt, binderID: note.binderID, author: author)
            scan(note.text, place: .note, id: note.id, kind: "note", title: note.title, date: note.updatedAt, binderID: note.binderID, author: author)
        }
        return items
    }

    private static func describe(_ hit: KnowledgeHit) -> [String: Any] {
        ["kind": hit.kind.rawValue, "source_id": hit.sourceID, "title": hit.title, "date": AutomationPayload.iso(hit.createdAt),
         "speaker": hit.speaker ?? "", "author": hit.author ?? "", "binder": Store.shared.binder(hit.binderID.flatMap(UUID.init))?.name ?? "",
         "text": hit.text, "score": (hit.score * 1000).rounded() / 1000]
    }

    private static func binderID(named name: String) -> UUID? {
        guard !name.isEmpty else { return nil }
        return Store.shared.binders(includeArchived: true).first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
