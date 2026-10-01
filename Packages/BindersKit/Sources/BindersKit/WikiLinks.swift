import Foundation

/// A link to a note, meeting, person or binder, written as Obsidian does: [[Title]], or [[Title|what to show]].
public struct WikiLink: Equatable, Sendable {
    public let target: String
    /// What it reads as: the part after "|", or the target.
    public let label: String
    /// The whole [[…]], in UTF-16 offsets of the text it came from.
    public let range: NSRange
}

public enum WikiLinks {
    static let pattern = try! NSRegularExpression(pattern: #"\[\[([^\[\]\|\n]+?)(?:\|([^\[\]\n]+?))?\]\]"#)

    public static func links(in text: String) -> [WikiLink] {
        let string = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            let target = string.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { return nil }
            // ![[photo.png]] shows a picture; it isn't a link to anything.
            if match.range.location > 0, string.character(at: match.range.location - 1) == 0x21, MarkdownMedia.kind(of: target) != .other { return nil }
            let alias = match.range(at: 2).location == NSNotFound ? nil : string.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            return WikiLink(target: target, label: alias.flatMap { $0.isEmpty ? nil : $0 } ?? target, range: match.range)
        }
    }

    /// Targets of `[[Name]]` and `[[Name|shown text]]`, in order, without duplicates: what the knowledge graph links.
    public static func targets(in text: String) -> [String] {
        var seen = Set<String>()
        return links(in: text).map(\.target).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Whether `text` has a link to `title`. Case and spacing don't matter.
    public static func text(_ text: String, linksTo title: String) -> Bool {
        let wanted = key(title)
        return !wanted.isEmpty && links(in: text).contains { key($0.target) == wanted }
    }

    /// The first place `text` mentions `title` in plain words, as a whole phrase and outside any [[link]]; nil if nowhere.
    public static func plainMention(of title: String, in text: String) -> NSRange? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 3 else { return nil }
        let string = text as NSString
        let linked = links(in: text).map(\.range)
        var from = 0
        while from < string.length {
            let found = string.range(of: title, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: string.length - from))
            guard found.location != NSNotFound else { return nil }
            let before = found.location > 0 ? string.substring(with: NSRange(location: found.location - 1, length: 1)) : " "
            let after = found.upperBound < string.length ? string.substring(with: NSRange(location: found.upperBound, length: 1)) : " "
            let wholeWords = !isWordCharacter(before) && !isWordCharacter(after)
            if wholeWords, !linked.contains(where: { NSIntersectionRange($0, found).length > 0 }) { return found }
            from = found.upperBound
        }
        return nil
    }

    /// `text` with its first plain mention of `title` made into a link: [[Title]], or [[Title|as written]] when the case
    /// differs. Nil when there is none.
    public static func linkingFirstMention(of title: String, in text: String) -> String? {
        guard let range = plainMention(of: title, in: text) else { return nil }
        let written = (text as NSString).substring(with: range)
        let link = written == title ? "[[\(title)]]" : "[[\(title)|\(written)]]"
        return (text as NSString).replacingCharacters(in: range, with: link)
    }

    /// When the cursor is in an unfinished link ("… see [[Laun"), the range of what's typed after the "[[", to suggest
    /// titles for. Nil elsewhere, and once a "|" starts the text to show.
    public static func partialLink(before cursor: Int, in text: String) -> NSRange? {
        let string = text as NSString
        guard cursor <= string.length else { return nil }
        let line = string.lineRange(for: NSRange(location: min(cursor, max(string.length - 1, 0)), length: 0))
        let start = min(line.location, cursor)
        let before = string.substring(with: NSRange(location: start, length: cursor - start))
        guard let open = before.range(of: "[[", options: .backwards) else { return nil }
        let typed = before[open.upperBound...]
        guard !typed.contains("]"), !typed.contains("|"), !typed.contains("[") else { return nil }
        let offset = start + (before as NSString).length - (String(typed) as NSString).length
        return NSRange(location: offset, length: cursor - offset)
    }

    /// Titles compared the way links should: case, accents and extra spaces aside.
    public static func key(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isWordCharacter(_ character: String) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}
