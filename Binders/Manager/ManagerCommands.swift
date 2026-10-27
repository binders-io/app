import Foundation
import SwiftData
import BindersKit

/// The Manager's writes as the app carries them out (lane MG1): only from the Manager's run for the request running now
/// (`ManagerService.refusal`), each change kept with the request so Undo can put it back. Its own (reply, edit_task,
/// close_task, merge_tasks, propose_note_edit) are here; the shared ones it may use (`ManagerTools.writes`) go through
/// InboxCommands as anyone's do, with what they change noted before and after.
@MainActor
enum ManagerCommands {
    static let own: Set<String> = ["manager_reply", "edit_task", "close_task", "merge_tasks", "propose_note_edit"]

    /// What a shared write changes, read before it: where moved things were, a folder's name, the folders there were.
    struct Before {
        var folders: Set<UUID>
        var places: [UUID: (folder: UUID?, title: String)] = [:]
        var folderName: (id: UUID, name: String)?
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
            guard into.column == .backlog || into.column == .ready else { return .failure("“\(into.title)” isn't in Backlog or Ready.") }
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

    /// Why the Manager may not change this card, or nil. It leaves alone a card on a team's board, one an agent holds, and
    /// one waiting on you; it closes only from Backlog or Ready, and never one that other cards wait for.
    static func refusal(_ card: TaskCard, board: BoardService, closing: Bool) -> String? {
        if board.isTeams(card) { return "“\(card.title)” is on a team's board: the team tidies it." }
        if card.assigneeIsAgent, BoardRules.isClaimed(card.state, at: Date()) { return "\(card.assignee ?? "An agent") holds “\(card.title)”: leave it to them." }
        if card.column == .blocked || card.column == .review { return "“\(card.title)” waits on the user: leave it to them." }
        if closing {
            guard card.column == .backlog || card.column == .ready else { return "“\(card.title)” isn't in Backlog or Ready, so it stays open." }
            if !board.waiting(on: card).isEmpty { return "Other cards wait for “\(card.title)”, so it stays open." }
        }
        return nil
    }
}
