import Foundation

// Lane DS5: a note's cards as one group on the board (its work, the cards Distill made from it and any you put in it), and
// acting on many cards at once.

/// A board's cards grouped by the note they belong to (`DistilledFrom.groupNote`), for Group by Note: in each column the
/// cards of one note together, under a header with the note's title, how many of them are in that column and how the
/// whole group is going on this board ("4 of 9 done"). The groups come in the same order in every column, newest first
/// (by the newest card in each), so a note's cards sit at the same height across the board; cards with no note come last,
/// under "Not from a note". Within a group the cards keep the column's own order.
public enum BoardGroups {
    /// The header over cards that belong to no note.
    public static let looseTitle = "Not from a note"

    /// A card, as grouping reads it.
    public struct Card: Equatable, Sendable {
        public var id: UUID
        public var column: BoardColumn
        /// The note whose group it's in; nil for none.
        public var note: UUID?
        public var created: Date
        /// Closed by Distill again, its section gone: neither done nor open, so it counts in no group's progress.
        public var closed: Bool

        public init(id: UUID, column: BoardColumn, note: UUID?, created: Date, closed: Bool = false) {
            self.id = id
            self.column = column
            self.note = note
            self.created = created
            self.closed = closed
        }
    }

    /// How a note's work is going on this board: its cards in Done, out of all of them that are still open or done.
    public struct Progress: Equatable, Sendable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }

        /// "4 of 9 done"
        public var line: String { "\(done) of \(total) done" }
        public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    }

    /// One note's cards in one column, or the cards from no note.
    public struct Group: Equatable, Sendable, Identifiable {
        /// Nil for the cards from no note.
        public var note: UUID?
        public var title: String
        /// Its cards in this column, in the column's order.
        public var cards: [UUID]
        /// The whole group on the board; nil for the cards from no note.
        public var progress: Progress?

        public var id: String { note?.uuidString ?? "loose" }

        public init(note: UUID?, title: String, cards: [UUID], progress: Progress?) {
            self.note = note
            self.title = title
            self.cards = cards
            self.progress = progress
        }
    }

    /// The notes with cards on the board, in the order their groups come: the newest card first, then by title.
    /// `titles`: each note's title; a note not in it is named "A note".
    public static func order(_ cards: [Card], titles: [UUID: String] = [:]) -> [UUID] {
        var newest: [UUID: Date] = [:]
        for card in cards {
            guard let note = card.note else { continue }
            newest[note] = max(newest[note] ?? .distantPast, card.created)
        }
        return newest.keys.sorted { a, b in
            if newest[a] != newest[b] { return newest[a]! > newest[b]! }
            let first = title(a, titles), second = title(b, titles)
            return first != second ? first.localizedStandardCompare(second) == .orderedAscending : a.uuidString < b.uuidString
        }
    }

    /// A note's progress over every column of the board.
    public static func progress(of note: UUID, in cards: [Card]) -> Progress {
        let mine = cards.filter { $0.note == note && !$0.closed }
        return Progress(done: mine.filter { $0.column == .done }.count, total: mine.count)
    }

    /// The groups of one column: `cards` are the whole board's, in the board's order (a column's cards keep theirs). A group
    /// with no card in this column isn't there.
    public static func groups(in column: BoardColumn, cards: [Card], titles: [UUID: String] = [:]) -> [Group] {
        let here = cards.filter { $0.column == column }
        var groups: [Group] = []
        for note in order(cards, titles: titles) {
            let mine = here.filter { $0.note == note }.map(\.id)
            guard !mine.isEmpty else { continue }
            groups.append(Group(note: note, title: title(note, titles), cards: mine, progress: progress(of: note, in: cards)))
        }
        let loose = here.filter { $0.note == nil }.map(\.id)
        if !loose.isEmpty { groups.append(Group(note: nil, title: looseTitle, cards: loose, progress: nil)) }
        return groups
    }

    /// Every card of a note on the board, in every column, in the board's order: what a group header's Select All selects.
    public static func cards(of note: UUID?, in cards: [Card]) -> [UUID] {
        cards.filter { $0.note == note }.map(\.id)
    }

    /// The words a column's header says of a group: "Checkout redesign · 3 · 4 of 9 done".
    public static func spoken(_ group: Group) -> String {
        let count = group.cards.count == 1 ? "1 card here" : "\(group.cards.count) cards here"
        return [group.title, count, group.progress?.line].compactMap { $0 }.joined(separator: ", ")
    }

    private static func title(_ note: UUID, _ titles: [UUID: String]) -> String {
        let title = titles[note]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "A note" : title
    }
}

