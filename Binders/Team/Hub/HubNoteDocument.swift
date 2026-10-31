import Foundation
import BindersAutomerge
import BindersKit

/// One linked note's Automerge document on this Mac, as the hub has it (GET /api/notes/:id/doc), kept in step with the
/// live feed's edits. Laid out as a team database's note is (NoteDocument: `text` and `props`), so it merges the same
/// way: an edit here is the splices from the document's words to the note's, as one change under this Mac's own actor,
/// which goes to the hub in a note.edit; a teammate's changes from the feed go in as they come, and both keep their words.
final class HubNoteDocument {
    let note: UUID
    private let document: NoteDocument

    /// The hub's saved document, with this Mac's changes made under `actor`.
    init(note: UUID, saved: Data, actor: UUID = UUID()) throws {
        self.note = note
        document = try NoteDocument(note: note, loading: saved, actor: actor)
    }

    var text: String { document.text }
    /// The words the hub's document started from: what the note was when the hub first made its document.
    var startingText: String { document.startingText }
    func save() -> Data { document.save() }

    /// The change that takes its words to `text`, made and applied here, in base64 as a note.edit carries it. Nil when
    /// they're the same.
    func change(to text: String, at date: Date = Date()) throws -> String? {
        let splices = TextEdits.splices(from: document.text, to: text)
        guard !splices.isEmpty else { return nil }
        let made = try document.change(splices: splices.map { NoteDocumentSplice(start: $0.start, delete: $0.delete, insert: $0.insert) },
                                       props: [:], at: date)
        return made?.bytes.base64EncodedString()
    }

    /// A note.edit's changes, in order. Ones it has change nothing; one built on a change it hasn't had waits for it, so
    /// its words don't show: the caller checks the words against the hub's and reads the document again when they differ.
    func apply(_ changes: [String]) throws {
        try document.apply(changes.compactMap { Data(base64Encoded: $0) })
    }

    /// Words written from `base` to `ours` here and from `base` to `theirs` elsewhere, merged as Automerge merges them:
    /// both keep their words. For an edit made here when the note's document wasn't (offline, or set aside on the hub
    /// meanwhile): it goes on top of the hub's document as the difference to this.
    static func merge(base: String, theirs: String, ours: String) -> String {
        if theirs == base || ours == theirs { return ours }
        if ours == base { return theirs }
        func splices(_ from: String, _ to: String) -> [NoteDocumentSplice] {
            TextEdits.splices(from: from, to: to).map { NoteDocumentSplice(start: $0.start, delete: $0.delete, insert: $0.insert) }
        }
        do {
            let root = try NoteDocument(new: UUID(), actor: UUID())
            _ = try root.change(splices: splices("", base), props: [:])
            let heads = root.heads
            let mine = try root.fork(at: heads, actor: UUID())
            let other = try root.fork(at: heads, actor: UUID())
            _ = try mine.change(splices: splices(base, ours), props: [:])
            guard let made = try other.change(splices: splices(base, theirs), props: [:]) else { return ours }
            try mine.apply([made.bytes])
            return mine.text
        } catch {
            return ours
        }
    }
}
