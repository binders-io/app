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
        MCPTool(name: "list_todos", description: "The user's to-dos: promises they made in messages, asks they made of others, and to-dos they added themselves.", parameters: [
            MCPToolParameter(name: "status", description: "Which ones. Default open.", options: ["open", "done", "dismissed", "all"]),
        ]),
        MCPTool(name: "recent_dictations", description: "What the user dictated recently, newest first.", parameters: [
            MCPToolParameter(name: "limit", type: "integer", description: "How many, up to 50. Default 20."),
        ]),
        MCPTool(name: "add_todo", description: "Add a to-do to the user's board. A time at the end (\"tomorrow at 3 pm\", \"by Friday\") becomes its due date. Returns its id. Opens the Binders app if it isn't running.", parameters: [
            MCPToolParameter(name: "text", description: "The to-do, as a person would say it.", required: true),
        ]),
        MCPTool(name: "set_todo_status", description: "Mark a to-do done, reopen it, or dismiss it.", parameters: [
            MCPToolParameter(name: "id", description: "The to-do's id, from list_todos or add_todo.", required: true),
            MCPToolParameter(name: "status", description: "The new status.", required: true, options: ["open", "done", "dismissed"]),
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard let reply = await MCPCore.handle(message, serverName: "binders", serverVersion: version, instructions: instructions, tools: tools,
                                               call: { name, arguments in try await call(name, arguments) }) else { return }
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

    private static func call(_ name: String, _ arguments: [String: Any]) async throws -> String {
        func string(_ key: String) -> String { (arguments[key] as? String ?? "").trimmed }
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
                        "meetings": counts.meetings, "notes": counts.notes] as [String: Any]
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
                                         "binder": Store.shared.binder(meeting.binderID)?.name ?? "", "notes": meeting.summary, "own_notes": meeting.userNotes]
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
            return json(todos.map { todo in
                ["id": todo.id.uuidString, "task": todo.task, "owner": todo.owner, "kind": todo.kind, "status": todo.status,
                 "due": todo.dueAt.map(AutomationPayload.iso) ?? "", "due_as_said": todo.dueText ?? "", "to": todo.to ?? "",
                 "source": todo.sourceTitle, "created": AutomationPayload.iso(todo.createdAt)] as [String: Any]
            })
        case "recent_dictations":
            let records = Store.shared.recentTranscripts(limit: integer("limit", default: 20, max: 50) * 2)
                .filter { $0.mode == "dictation" && $0.status == "inserted" && !$0.finalText.trimmed.isEmpty }
                .prefix(integer("limit", default: 20, max: 50))
            return json(records.map { record in
                ["id": record.id.uuidString, "date": AutomationPayload.iso(record.createdAt), "app": record.appName ?? "", "text": record.finalText] as [String: Any]
            })
        case "add_todo", "add_to_calendar":
            guard !string("text").isEmpty else { throw MCPCore.ToolFailure("text is required") }
            return try await handOff(name, ["text": string("text")])
        case "add_note":
            guard !string("text").isEmpty else { throw MCPCore.ToolFailure("text is required") }
            return try await handOff(name, ["text": string("text"), "binder": string("binder")])
        case "add_to_knowledge":
            guard !string("title").isEmpty, !string("text").isEmpty else { throw MCPCore.ToolFailure("title and text are required") }
            let source = string("source").isEmpty ? "" : "Source: \(string("source"))\n\n"
            return try await handOff("add_note", ["text": "\(string("title"))\n\n\(source)\(string("text"))", "binder": string("binder")])
        case "append_to_note":
            guard !string("id").isEmpty, !string("text").isEmpty else { throw MCPCore.ToolFailure("id and text are required") }
            return try await handOff(name, ["id": string("id"), "text": string("text")])
        case "create_binder":
            guard !string("name").isEmpty else { throw MCPCore.ToolFailure("name is required") }
            return try await handOff(name, ["name": string("name")])
        case "add_meeting":
            guard !string("title").isEmpty, !string("notes").isEmpty else { throw MCPCore.ToolFailure("title and notes are required") }
            let minutes = (arguments["duration_minutes"] as? Int) ?? (arguments["duration_minutes"] as? Double).map(Int.init)
            return try await handOff(name, ["title": string("title"), "notes": string("notes"), "date": string("date"), "attendees": string("attendees"),
                                            "duration_minutes": minutes.map(String.init) ?? "", "app": string("app"), "binder": string("binder")])
        case "set_todo_status":
            guard !string("id").isEmpty, !string("status").isEmpty else { throw MCPCore.ToolFailure("id and status are required") }
            return try await handOff(name, ["id": string("id"), "status": string("status")])
        default:
            throw MCPCore.ToolFailure("No tool named \(name)")
        }
    }

    /// Hands a write to the running app through the inbox and waits for its answer. The app is the only writer, so its
    /// windows update and the index picks the item up; launching it takes a few seconds if it isn't running.
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
