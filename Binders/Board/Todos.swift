import Foundation
import SwiftData
import BindersKit

/// A to-do wherever it lives: a promise, or a checklist item in a meeting's notes, a note or a note's digest.
struct TodoItem {
    /// As list_todos gives it: a promise's id, or where a checklist item is and a fingerprint of its words.
    let id: String
    let text: String
    let owner: String?
    let done: Bool
    let due: Date?
    let binderID: UUID?
    /// "meeting", "note" or "commitment", with the item it came from.
    let sourceKind: String
    let sourceID: UUID
    let sourceTitle: String
}

/// Finds to-dos by id and ticks them where they live, for the to-do lists, the boards and the MCP tools alike.
@MainActor
enum Todos {
    /// The to-do with this id, as it reads now. Nil when it has changed or is gone.
    static func find(_ id: String) -> TodoItem? {
        let context = Store.shared.context
        if let reference = BoardTaskReference(id) {
            let wanted = reference.id
            /// In a teammate's meeting or note, their "You" is them.
            func owner(_ line: TaskLine, _ author: String?) -> String? {
                NotesEditing.owner(line.owner, author: author, reader: TeamSyncService.myName)
            }
            func task(in markdown: String) -> TaskLine? {
                markdown.components(separatedBy: "\n").lazy.compactMap(NotesEditing.task(from:))
                    .first { NotesEditing.fingerprint($0.text) == reference.fingerprint }
            }
            switch reference.place {
            case .meeting:
                guard let meeting = (try? context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == wanted })))?.first,
                      let line = task(in: meeting.summary) else { return nil }
                return TodoItem(id: id, text: line.text, owner: owner(line, meeting.isTeamCopy ? meeting.teamAuthorName : nil), done: line.done,
                                due: nil, binderID: meeting.binderID, sourceKind: "meeting", sourceID: meeting.id, sourceTitle: meeting.title)
            case .digest, .note:
                guard let note = (try? context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == wanted })))?.first,
                      let line = task(in: reference.place == .digest ? note.digest : note.text) else { return nil }
                return TodoItem(id: id, text: line.text, owner: owner(line, note.isTeamCopy ? note.teamAuthorName : nil), done: line.done,
                                due: nil, binderID: note.binderID, sourceKind: "note", sourceID: note.id, sourceTitle: note.title)
            }
        }
        guard let uuid = UUID(uuidString: id), let record = Store.shared.commitments().first(where: { $0.id == uuid }) else { return nil }
        return TodoItem(id: id, text: record.task, owner: record.owner, done: record.status == "done", due: record.dueAt, binderID: record.binderID,
                        sourceKind: "commitment", sourceID: record.sourceWritingID ?? record.id, sourceTitle: record.sourceTitle)
    }

    /// Ticks the to-do off, or opens it again, where it lives. Returns its words; nil when it has changed or is gone.
    @discardableResult
    static func setDone(_ id: String, _ done: Bool, commitments: CommitmentService?) -> String? {
        MarkdownEditor.flushAll()
        let store = Store.shared
        guard let reference = BoardTaskReference(id) else {
            guard let uuid = UUID(uuidString: id), let record = store.commitments().first(where: { $0.id == uuid }) else { return nil }
            if let commitments {
                commitments.setStatus(record, done ? "done" : "open")
            } else {
                record.status = done ? "done" : "open"
                record.doneAt = done ? Date() : nil
                store.save()
            }
            return record.task
        }
        let wanted = reference.id
        let found: (markdown: String, task: TaskLine)
        switch reference.place {
        case .meeting:
            guard let meeting = (try? store.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == wanted })))?.first,
                  let result = NotesEditing.setTask(fingerprint: reference.fingerprint, done: done, in: meeting.summary) else { return nil }
            meeting.summary = result.markdown
            found = result
        case .digest:
            guard let note = (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == wanted })))?.first,
                  let result = NotesEditing.setTask(fingerprint: reference.fingerprint, done: done, in: note.digest) else { return nil }
            note.digest = result.markdown
            found = result
        case .note:
            guard let note = (try? store.context.fetch(FetchDescriptor<NoteItem>(predicate: #Predicate { $0.id == wanted })))?.first,
                  let result = NotesEditing.setTask(fingerprint: reference.fingerprint, done: done, in: note.text) else { return nil }
            NoteHistory.willChange(note, to: result.markdown)
            note.text = result.markdown
            note.updatedAt = Date()
            found = result
        }
        store.save()
        return found.task.text
    }
}