/// The cards selected on a board, as clicks change it: ⌘-click adds or takes one away, ⇧-click adds the cards between the
/// last one clicked and this one in the same column, ⌘A and a group's Select All choose a set, Esc clears it. A plain click
/// clears it and opens the card.
public struct BoardSelection: Equatable, Sendable {
    public private(set) var ids: Set<UUID> = []
    /// The last card clicked with ⌘ or ⇧, where a ⇧-click's run starts.
    public private(set) var anchor: UUID?

    public init(_ ids: Set<UUID> = []) {
        self.ids = ids
    }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// A click on a card: `column`, that column's cards in the order shown. Returns true when the click chose, false for a
    /// plain click, which clears the selection and leaves the card to open.
    @discardableResult
    public mutating func click(_ id: UUID, command: Bool, shift: Bool, column: [UUID]) -> Bool {
        if shift, let anchor, let from = column.firstIndex(of: anchor), let to = column.firstIndex(of: id) {
            ids.formUnion(column[min(from, to)...max(from, to)])
            return true
        }
        if command || shift {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
            return true
        }
        clear()
        return false
    }

    /// Exactly these, as ⌘A or a group's Select All choose them; with `adding`, these as well as what's selected.
    public mutating func select(_ chosen: [UUID], adding: Bool = false) {
        ids = adding ? ids.union(chosen) : Set(chosen)
        anchor = chosen.first
    }

    public mutating func clear() {
        ids = []
        anchor = nil
    }

    /// Only those still on the board: one deleted, or moved to another board, leaves the selection.
    public mutating func keep(_ present: Set<UUID>) {
        ids.formIntersection(present)
        if let anchor, !present.contains(anchor) { self.anchor = nil }
    }
}

/// What acting on many cards at once says: what it did, and which cards stayed as they were and why, a line for each
/// reason, as the several-notes panel says what stays.
public enum BoardBulkWords {
    /// Why a card stayed as it was.
    public enum Stay: Hashable, Sendable {
        /// An agent (or a person) has it now, and the change would take it from under them.
        case working(String)
        /// It's done, so it isn't given to anyone.
        case done
        /// Distill made it from this note: it's that note's work, so it stays in its group.
        case distilled(String)
        /// It was put on the board from this note (Put on Board, lane DS6): it's that note's work, so it stays in its group.
        case put(String)
        /// The rules said no, in their words (a team database out of reach, a card that waits for others…).
        case refused(String)
    }

    /// "1 card", "5 cards"
    public static func cards(_ count: Int) -> String { count == 1 ? "1 card" : "\(count) cards" }

    /// "5 cards selected"
    public static func selected(_ count: Int) -> String { cards(count) + " selected" }

    /// "1 stayed: Claude Code is working on it." for each reason, in the order first met.
    public static func stayed(_ stays: [Stay]) -> String? {
        guard !stays.isEmpty else { return nil }
        var order: [Stay] = []
        var counts: [Stay: Int] = [:]
        for stay in stays {
            if counts[stay] == nil { order.append(stay) }
            counts[stay, default: 0] += 1
        }
        return order.map { stay in
            let count = counts[stay] ?? 1
            let one = count == 1
            let why: String
            switch stay {
            case .working(let who): why = "\(who) is working on \(one ? "it" : "them")."
            case .done: why = one ? "it's done." : "they're done."
            case .distilled(let note): why = "Distill made \(one ? "it" : "them") from “\(note)”, so \(one ? "it stays" : "they stay") in that note's group."
            case .put(let note): why = "\(one ? "it was" : "they were") put on the board from “\(note)”, so \(one ? "it stays" : "they stay") in that note's group."
            case .refused(let reason):
                let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                why = reason.hasSuffix(".") ? reason : reason + "."
            }
            return "\(count) stayed: \(why)"
        }.joined(separator: " ")
    }

