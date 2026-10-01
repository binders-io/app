import Foundation
import BindersKit

/// Each note's #tags, found again only when its text changes: the notes list and filter show every note's tags and
/// redraw whenever a note changes.
@MainActor
enum NoteTagCache {
    private static var cache: [UUID: (hash: Int, tags: [String])] = [:]

    static func tags(of note: NoteItem) -> [String] {
        let text = note.text
        let hash = text.hashValue
        if let hit = cache[note.id], hit.hash == hash { return hit.tags }
        let tags = NoteTags.tags(in: text)
        cache[note.id] = (hash, tags)
        return tags
    }
}
