import AppKit
import SwiftData
import BindersKit

/// The writes that arrive through the inbox (see `Inbox` in BindersKit): notes, binders, meetings from elsewhere, to-dos.
@MainActor
enum InboxCommands {
    static var directory: URL { AppPaths.support.appendingPathComponent(Inbox.folder, isDirectory: true) }

    /// binders://apply?file=<name>: performs the request and leaves the result beside it.
    static func apply(named name: String, controller: DictationController) async {
        guard Inbox.isValidName(name) else {
            Log.app.error("Inbox: request name is not a UUID")
            return
        }
        let requestURL = directory.appendingPathComponent(Inbox.requestFile(name))
        let resultURL = directory.appendingPathComponent(Inbox.resultFile(name))
        let result: InboxResult
        if let data = try? Data(contentsOf: requestURL), let request = try? JSONDecoder().decode(InboxRequest.self, from: data) {
            result = await perform(request, controller: controller)
        } else {
            result = .failure("Couldn't read the request")
        }
        try? JSONEncoder().encode(result).write(to: resultURL, options: .atomic)
        try? FileManager.default.removeItem(at: requestURL)
    }

    static func perform(_ request: InboxRequest, controller: DictationController) async -> InboxResult {
        func field(_ key: String) -> String { (request.fields[key] ?? "").trimmed }
        let store = Store.shared
        switch request.action {
        case "add_note":
            let text = field("text")
            guard !text.isEmpty else { return .failure("text is required") }
            guard let binder = binder(named: field("binder")) else { return .failure(noBinder(field("binder"))) }
            let note = NoteItem(text: text)
            note.binderID = binder.id
            note.sharedWithTeam = binder.sharedWithTeam
            store.insert(note)
            return InboxResult(ok: true, id: note.id.uuidString, message: "Note “\(note.title)” added to \(binder.name)")

        case "append_to_note":
            guard let id = UUID(uuidString: field("id")) else { return .failure("id must be a note id") }
            let text = field("text")
            guard !text.isEmpty else { return .failure("text is required") }
            guard let note = (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == id })))?.first else {
                return .failure("No note with that id")
            }
            note.text = note.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + text
            note.updatedAt = Date()
            store.save()
            return InboxResult(ok: true, id: note.id.uuidString, message: "Appended to “\(note.title)”")

        case "create_binder":
            let name = field("name")
            guard !name.isEmpty else { return .failure("name is required") }
            let all = store.binders(includeArchived: true)
            if let existing = all.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return InboxResult(ok: true, id: existing.id.uuidString, message: "Binder “\(existing.name)” already exists")
            }
            let used = Set(all.map(\.colorIndex))
            let binder = BinderRecord(name: name, colorIndex: (0..<BinderRecord.paletteSize).first { !used.contains($0) } ?? all.count % BinderRecord.paletteSize)
            store.insert(binder)
            return InboxResult(ok: true, id: binder.id.uuidString, message: "Binder “\(name)” created")

        case "add_meeting":
            let title = field("title"), notes = field("notes")
            guard !title.isEmpty, !notes.isEmpty else { return .failure("title and notes are required") }
            guard let binder = binder(named: field("binder")) else { return .failure(noBinder(field("binder"))) }
            let record = MeetingRecord(title: title, appName: field("app").isEmpty ? "Imported" : field("app"), templateID: AppSettings.shared.meetingTemplateID)
            let date = parseDate(field("date")) ?? Date()
            record.createdAt = date
            record.duration = Double(max(0, Int(field("duration_minutes")) ?? 0) * 60)
            record.endedAt = date.addingTimeInterval(record.duration)
            record.attendees = field("attendees").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            record.summary = notes
            record.status = "ready"
            record.binderID = binder.id
            record.sharedWithTeam = binder.sharedWithTeam
            store.insert(record)
            return InboxResult(ok: true, id: record.id.uuidString, message: "Meeting “\(title)” added to \(binder.name)")

        case "set_todo_status":
            let status = field("status").lowercased()
            guard ["open", "done", "dismissed"].contains(status) else { return .failure("status must be open, done or dismissed") }
            if let reference = BoardTaskReference(field("id")) {
                guard status != "dismissed" else { return .failure("Only promises can be dismissed. Mark this one done instead.") }
                return setTask(reference, done: status == "done")
            }
            guard let id = UUID(uuidString: field("id")) else { return .failure("id must be a to-do id from list_todos") }
            guard let todo = store.commitments().first(where: { $0.id == id }) else { return .failure("No to-do with that id") }
            controller.commitments.setStatus(todo, status)
            return InboxResult(ok: true, id: todo.id.uuidString, message: "“\(todo.task)” is now \(status)")

        case "add_todo":
            let text = field("text")
            guard !text.isEmpty else { return .failure("text is required") }
            // Into the named binder, when one is given; otherwise the current one.
            if !field("binder").isEmpty, binder(named: field("binder")) == nil { return .failure(noBinder(field("binder"))) }
            let added = controller.commitments.addSpoken(text)
            if !field("binder").isEmpty, let target = binder(named: field("binder")) {
                added.commitment.binderID = target.id
                store.save()
            }
            return InboxResult(ok: true, id: added.commitment.id.uuidString, message: added.line)

        case "create_task", "claim_task", "update_task", "ask_on_task", "comment_task", "release_task", "complete_task":
            return boardAction(request.action, field: field, controller: controller)

        case "add_to_calendar":
            let text = field("text")
            guard !text.isEmpty else { return .failure("text is required") }
            let result = await controller.addToCalendar(described: text)
            return result.added ? InboxResult(ok: true, message: result.line) : .failure(result.line)

        default:
            return .failure("Unknown action \(request.action)")
        }
    }

    /// Ticks or unticks a checklist item in a meeting's notes, a note's digest or a note, found by its words.
    private static func setTask(_ reference: BoardTaskReference, done: Bool) -> InboxResult {
        guard let text = Todos.setDone(reference.string, done, commitments: nil) else { return .failure(todoGone) }
        return InboxResult(ok: true, id: reference.string, message: "“\(text)” is now \(done ? "done" : "open")")
    }

    private static let todoGone = "That to-do has changed or is gone. list_todos has the current ones."

    /// A change to a card, by the actor named in the request (an agent over MCP, or you from the phone).
    private static func boardAction(_ action: String, field: (String) -> String, controller: DictationController) -> InboxResult {
        let board = controller.board
        let actor = BoardActor(name: field("actor").isEmpty ? "AI agent" : field("actor"),
                               kind: BoardActor.Kind(rawValue: field("actor_kind")) ?? .agent)
        if action == "create_task" {
            let column: BoardColumn = BoardColumn(loose: field("column")) == .ready ? .ready : .backlog
            if !field("todo").isEmpty {
                // A card for a to-do goes to the to-do's binder unless another is named, and stays linked to it.
                guard let todo = Todos.find(field("todo")) else { return .failure(todoGone) }
                if !field("binder").isEmpty, binder(named: field("binder")) == nil { return .failure(noBinder(field("binder"))) }
                let target = field("binder").isEmpty ? nil : binder(named: field("binder"))?.id
                let made = board.create(from: todo, column: column, binderID: target, title: field("title").isEmpty ? nil : field("title"),
                                        details: field("details"), by: actor)
                let name = Store.shared.binder(made.card.binderID)?.name ?? "binder's"
                return InboxResult(ok: true, id: made.card.id.uuidString, message: made.existed
                    ? "That to-do is already on the \(name) board as “\(made.card.title)”, in \(made.card.column.title)."
                    : "Card “\(made.card.title)” added to the \(name) board, in \(made.card.column.title). The to-do is ticked off when the card is done.")
            }
            guard !field("title").isEmpty else { return .failure("title is required") }
            guard let target = binder(named: field("binder")) else { return .failure(noBinder(field("binder"))) }
            let card = board.create(title: field("title"), details: field("details"), binderID: target.id, column: column, by: actor)
            return InboxResult(ok: true, id: card.id.uuidString, message: "Card “\(card.title)” added to the \(target.name) board, in \(card.column.title)")
        }
        guard let id = UUID(uuidString: field("id")), let card = board.card(id) else {
            return .failure("No card with that id. list_tasks shows them.")
        }
        do {
            switch action {
            case "claim_task":
                try board.claim(card, by: actor)
                let until = card.claimExpiresAt.map { " until \($0.formatted(date: .omitted, time: .shortened)); every update extends it" } ?? ""
                return InboxResult(ok: true, id: card.id.uuidString, message: "“\(card.title)” is yours\(until). It's \(card.column.title).")
            case "update_task":
                if let column = BoardColumn(loose: field("column")) { try board.move(card, to: column, by: actor) }
                if !field("progress").isEmpty || !field("links").isEmpty {
                    let links = field("links").split(whereSeparator: { $0 == "\n" || $0 == "," }).map(String.init)
                    board.report(card, progress: field("progress"), links: links, by: actor)
                }
                return InboxResult(ok: true, id: card.id.uuidString, message: "Updated “\(card.title)”. It's \(card.column.title).")
            case "ask_on_task":
                try board.ask(card, question: field("text"), by: actor)
                return InboxResult(ok: true, id: card.id.uuidString, message: "Asked. “\(card.title)” waits in Blocked until the user answers; get_task shows the answer.")
            case "comment_task":
                board.comment(card, text: field("text"), by: actor)
                return InboxResult(ok: true, id: card.id.uuidString, message: "Comment added to “\(card.title)”.")
            case "release_task":
                try board.release(card, note: field("text"), by: actor)
                return InboxResult(ok: true, id: card.id.uuidString, message: "Released “\(card.title)”. It's back in \(card.column.title).")
            case "complete_task":
                try board.complete(card, summary: field("text"), by: actor)
                return InboxResult(ok: true, id: card.id.uuidString,
                                   message: card.column == .done ? "“\(card.title)” is done." : "“\(card.title)” is in Review for the user to check.")
            default:
                return .failure("Unknown action \(action)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// The named binder, or the current one when no name is given. Nil when a name is given and nothing matches.
    private static func binder(named name: String) -> BinderRecord? {
        guard !name.isEmpty else { return Store.shared.binder(AppSettings.shared.currentBinderID) ?? Store.shared.defaultBinder() }
        return Store.shared.binders(includeArchived: true).first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private static func noBinder(_ name: String) -> String {
        "No binder named “\(name)”. list_binders shows the names; create_binder makes a new one."
    }

    private static func parseDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
