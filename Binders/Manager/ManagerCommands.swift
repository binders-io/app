import Foundation
import SwiftData
import BindersKit

/// The Manager's writes as the app carries them out (lane MG1): only from the Manager's run for the request running now
/// (`ManagerService.refusal`), each change kept with the request so Undo can put it back. Its own (reply, edit_task,
/// close_task, merge_tasks, propose_note_edit) are here; the shared ones it may use (`ManagerTools.writes`) go through
/// InboxCommands as anyone's do, with what they change noted before and after.
@MainActor
enum ManagerCommands {
    static let own: Set<String> = ["manager_reply", "edit_task", "close_task", "merge_tasks", "move_task", "assign_task", "delete_task",
                                   "review_proposals", "delete_note", "edit_binder", "propose_note_edit"]

    /// What a shared write changes, read before it: where moved things were, a folder's name, the folders there were.
    struct Before {
        var folders: Set<UUID>
        var places: [UUID: (folder: UUID?, title: String)] = [:]
        var folderName: (id: UUID, name: String)?
        /// A note's text before an edit.
        var noteText: (id: UUID, text: String, editedBy: String?, editedAt: Date?)?
        var binders: Set<UUID> = []
    }

    static func before(_ request: InboxRequest) -> Before {
        let store = Store.shared
        func field(_ key: String) -> String { (request.fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var before = Before(folders: Set(store.allFolders().map(\.id)))
        switch request.action {
        case "move_item":
            let ids = field("ids").isEmpty ? [field("id")] : field("ids").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for id in ids.compactMap(UUID.init(uuidString:)) {
                if let note = store.note(id) {
                    before.places[id] = (note.folderID, note.title)
                } else if let meeting = store.meeting(id) {
                    before.places[id] = (store.folderOfItem(id), meeting.title)
                } else if let folder = store.folder(id) {
                    before.places[id] = (folder.parentID, folder.name)
                }
            }
        case "rename_folder":
            if let id = UUID(uuidString: field("id")), let folder = store.folder(id) { before.folderName = (id, folder.name) }
        case "update_note", "append_to_note":
            if let id = UUID(uuidString: field("id")), let note = store.note(id) { before.noteText = (id, note.text, note.editedBy, note.editedAt) }
        case "create_binder":
            before.binders = Set(store.binders(includeArchived: true).map(\.id))
        default:
            break
        }
        return before
    }

    /// Keeps what a shared write changed with the request: the folders it made, then what it did.
    static func after(_ request: InboxRequest, result: InboxResult, before: Before, manager: ManagerService) {
        guard result.ok || !(result.items ?? []).isEmpty, let id = UUID(uuidString: request.fields["manager_request"] ?? "") else { return }
        let store = Store.shared
        // Parents before what's inside them, so Undo takes the inside ones away first.
        let made = store.allFolders().filter { !before.folders.contains($0.id) }.sorted { store.folderNames($0.id).count < store.folderNames($1.id).count }
        for folder in made {
            manager.record(ManagerChange(kind: .madeFolder, id: folder.id, line: "Made the folder “\(folder.name)”"), for: id)
        }
        switch request.action {
        case "move_item":
            let moved = result.items.map { $0.filter(\.done).compactMap { UUID(uuidString: $0.id) } } ?? result.id.flatMap(UUID.init(uuidString:)).map { [$0] } ?? []
            for item in moved {
                guard let place = before.places[item] else { continue }
                let now = store.note(item)?.folderID ?? store.folder(item)?.parentID ?? store.folderOfItem(item)
                guard now != place.folder else { continue }
                manager.record(ManagerChange(kind: .movedItem, id: item, line: "Moved “\(place.title)” to \(store.folder(now)?.name ?? "the top of its binder")",
                                             before: place.folder?.uuidString ?? ""), for: id)
            }
        case "rename_folder":
            guard let old = before.folderName, let folder = store.folder(old.id), folder.name != old.name else { return }
            manager.record(ManagerChange(kind: .renamedFolder, id: old.id, line: "Renamed the folder “\(old.name)” to “\(folder.name)”", before: old.name), for: id)
        case "create_task":
            guard let card = result.id.flatMap(UUID.init(uuidString:)) else { return }
            let title = (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.id == card })))?.first?.title ?? ""
            manager.record(ManagerChange(kind: .madeCard, id: card, line: "Made the card “\(title)”"), for: id)
        case "update_note", "append_to_note":
            guard let old = before.noteText, let note = store.note(old.id), note.text != old.text else { return }
            manager.record(ManagerChange(kind: .editedNote, id: note.id, line: request.action == "append_to_note" ? "Added to “\(note.title)”" : "Changed “\(note.title)”",
                                         before: old.editedBy ?? "", beforeDetails: old.text, beforeLinks: old.editedAt.map { [AutomationPayload.iso($0)] },
                                         snapshot: note.text), for: id)
        case "add_note":
            guard let made = result.id.flatMap(UUID.init(uuidString:)), let note = store.note(made) else { return }
            manager.record(ManagerChange(kind: .madeNote, id: made, line: "Wrote the note “\(note.title)”", snapshot: note.text), for: id)
        case "create_binder":
            guard let made = result.id.flatMap(UUID.init(uuidString:)), !before.binders.contains(made), let binder = store.binder(made) else { return }
            manager.record(ManagerChange(kind: .madeBinder, id: made, line: "Made the binder “\(binder.name)”"), for: id)
        case "distill_note":
            guard let note = UUID(uuidString: request.fields["id"] ?? "") else { return }
            manager.record(ManagerChange(kind: .distilled, id: note, line: "Distilled “\(store.note(note)?.title ?? "a note")”: its work items wait for you"), for: id)
        default:
            break
        }
    }

    /// One of its own writes.
    static func perform(_ request: InboxRequest, controller: DictationController) -> InboxResult {
        func field(_ key: String) -> String { (request.fields[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let manager = controller.manager
        let board = controller.board
        guard let id = UUID(uuidString: field("manager_request")) else { return .failure("No request") }
        let actor = BoardActor(name: field("actor"), kind: .agent)
        let why = field("why")
        func card(_ raw: String) -> TaskCard? { UUID(uuidString: raw).flatMap(board.card) }
        switch request.action {
        case "manager_reply":
            guard !field("text").isEmpty else { return .failure("text is required") }
            manager.reply(id, field("text"))
            return InboxResult(ok: true, id: id.uuidString, message: "The user has your reply.")

        case "edit_task":
            guard let card = card(field("id")) else { return .failure("No card with that id") }
            if let refusal = refusal(card, board: board, closing: false) { return .failure(refusal) }
            let title = request.fields["title"].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
            let details = request.fields["details"]
            guard title != nil || details != nil else { return .failure("Give title, details or both") }
            guard title.map({ $0 != card.title }) ?? false || details.map({ $0 != card.details }) ?? false else {
                return InboxResult(ok: true, id: card.id.uuidString, message: "“\(card.title)” already says that.")
            }
            let change = ManagerChange(kind: .editedCard, id: card.id, line: title.map { "Retitled “\(card.title)” to “\($0)”" } ?? "Rewrote the description of “\(card.title)”",
                                       before: card.title, beforeDetails: card.details)
            board.tidy(card, title: title, details: details, by: actor, line: why.isEmpty ? "Edited by the Manager." : "Edited by the Manager: \(why)")
            manager.record(change, for: id)
            return InboxResult(ok: true, id: card.id.uuidString, message: "Changed “\(card.title)”.")

        case "close_task":
            guard let card = card(field("id")) else { return .failure("No card with that id") }
            if let refusal = refusal(card, board: board, closing: true) { return .failure(refusal) }
            guard !why.isEmpty else { return .failure("why is required: it goes on the card") }
            let from = card.column
            do {
                try board.tidyMove(card, to: .done, note: "Closed by the Manager (\(actor.name)): \(why)")
            } catch {
                return .failure(error.localizedDescription)
            }
            manager.record(ManagerChange(kind: .closedCard, id: card.id, line: "Closed “\(card.title)”: \(why)", before: from.rawValue), for: id)
            return InboxResult(ok: true, id: card.id.uuidString, message: "Moved “\(card.title)” to Done.")

        case "merge_tasks":
            guard let into = card(field("into")) else { return .failure("No card with the id into gives") }
            let raw = field("ids").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { $0 != into.id.uuidString && !$0.isEmpty }
            var others: [TaskCard] = []
            for item in raw {
                guard let other = card(item) else { return .failure("No card with the id \(item)") }
                if !others.contains(where: { $0.id == other.id }) { others.append(other) }
            }
            guard !others.isEmpty else { return .failure("Give the cards that merge into it, other than it") }
            if let refusal = refusal(into, board: board, closing: false) { return .failure(refusal) }
            for other in others {
                if let refusal = refusal(other, board: board, closing: true) { return .failure(refusal) }
                guard other.binderID == into.binderID else { return .failure("“\(other.title)” is on another board: merge cards on the same one.") }
            }
            let oldDetails = into.details, oldLinks = into.links
            var details = into.details.trimmingCharacters(in: .whitespacesAndNewlines)
            var links = into.links
            for other in others {
                let words = other.details.trimmingCharacters(in: .whitespacesAndNewlines)
                details += (details.isEmpty ? "" : "\n\n") + "Merged from “\(other.title)”" + (words.isEmpty ? "." : ":\n" + words)
                for link in other.links where !links.contains(link) { links.append(link) }
            }
            board.tidy(into, details: details, links: links, by: actor,
                       line: "Merged \(others.count) card\(others.count == 1 ? "" : "s") into this one" + (why.isEmpty ? "." : ": \(why)"))
            var closed: [ManagerChange] = [], titles: [String] = []
            for other in others {
                let from = other.column
                do {
                    try board.tidyMove(other, to: .done, note: "Merged into “\(into.title)” by the Manager (\(actor.name)).")
                    closed.append(ManagerChange(kind: .closedCard, id: other.id, line: "Merged “\(other.title)”", before: from.rawValue))
                    titles.append("“\(other.title)”")
                } catch {
                    // Kept as far as it got, so Undo puts back what moved.
                    break
                }
            }
            manager.record(ManagerChange(kind: .mergedCards, id: into.id, line: "Merged \(titles.joined(separator: ", ")) into “\(into.title)”",
                                         beforeDetails: oldDetails, beforeLinks: oldLinks, merged: closed), for: id)
            return InboxResult(ok: true, id: into.id.uuidString, message: "Merged \(closed.count) of \(others.count) into “\(into.title)”.")

        case "move_task":
            guard let card = card(field("id")) else { return .failure("No card with that id") }
            guard let column = BoardColumn(loose: field("column")) else { return .failure("column is backlog, ready, in_progress, review, blocked or done") }
            guard card.column != column else { return InboxResult(ok: true, id: card.id.uuidString, message: "“\(card.title)” is in that column already.") }
            if let refusal = board.teamRefusal(.move(column), on: card, by: actor) { return .failure(refusal) }
            let from = card.column
            do {
                try board.tidyMove(card, to: column, note: "Moved by the Manager (\(actor.name))" + (why.isEmpty ? "." : ": \(why)"))
            } catch {
                return .failure(error.localizedDescription)
            }
            manager.record(ManagerChange(kind: column == .done ? .closedCard : .movedCard, id: card.id, line: "Moved “\(card.title)” to \(column.title)",
                                         before: from.rawValue), for: id)
            return InboxResult(ok: true, id: card.id.uuidString, message: "Moved “\(card.title)” to \(column.title).")

        case "assign_task":
            guard let card = card(field("id")) else { return .failure("No card with that id") }
            let to = field("to")
            let previous = card.meantFor ?? ""
            guard to != previous else { return InboxResult(ok: true, id: card.id.uuidString, message: "“\(card.title)” is meant for \(to.isEmpty ? "no one" : to) already.") }
            if to.isEmpty {
                board.assign(card, to: nil, by: .you)
                manager.record(ManagerChange(kind: .assignedCard, id: card.id, line: "Took “\(card.title)” from \(previous)", before: previous), for: id)
                return InboxResult(ok: true, id: card.id.uuidString, message: "“\(card.title)” is meant for no one now.")
            }
            let team = controller.teamBoard
            if let theirs = team.teammatesAgent(named: to), !team.agreed(to: theirs) {
                return .failure("\(to) is a teammate's agent, and Binders asks the user before their first card goes to it. Ask them to give it one themselves.")
            }
            let isAgent = AgentRegistry.shared.agent(named: to) != nil || team.teammatesAgent(named: to) != nil
            let handOff = isAgent ? board.give(card, to: to, by: .you) : nil
            if !isAgent { board.assign(card, to: to, by: .you) }
            board.note(card, text: "Given to \(to) by the Manager (\(actor.name))" + (why.isEmpty ? "." : ": \(why)"))
            manager.record(ManagerChange(kind: .assignedCard, id: card.id, line: "Gave “\(card.title)” to \(to)", before: previous), for: id)
            var said = "“\(card.title)” is meant for \(to)."
            if case .notWoken(let why)? = handOff { said += " \(to) wasn't started: \(why)" } else if isAgent { said += " Binders handed it over." }
            return InboxResult(ok: true, id: card.id.uuidString, message: said)

        case "delete_task":
            guard let card = card(field("id")) else { return .failure("No card with that id") }
            guard !why.isEmpty else { return .failure("why is required") }
            let snapshot = ManagerCardSnapshot(card).json
            let title = card.title
            if let refused = board.delete(card) { return .failure(refused) }
            manager.record(ManagerChange(kind: .deletedCard, id: card.id, line: "Deleted “\(title)”: \(why)", snapshot: snapshot), for: id)
            return InboxResult(ok: true, id: card.id.uuidString, message: "Deleted “\(title)”.")

        case "review_proposals":
            guard let note = UUID(uuidString: field("id")) else { return .failure("id must be a note id") }
            func ids(_ key: String) -> Set<UUID> { Set(field(key).split(separator: ",").compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespaces)) }) }
            let column: BoardColumn = BoardColumn(loose: field("column")) == .ready ? .ready : .backlog
            return ManagerProposals.review(note: note, action: field("action"), proposals: ids("proposals"), items: ids("items"), column: column,
                                           request: id, controller: controller)

        case "delete_note":
            guard let noteID = UUID(uuidString: field("id")), let note = Store.shared.note(noteID) else { return .failure("No note with that id") }
            guard !why.isEmpty else { return .failure("why is required") }
            if note.isTeamCopy { return .failure("“\(note.title)” is a teammate's note: only they delete it.") }
            if TeamNotes.current?.covers(note) == true || note.sharedWithTeam {
                return .failure("“\(note.title)” is shared with the team, so deleting it deletes it for everyone: the user does that themselves.")
            }
            MarkdownEditor.flushAll()
            let entry = NoteTrash.Entry(note)
            ScratchpadController.shared.noteWillBeDeleted(note)
            NotePopouts.shared.close(note.id)
            Store.shared.delete(note, keepingHistory: true)
            manager.record(ManagerChange(kind: .deletedNote, id: noteID, line: "Deleted the note “\(entry.title)”: \(why)", snapshot: ManagerNoteSnapshot(entry).json), for: id)
            return InboxResult(ok: true, id: noteID.uuidString, message: "Deleted “\(entry.title)”.")

        case "edit_binder":
            guard let binder = InboxCommands.binder(named: field("id")), !field("id").isEmpty else { return .failure("No binder with that id or name. list_binders shows them.") }
            if binder.isTeamCopy { return .failure("“\(binder.name)” is a teammate's binder: only they change it.") }
            let snapshot = ManagerBinderSnapshot(binder)
            var changed: [String] = []
            let name = field("name")
            if !name.isEmpty, name != binder.name {
                if Store.shared.binders(includeArchived: true).contains(where: { $0.id != binder.id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                    return .failure("There's a binder named “\(name)” already.")
                }
                binder.name = name
                changed.append("renamed it “\(name)”")
            }
            if let color = Int(field("color")), color != binder.colorIndex {
                guard (0..<BinderRecord.paletteSize).contains(color) else { return .failure("color is 0 to \(BinderRecord.paletteSize - 1)") }
                binder.colorIndex = color
                changed.append("changed its colour")
            }
            if !field("archived").isEmpty {
                let archive = field("archived") == "true"
                if archive, binder.isDefault { return .failure("“\(binder.name)” is the binder things go to by default, so it stays.") }
                if archive != binder.archived {
                    binder.archived = archive
                    changed.append(archive ? "archived it" : "brought it back")
                }
            }
            guard !changed.isEmpty else { return InboxResult(ok: true, id: binder.id.uuidString, message: "“\(binder.name)” is like that already.") }
            Store.shared.save()
            manager.record(ManagerChange(kind: .editedBinder, id: binder.id, line: "“\(snapshot.name)”: " + changed.joined(separator: ", "), snapshot: snapshot.json), for: id)
            return InboxResult(ok: true, id: binder.id.uuidString, message: "“\(snapshot.name)”: " + changed.joined(separator: ", ") + ".")

        case "propose_note_edit":
            guard let noteID = UUID(uuidString: field("id")), let note = Store.shared.note(noteID) else { return .failure("No note with that id") }
            if note.isTeamCopy { return .failure("“\(note.title)” is a teammate's note: suggest the change on a card for the user instead.") }
            let find = request.fields["find"], replace = request.fields["replace"], text = request.fields["text"]
            let suggestion = NoteEditSuggestion(note: note.id, noteTitle: note.title, request: id, agent: actor.name, why: String(why.prefix(500)),
                                                find: find?.isEmpty == false ? find : nil, replace: find?.isEmpty == false ? (replace ?? "") : nil,
                                                text: find?.isEmpty == false ? nil : text, base: NoteEditSuggestion.fingerprint(note.text))
            switch suggestion.applied(to: note.text) {
            case .failure(.changed):
                return .failure(suggestion.find != nil ? "That passage isn't in “\(note.title)” exactly once. Give it exactly as get_note shows it, with enough around it to be there once."
                                : "“\(note.title)” changed while you read it. Read it again with get_note.")
            case .failure(.nothing):
                return InboxResult(ok: true, id: note.id.uuidString, message: "“\(note.title)” already says that.")
            case .success:
                manager.suggest(suggestion)
                manager.record(ManagerChange(kind: .suggestedEdit, id: suggestion.id, line: "Suggested an edit to “\(note.title)”"), for: id)
                return InboxResult(ok: true, id: suggestion.id.uuidString, message: "Suggested the edit to “\(note.title)”. It waits for the user.")
            }

        default:
            return .failure("Unknown action \(request.action)")
        }
    }

    /// Why the Manager can't change this card now, or nil. It manages every board as you would, a team's too, whose moves
    /// go through the team's database, which may refuse them while it's out of reach. A card that's done stays done unless
    /// it's moved with move_task.
    static func refusal(_ card: TaskCard, board: BoardService, closing: Bool) -> String? {
        if card.column == .done { return "“\(card.title)” is done already." }
        if closing, let refusal = board.teamRefusal(.move(.done), on: card, by: BoardActor(name: "Manager", kind: .agent)) { return refusal }
        return nil
    }
}
