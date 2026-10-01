import Foundation
import Observation
import SwiftData
import BindersKit

/// Deleting a note takes one key, and Undo puts it back as it was, history and all. Notes shared with a team don't
/// come through here: deleting one removes it for everyone, so that still asks first and can't be undone.
@MainActor
@Observable
final class NoteTrash {
    static let shared = NoteTrash()

    /// A deleted note, everything it had.
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let text: String
        let binderID: UUID?
        let createdAt: Date
        let updatedAt: Date
        let digest: String
        let digestHash: String
        let status: String?
        let owner: String?
        let dueAt: Date?

        var title: String {
            let firstLine = MarkdownSyntax.plainTitle(text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")
            return firstLine.isEmpty ? "Untitled note" : String(firstLine.prefix(80))
        }

        init(_ note: NoteItem) {
            id = note.id
            text = note.text
            binderID = note.binderID
            createdAt = note.createdAt
            updatedAt = note.updatedAt
            digest = note.digest
            digestHash = note.digestHash
            status = note.status
            owner = note.owner
            dueAt = note.dueAt
        }
    }

    /// The note just deleted, while its Undo button shows.
    private(set) var last: Entry?
    /// The note Undo just put back, for the list to select.
    private(set) var restored: UUID?
    @ObservationIgnored private var hiding: Task<Void, Never>?

    func delete(_ note: NoteItem, undoManager: UndoManager?) {
        MarkdownEditor.flushAll()
        let entry = Entry(note)
        ScratchpadController.shared.noteWillBeDeleted(note)
        NotePopouts.shared.close(note.id)
        // Let the editor leave the hierarchy before the model is deleted. Its history stays until the app quits, for Undo.
        DispatchQueue.main.async { Store.shared.delete(note, keepingHistory: true) }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] trash in trash.restore(entry, undoManager: undoManager) }
        undoManager?.setActionName("Delete Note")
        last = entry
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.last == entry else { return }
            self?.last = nil
        }
    }

    /// Puts a deleted note back, with the same id, so links, history and the board still find it.
    @discardableResult
    func restore(_ entry: Entry, undoManager: UndoManager?) -> NoteItem? {
        if last == entry { last = nil }
        guard Store.shared.note(entry.id) == nil else { return nil }
        let note = NoteItem(text: entry.text)
        note.id = entry.id
        note.binderID = Store.shared.binder(entry.binderID)?.id ?? Store.shared.defaultBinder().id
        note.createdAt = entry.createdAt
        note.updatedAt = entry.updatedAt
        note.digest = entry.digest
        note.digestHash = entry.digestHash
        note.status = entry.status
        note.owner = entry.owner
        note.dueAt = entry.dueAt
        Store.shared.insert(note)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] trash in
            if let note = Store.shared.note(entry.id) { trash.delete(note, undoManager: undoManager) }
        }
        undoManager?.setActionName("Delete Note")
        restored = entry.id
        return note
    }
}
