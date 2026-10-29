import Foundation

/// A folder inside a binder, as the rules see it: where it is and what it's called. Folders hold notes, meetings,
/// captures and other folders, as deep as people want; a folder's sharing is its binder's.
public struct FolderNode: Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Nil at the top of the binder.
    public var parentID: UUID?
    public var name: String
    /// Kept for the team database's order; lists go by name.
    public var position: Double

    public init(id: UUID = UUID(), parentID: UUID? = nil, name: String, position: Double = 0) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.position = position
    }
}

/// The rules for folders inside a binder: paths, what may move where, and names. Pure, so the Mac's windows, its MCP
/// tools and the team copy agree.
public enum FolderTree {
    /// What separates folders in a path: "DevOps/Pipelines".
    public static let separator = "/"
    public static let maxNameLength = 80

    /// A name as it's kept: spaces trimmed and collapsed, a "/" (which separates a path) as "-", at most 80 characters.
    /// Nil when nothing is left.
    public static func cleanName(_ name: String) -> String? {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let kept = String(cleaned.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? nil : kept
    }

    /// What two names are the same folder by: case and spacing don't count.
    public static func key(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: nil).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The parts of a path as someone wrote it: "DevOps / Pipelines" is ["DevOps", "Pipelines"]; "", "/" and "Top" of
    /// nothing are the top ([]). Empty parts ("DevOps//Pipelines") are skipped.
    public static func components(_ path: String) -> [String] {
        path.components(separatedBy: separator).compactMap { cleanName($0) }
    }

    /// The folders from the top of the binder down to `id`, itself last; empty for the top or a folder that isn't there.
    /// A loop in what was read (two folders each inside the other, from two Macs at once) stops before the first folder
    /// seen twice.
    public static func chain(to id: UUID?, in folders: [UUID: FolderNode]) -> [FolderNode] {
        var chain: [FolderNode] = []
        var seen = Set<UUID>()
        var next = id
        while let current = next, let node = folders[current], seen.insert(current).inserted {
            chain.append(node)
            next = node.parentID
        }
        return chain.reversed()
    }

    /// "DevOps/Pipelines"; "" at the top.
    public static func path(of id: UUID?, in folders: [UUID: FolderNode]) -> String {
        chain(to: id, in: folders).map(\.name).joined(separator: separator)
    }

    /// The same for a list of folders, untangled as they're shown (`untangled`).
    public static func path(of id: UUID?, in folders: [FolderNode]) -> String {
        path(of: id, in: index(untangled(folders)))
    }

    public static func index(_ folders: [FolderNode]) -> [UUID: FolderNode] {
        Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The folder and every folder inside it, however deep.
    public static func subtree(of id: UUID, in folders: [FolderNode]) -> Set<UUID> {
        var children: [UUID: [UUID]] = [:]
        for folder in folders { if let parent = folder.parentID { children[parent, default: []].append(folder.id) } }
        var found: Set<UUID> = [id]
        var queue = [id]
        while let next = queue.popLast() {
            for child in children[next] ?? [] where found.insert(child).inserted { queue.append(child) }
        }
        return found
    }

    /// Whether `folder` may go into `target` (nil: the top of the binder): never into itself or a folder inside it.
    public static func canMove(_ folder: UUID, into target: UUID?, in folders: [FolderNode]) -> Bool {
        guard let target else { return true }
        return !subtree(of: folder, in: folders).contains(target)
    }

    /// The folders directly in `parent` (nil: the top), by name as Finder sorts them ("Week 2" before "Week 10").
    public static func children(of parent: UUID?, in folders: [FolderNode]) -> [FolderNode] {
        sorted(folders.filter { $0.parentID == parent })
    }

    public static func sorted(_ folders: [FolderNode]) -> [FolderNode] {
        folders.sorted { a, b in
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
    }

    /// The folders as they're shown: one whose parent isn't there (a teammate's folder that hasn't arrived) is at the
    /// top, and so is one in a loop (two folders each moved into the other on two Macs at once), rather than hidden.
    public static func untangled(_ folders: [FolderNode]) -> [FolderNode] {
        let byID = index(folders)
        return folders.map { folder -> FolderNode in
            var folder = folder
            guard let parent = folder.parentID else { return folder }
            if byID[parent] == nil {
                folder.parentID = nil
                return folder
            }
            var seen: Set<UUID> = []
            var next: UUID? = parent
            while let current = next, let node = byID[current], seen.insert(current).inserted {
                if current == folder.id {
                    folder.parentID = nil
                    break
                }
                next = node.parentID
            }
            return folder
        }
    }

    /// Every folder under `parent`, parents before what's inside them, with how deep each is: for a menu or the sidebar.
    /// `excluding` leaves out those folders and everything inside them. Untangled first (`untangled`).
    public static func flattened(_ folders: [FolderNode], under parent: UUID? = nil, excluding: Set<UUID> = []) -> [(node: FolderNode, depth: Int)] {
        let placed = untangled(folders)
        var result: [(node: FolderNode, depth: Int)] = []
        var visited = Set<UUID>()
        func walk(_ parent: UUID?, depth: Int) {
            for child in children(of: parent, in: placed) where !excluding.contains(child.id) && visited.insert(child.id).inserted {
                result.append((child, depth))
                walk(child.id, depth: depth + 1)
            }
        }
        walk(parent, depth: 0)
        return result
    }

    /// A row of a binder's list drawn as a tree: a folder, or one of the items in it, with how deep it is.
    public enum OutlineRow: Hashable, Sendable {
        case folder(UUID, depth: Int)
        case item(UUID, depth: Int)

        public var depth: Int {
            switch self {
            case .folder(_, let depth), .item(_, let depth): depth
            }
        }
    }

    /// A binder's list as a tree, the way Finder and Obsidian keep one: at each level its folders by name, then the
    /// items in it in the order given (newest first, say); what's inside a folder shows under it only while it's in
    /// `open`. An item whose folder isn't there (a teammate's folder that hasn't arrived) is at the top. Untangled first.
    public static func outline(_ folders: [FolderNode], items: [(id: UUID, folder: UUID?)], open: Set<UUID>) -> [OutlineRow] {
        let placed = untangled(folders)
        let known = Set(placed.map(\.id))
        var inFolder: [UUID?: [UUID]] = [:]
        for item in items { inFolder[item.folder.flatMap { known.contains($0) ? $0 : nil }, default: []].append(item.id) }
        var rows: [OutlineRow] = []
        var visited = Set<UUID>()
        func walk(_ parent: UUID?, depth: Int) {
            for child in children(of: parent, in: placed) where visited.insert(child.id).inserted {
                rows.append(.folder(child.id, depth: depth))
                if open.contains(child.id) { walk(child.id, depth: depth + 1) }
            }
            rows += (inFolder[parent] ?? []).map { .item($0, depth: depth) }
        }
        walk(nil, depth: 0)
        return rows
    }

    /// How many of `items` (each by its folder) each folder holds, in it or in the folders inside it, however deep. An
    /// item whose folder isn't there counts for none.
    public static func counts(_ folders: [FolderNode], items: [UUID?]) -> [UUID: Int] {
        let byID = index(untangled(folders))
        var direct: [UUID: Int] = [:]
        for case let folder? in items where byID[folder] != nil { direct[folder, default: 0] += 1 }
        var counts: [UUID: Int] = [:]
        for (folder, count) in direct {
            for ancestor in chain(to: folder, in: byID) { counts[ancestor.id, default: 0] += count }
        }
        return counts
    }

    /// The folders `id` is inside, from the top down, without itself: what has to be open for it to show.
    public static func ancestors(of id: UUID?, in folders: [FolderNode]) -> [UUID] {
        chain(to: id, in: index(untangled(folders))).dropLast().map(\.id)
    }

    /// The folder at a path, each part matched ignoring case and spacing, starting in `parent` (nil: the top). Nil when
    /// a part isn't there. An empty path is `parent` itself.
    public static func resolve(_ path: [String], in folders: [FolderNode], from parent: UUID? = nil) -> UUID? {
        let found = resolvePartially(path, in: folders, from: parent)
        return found.missing.isEmpty ? found.deepest : nil
    }

    /// As far as a path goes: the deepest folder found (nil: none, so `parent`), and the names after it still to make.
    public static func resolvePartially(_ path: [String], in folders: [FolderNode], from parent: UUID? = nil) -> (deepest: UUID?, missing: [String]) {
        var current = parent
        for (index, name) in path.enumerated() {
            let wanted = key(name)
            guard let match = children(of: current, in: folders).first(where: { key($0.name) == wanted }) else {
                return (current, Array(path[index...]))
            }
            current = match.id
        }
        return (current, [])
    }
}

// MARK: - Tidy into folders

/// Finding the prefixes people put in titles to organize notes ("DevOps | Pipeline cleanup", "Social post · Launch
/// week") and offering a folder for each, so the titles no longer have to carry them.
///
/// The rule: a title's prefix is what comes before its first separator, `|` or `·` (a space on either side optional for
/// `|`, at least one for `·`), or `-`, `–` or `—` with a space on both sides, so "Follow-up" and "2026-10-02" don't
/// split. It counts when what follows has a letter or a digit, the prefix has a letter, isn't a date ("March",
/// "Oct 2", "Q3", "Week 42"), has at most 3 words and 32 characters, and has no brackets. Prefixes are the same
/// ignoring case and spacing; one that two notes or more share becomes a folder, as does one naming a folder already
/// at the top of the binder.
public enum FolderTidy {
    public static let maxWords = 3
    public static let maxCharacters = 32

    public struct Split: Equatable, Sendable {
        public let prefix: String
        public let rest: String
    }

    /// A title's prefix and what follows it, when it has one by the rule; nil otherwise.
    public static func split(_ title: String) -> Split? {
        guard let cut = cut(title) else { return nil }
        let prefix = cut.before.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard isPrefix(prefix), cut.after.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return Split(prefix: prefix, rest: cut.after)
    }

    /// The text on either side of the first separator, trimmed; nil without one.
    private static func cut(_ text: String) -> (before: String, after: String)? {
        let characters = Array(text)
        func isSpace(_ index: Int) -> Bool { characters.indices.contains(index) && characters[index].isWhitespace }
        for (index, character) in characters.enumerated() {
            let cuts: Bool
            switch character {
            case "|": cuts = true
            case "·": cuts = isSpace(index - 1) || isSpace(index + 1)
            case "-", "–", "—": cuts = isSpace(index - 1) && isSpace(index + 1)
            default: cuts = false
            }
            if cuts {
                return (String(characters[..<index]).trimmingCharacters(in: .whitespaces),
                        String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Whether the words before a separator can be a folder: a letter in them, not a date, short, no brackets.
    public static func isPrefix(_ prefix: String) -> Bool {
        let words = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= maxWords, prefix.count <= maxCharacters,
              prefix.contains(where: \.isLetter), prefix.rangeOfCharacter(from: CharacterSet(charactersIn: "[]{}")) == nil else { return false }
        return !isDate(words)
    }

    /// The key prefixes are grouped by: case and spacing don't count.
    public static func key(_ prefix: String) -> String { FolderTree.key(prefix) }

    private static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                                              "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
                                              "sept", "oct", "nov", "dec"]
    private static let weekdays: Set<String> = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mon", "tue",
                                                "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun"]
    private static let days: Set<String> = ["today", "yesterday", "tomorrow", "tonight", "week", "wk", "weekend"]
    /// Words that go with a date without making one: "Week of Oct".
    private static let neutral: Set<String> = ["of", "the", "and", "&", "to"]

    /// Every word a number, an ordinal, a month, a weekday, a day word, a quarter, a half, a fiscal year or a week, with
    /// at least one of them: "March", "Oct 2", "2 Oct 2026", "Q3", "Q3 2026", "FY26", "Week 42", "W42", "Week of Oct".
    static func isDate(_ words: [String]) -> Bool {
        var dated = false
        for word in words {
            let parts = word.lowercased().split(whereSeparator: { "-/.,'’".contains($0) }).map(String.init)
            guard !parts.isEmpty else { continue }
            for part in parts {
                if neutral.contains(part) { continue }
                guard isDatePart(part) else { return false }
                dated = true
            }
        }
        return dated
    }

    private static func isDatePart(_ part: String) -> Bool {
        if months.contains(part) || weekdays.contains(part) || days.contains(part) { return true }
        func matches(_ pattern: String) -> Bool { part.range(of: pattern, options: .regularExpression) != nil }
        // 3, 3rd, 2026, 26; Q3, H1, FY26, FY2026, W42, WK42; and a year run in, as in "Q32026".
        return matches(#"^\d+(st|nd|rd|th)?$"#) || matches(#"^q[1-4](\d{2}|\d{4})?$"#) || matches(#"^h[12](\d{2}|\d{4})?$"#)
            || matches(#"^fy\d{2,4}$"#) || matches(#"^wk?\d{1,2}$"#)
    }

    public struct Note: Equatable, Sendable {
        public let id: UUID
        public let title: String

        public init(id: UUID, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Item: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let title: String
        /// The title without its prefix.
        public let newTitle: String

        public init(id: UUID, title: String, newTitle: String) {
            self.id = id
            self.title = title
            self.newTitle = newTitle
        }
    }

    public struct Proposal: Equatable, Sendable, Identifiable {
        public var id: String { key }
        public let key: String
        /// The folder's name: the prefix as most of its notes write it, or the existing folder's.
        public let folderName: String
        /// A folder already at the top of the binder that the prefix names, which the notes go into.
        public let existingFolder: UUID?
        public let items: [Item]

        public init(key: String, folderName: String, existingFolder: UUID?, items: [Item]) {
            self.key = key
            self.folderName = folderName
            self.existingFolder = existingFolder
            self.items = items
        }
    }

    /// One folder for each prefix two notes or more share, with those notes, by folder name. `notes` in the order a
    /// tie in spelling goes to (newest first, say); `existing`, the folders at the top of the binder, which a prefix
    /// naming one goes into, a single note being enough then.
    public static func proposals(for notes: [Note], existing: [FolderNode] = []) -> [Proposal] {
        var groups: [String: [(note: Note, split: Split)]] = [:]
        var order: [String] = []
        for note in notes {
            guard let split = split(note.title) else { continue }
            let key = key(split.prefix)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append((note, split))
        }
        let tops = FolderTree.sorted(existing.filter { $0.parentID == nil })
        var proposals: [Proposal] = []
        for key in order {
            guard let group = groups[key] else { continue }
            let folder = tops.first { names(FolderTree.key($0.name), key) }
            guard group.count >= 2 || folder != nil else { continue }
            // The spelling most of its notes use; a tie goes to the one that came first.
            var counts: [String: Int] = [:]
            var spellings: [String] = []
            for entry in group {
                if counts[entry.split.prefix] == nil { spellings.append(entry.split.prefix) }
                counts[entry.split.prefix, default: 0] += 1
            }
            let most = spellings.map { counts[$0] ?? 0 }.max() ?? 0
            let spelling = spellings.first { counts[$0] == most } ?? group[0].split.prefix
            let items = group.map { Item(id: $0.note.id, title: $0.note.title, newTitle: $0.split.rest) }
            // Two prefixes naming one folder ("Social post", "Social posts") go into it together.
            if let folder, let index = proposals.firstIndex(where: { $0.existingFolder == folder.id }) {
                proposals[index] = Proposal(key: proposals[index].key, folderName: folder.name, existingFolder: folder.id,
                                            items: sortedItems(proposals[index].items + items))
                continue
            }
            proposals.append(Proposal(key: key, folderName: folder?.name ?? FolderTree.cleanName(spelling) ?? spelling,
                                      existingFolder: folder?.id, items: sortedItems(items)))
        }
        return proposals.sorted { $0.folderName.localizedStandardCompare($1.folderName) == .orderedAscending }
    }

    private static func sortedItems(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            let order = a.newTitle.localizedStandardCompare(b.newTitle)
            return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
        }
    }

    /// A folder's name and a prefix are the same, or one is the other with an "s" or "es": "Social posts" takes
    /// "Social post".
    static func names(_ folder: String, _ prefix: String) -> Bool {
        folder == prefix || folder == prefix + "s" || folder == prefix + "es" || prefix == folder + "s" || prefix == folder + "es"
    }

    /// Which of the ticked notes keep their titles: those whose new title another note already has (`taken`, by
    /// WikiLinks.key), or that two of them would share. Moved, but renamed to nothing anyone can tell apart.
    public static func keepingTitles(_ items: [Item], taken: Set<String>) -> Set<UUID> {
        var counts: [String: Int] = [:]
        for item in items { counts[WikiLinks.key(item.newTitle), default: 0] += 1 }
        return Set(items.filter { item in
            let key = WikiLinks.key(item.newTitle)
            return taken.contains(key) || (counts[key] ?? 0) > 1 || key.isEmpty
        }.map(\.id))
    }

    /// The note with its title's prefix and separator taken off its first line, its heading mark and the markup after
    /// the prefix kept: "# DevOps | **Pipeline** cleanup" is "# **Pipeline** cleanup". Nil when its title doesn't split
    /// by the rule.
    public static func removingPrefix(from text: String) -> String? {
        let firstEnd = text.firstIndex(of: "\n") ?? text.endIndex
        let line = String(text[..<firstEnd])
        guard let plain = split(MarkdownSyntax.plainTitle(line)) else { return nil }
        let marker = line.range(of: #"^[ \t]*(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+)?"#, options: .regularExpression)
            .map { String(line[$0]) } ?? ""
        let content = String(line.dropFirst(marker.count))
        // The line as written, markup and all, when its prefix is the title's; else the title's words after it.
        let rest: String
        if let raw = cut(content), key(MarkdownSyntax.plainTitle(raw.before)) == key(plain.prefix) {
            rest = raw.after
        } else {
            rest = plain.rest
        }
        return marker + rest + text[firstEnd...]
    }
}