    /// "Moved 5 cards to In Progress." and why any stayed; `already`: cards that were in that column already.
    public static func moved(_ count: Int, to column: BoardColumn, already: Int = 0, stays: [Stay] = []) -> String {
        var parts: [String] = []
        if count > 0 { parts.append("Moved \(cards(count)) to \(column.title).") }
        if already > 0 { parts.append(already == 1 ? "1 was in \(column.title) already." : "\(already) were in \(column.title) already.") }
        if let stayed = stayed(stays) { parts.append(stayed) }
        return parts.isEmpty ? "Nothing moved." : parts.joined(separator: " ")
    }

    /// "Gave 5 cards to Claude Code.", "5 cards are for Sam now.", "5 cards are for anyone now.", and why any stayed.
    public static func assigned(_ count: Int, to name: String?, agent: Bool, stays: [Stay] = []) -> String {
        var parts: [String] = []
        if count > 0 {
            if let name, agent {
                parts.append("Gave \(cards(count)) to \(name).")
            } else {
                let are = count == 1 ? "1 card is" : "\(count) cards are"
                parts.append("\(are) for \(name.map { $0 == "You" ? "you" : $0 } ?? "anyone") now.")
            }
        }
        if let stayed = stayed(stays) { parts.append(stayed) }
        return parts.isEmpty ? "Nothing changed." : parts.joined(separator: " ")
    }

    /// After giving several to an agent, the ones it wasn't woken for, a line for each reason in the hand-off's own words:
    /// "2 weren't handed over yet: Agents are paused."
    public static func notHandedOver(_ reasons: [String]) -> String? {
        guard !reasons.isEmpty else { return nil }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for reason in reasons {
            if counts[reason] == nil { order.append(reason) }
            counts[reason, default: 0] += 1
        }
        return order.map { reason in
            let count = counts[reason] ?? 1
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(count) \(count == 1 ? "wasn't" : "weren't") handed over yet: " + (trimmed.hasSuffix(".") ? trimmed : trimmed + ".")
        }.joined(separator: " ")
    }

    /// "Deleted 5 cards.", and why any stayed.
    public static func deleted(_ count: Int, stays: [Stay] = []) -> String {
        var parts: [String] = []
        if count > 0 { parts.append("Deleted \(cards(count)).") }
        if let stayed = stayed(stays) { parts.append(stayed) }
        return parts.isEmpty ? "Nothing was deleted." : parts.joined(separator: " ")
    }

    /// "Put 5 cards in “Checkout redesign”." or "Took 5 cards out of their notes' groups.", and why any stayed.
    public static func grouped(_ count: Int, into note: String?, stays: [Stay] = []) -> String {
        var parts: [String] = []
        if count > 0 {
            if let note {
                parts.append("Put \(cards(count)) in “\(note)”.")
            } else {
                parts.append("Took \(cards(count)) out of \(count == 1 ? "its note's group" : "their notes' groups").")
            }
        }
        if let stayed = stayed(stays) { parts.append(stayed) }
        return parts.isEmpty ? "Nothing changed." : parts.joined(separator: " ")
    }

    /// The one question before deleting several: "Delete 5 cards?", with what Undo can and can't put back. `shared`: how
    /// many are on a board shared through the team database, which go for everyone.
    public static func deleteQuestion(_ count: Int) -> String { "Delete \(cards(count))?" }

    public static func deleteMessage(_ count: Int, shared: Int) -> String {
        if shared == 0 { return "You can undo this." }
        let them = shared == count ? (count == 1 ? "It's on the team's board" : "They're on the team's board")
            : shared == 1 ? "1 of them is on the team's board" : "\(shared) of them are on the team's board"
        let mine = count - shared
        return them + ": " + (shared == 1 ? "it's" : "they're") + " deleted for everyone, which can't be undone."
            + (mine == 0 ? "" : mine == 1 ? " Undo puts the other one back." : " Undo puts the other \(mine) back.")
    }

    /// The one question before giving several to an agent: "Give 5 cards to Claude Code?"
    public static func giveQuestion(_ count: Int, to agent: String) -> String { "Give \(cards(count)) to \(agent)?" }

    public static func giveMessage(_ count: Int, to agent: String) -> String {
        "\(count == 1 ? "It goes" : "Each goes") to Ready and \(agent) is woken for \(count == 1 ? "it" : "each") now, as Give to does, with a receipt on "
            + "\(count == 1 ? "the card" : "every card"). Undo puts back who \(count == 1 ? "it was" : "they were") for, but can't call back a run that started."
    }
}
