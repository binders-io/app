import Foundation

/// Distill again, after the note changed: what's read now compared with the items from before, by the section each came
/// from. New sections get new items; a section whose text changed since its cards were made gets its cards' briefs to
/// update and new items for what's new in it; a section that's the same gets nothing, unless the last reading held items
/// back from it (`Earlier.heldBack`); a card whose section is gone is offered to close. The same item is never made twice,
/// nor one much like an item from before anywhere in the note (`alike`, lane BF2): a model words the same work a little
/// differently each time it reads.
public enum DistillAgain {
    /// An item from before, as the comparison reads it: its section and that section's version, its title, and its card
    /// when it's on the board.
    public struct Earlier: Equatable, Sendable {
        public var item: UUID
        public var title: String
        public var section: String?
        public var sectionHash: String?
        public var card: UUID?
        /// The card is Done, or closed: nothing to update on it.
        public var finished: Bool
        /// It came from the latest reading with items, and that reading left items out past its count (0.11.0 kept a long
        /// note's first 25): its section, though the same, still has items to offer.
        public var heldBack: Bool
        /// Its brief and the note's words it came from, for telling a repeat in other words (`alike`).
        public var brief: String?
        public var quote: String?
        /// Still waiting for review in a proposal (no card yet): what's new in its changed section brings it up to date
        /// (`Plan.refreshes`) rather than proposing it again.
        public var waiting: Bool
        /// Not one of Distill's items: a card made from the note some other way (put in its group by hand, Put on Board,
        /// an agent's create_task with the note). A repeat of it is left out, but it says nothing of how its section stands,
        /// and it's never brought up to date or closed.
        public var other: Bool
        /// It came from a reading of the whole note: Binders' model's, or an agent's answering "Distill with…". False for an
        /// agent's own proposal of what it picked out, which says nothing of the rest of its section: a repeat of it is
        /// left out, and the section is still read.
        public var whole: Bool

        public init(item: UUID, title: String, section: String?, sectionHash: String?, card: UUID?, finished: Bool = false,
                    heldBack: Bool = false, brief: String? = nil, quote: String? = nil, waiting: Bool = false, other: Bool = false,
                    whole: Bool = true) {
            self.item = item
            self.title = title
            self.section = section
            self.sectionHash = sectionHash
            self.card = card
            self.finished = finished
            self.heldBack = heldBack
            self.brief = brief
            self.quote = quote
            self.waiting = waiting
            self.other = other
            self.whole = whole
        }
    }

    /// An item still waiting for review whose section changed, brought up to date by what the note now says (Distill
    /// again), in place of a new item much like it.
    public struct Refresh: Equatable, Sendable {
        public var item: UUID
        public var brief: String
        public var doneWhen: String
        public var quote: String?
        public var sectionHash: String?
        public var briefPending: Bool?
    }

    /// How a section stands against the items from before.
    public enum SectionState: Equatable, Sendable {
        case new, changed, same
    }

    public struct Plan: Equatable, Sendable {
        /// Items to propose, in the reader's order, with their waits on each other kept.
        public var items: [DistillItem]
        /// Cards whose section changed: a new brief from the item that matches them best.
        public var updates: [DistillUpdate]
        /// Cards whose section is gone.
        public var closes: [DistillUpdate]
        /// Items still waiting for review whose section changed, brought up to date.
        public var refreshes: [Refresh] = []
        /// Items left out as the same as one from before, or from a section that's the same.
        public var leftOut: Int
        /// Each section of the note now, by title, and how it stands.
        public var sections: [String: SectionState]
    }

    /// The plan: `read` is what the reader proposed now (each with its section's hash as now), `earlier` every item from
    /// before (placed, still proposed or put aside, and dropped ones, which are never proposed again) and the note's other
    /// cards (`Earlier.other`), `sections` the note's sections now.
    public static func plan(read: [DistillItem], earlier: [Earlier], sections: [DistillSections.Section]) -> Plan {
        var states: [String: SectionState] = [:]
        // Cards made from the note some other way, and an agent's pick of items, say nothing of how a section stands: Put
        // on Board from one line of a section never makes the rest of it "the same".
        let distilled = earlier.filter { !$0.other && $0.whole }
        for section in sections {
            let before = distilled.filter { $0.section == section.heading }
            if before.isEmpty {
                states[section.title] = .new
            } else if before.allSatisfy({ $0.sectionHash == section.hash }) {
                states[section.title] = .same
            } else {
                states[section.title] = .changed
            }
        }
        let now = Dictionary(sections.map { ($0.heading ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        var keep: [DistillItem] = []
        var updates: [DistillUpdate] = []
        var refreshes: [Refresh] = []
        var leftOut = 0
        var matched: Set<UUID> = []
        /// Brings the card, or the waiting item, `earlier` stands for up to date with `item`; false when it's neither.
        func update(_ earlier: Earlier, with item: DistillItem, section: DistillSections.Section?) -> Bool {
            guard !earlier.other, !matched.contains(earlier.item) else { return false }
            if let card = earlier.card, !earlier.finished {
                matched.insert(earlier.item)
                updates.append(DistillUpdate(kind: .brief, card: card, item: earlier.item, section: item.section, sectionHash: section?.hash,
                                             brief: item.brief, doneWhen: item.doneWhen, quote: item.quote))
                return true
            }
            if earlier.waiting, earlier.card == nil {
                matched.insert(earlier.item)
                refreshes.append(Refresh(item: earlier.item, brief: item.brief, doneWhen: item.doneWhen, quote: item.quote ?? earlier.quote,
                                         sectionHash: section?.hash, briefPending: item.briefPending))
                return true
            }
            return false
        }
        for item in read {
            let section = sections.first { $0.heading == item.section }
            let state = section.map { states[$0.title] ?? .new } ?? .new
            let before = earlier.filter { $0.section == item.section }
            // Never the same item twice: one with the title of an item from before in the same section.
            if let same = before.first(where: { similarity($0.title, item.title) >= 0.99 }) {
                if state == .changed { _ = update(same, with: item, section: section) }
                leftOut += 1
                continue
            }
            // Lane BF2: much like an item from before anywhere in the note, or one kept already now, it's a repeat in other
            // words. A changed section's card it matches best is brought up to date below instead.
            let repeated = earlier.contains { alike(item, $0) } || keep.contains { alike(item, $0) }
            if repeated, state != .changed {
                leftOut += 1
                continue
            }
            switch state {
            case .same:
                // A section the last reading cut short offers what was held back.
                if before.contains(where: \.heldBack) {
                    keep.append(item)
                } else {
                    leftOut += 1
                }
            case .new:
                keep.append(item)
            case .changed:
                // What's new in a changed section: an update for the card, or the item still waiting, it matches best; else
                // a new item.
                if let best = before.filter({ !matched.contains($0.item) && !$0.other && (($0.card != nil && !$0.finished) || ($0.waiting && $0.card == nil)) })
                    .map({ ($0, similarity($0.title, item.title)) }).filter({ $0.1 >= 0.5 }).max(by: { $0.1 < $1.1 })?.0,
                   update(best, with: item, section: section) {
                    leftOut += best.card == nil ? 1 : 0
                } else if repeated {
                    leftOut += 1
                } else {
                    keep.append(item)
                }
            }
        }
        // Cards whose section is gone: offered to close.
        var closes: [DistillUpdate] = []
        for item in earlier where item.card != nil && !item.finished && !item.other {
            let gone = item.section.map { now[$0] == nil } ?? (now[""] == nil && item.sectionHash != nil)
            if gone, let card = item.card {
                closes.append(DistillUpdate(kind: .close, card: card, item: item.item, section: item.section))
            }
        }
        // Waits on items that were left out go with them.
        let kept = Set(keep.map(\.id))
        keep = keep.map { item in
            var item = item
            item.waitsFor = item.waitsFor.filter(kept.contains)
            return item
        }
        return Plan(items: keep, updates: updates, closes: closes, refreshes: refreshes, leftOut: leftOut, sections: states)
    }

    /// An agent's own proposal for a note distilled before: everything it proposes, but an item the same as one from
    /// before in the same section, which is never made twice, or much like one from before anywhere in the note, by any
    /// reader, or like one it kept already (`alike`, as `plan` leaves out). It offers no updates or closes: those come from
    /// reading the note again (`plan`).
    public static func additions(read: [DistillItem], earlier: [Earlier]) -> (items: [DistillItem], leftOut: Int) {
        var keep: [DistillItem] = []
        for item in read {
            let same = earlier.contains { $0.section == item.section && similarity($0.title, item.title) >= 0.99 }
            guard !same, !earlier.contains(where: { alike(item, $0) }), !keep.contains(where: { alike(item, $0) }) else { continue }
            keep.append(item)
        }
        let kept = Set(keep.map(\.id))
        return (keep.map { item in
            var item = item
            item.waitsFor = item.waitsFor.filter(kept.contains)
            return item
        }, read.count - keep.count)
    }

    /// Whether two items are the same work in other words: titles nearly the same; titles much alike with briefs alike
    /// too; or the same words of the note quoted, with titles a little alike. Words are compared without their endings
    /// ("limiting", "limits" and "limit" are one word, and so are "monthly" and "month"), so "Rate-limit the login endpoint" is "Add login rate limiting",
    /// while "Write tests for login" and "Write tests for signup", whose briefs differ, stay two items.
    public static func alike(_ a: (title: String, brief: String?, quote: String?), _ b: (title: String, brief: String?, quote: String?)) -> Bool {
        let titles = closeness(a.title, b.title)
        if titles >= 0.75 { return true }
        if titles >= 0.5, let one = a.brief, let two = b.brief, !one.isEmpty, !two.isEmpty, closeness(one, two) >= 0.4 { return true }
        func plain(_ quote: String?) -> String? {
            quote.map { LoopGuard.normalize($0).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ") }
        }
        if titles >= 0.3, let one = plain(a.quote), let two = plain(b.quote), !two.isEmpty,
           one.split(separator: " ").count >= 4, one == two || (one.count >= 30 && (one.contains(two) || two.contains(one))) {
            return true
        }
        return false
    }

    static func alike(_ item: DistillItem, _ earlier: Earlier) -> Bool {
        alike((item.title, item.brief, item.quote), (earlier.title, earlier.brief, earlier.quote))
    }

    static func alike(_ item: DistillItem, _ other: DistillItem) -> Bool {
        alike((item.title, item.brief, item.quote), (other.title, other.brief, other.quote))
    }

    /// Like `similarity`, with words' endings taken off.
    static func closeness(_ a: String, _ b: String) -> Double {
        let small: Set<String> = ["the", "a", "an", "to", "of", "for", "and", "in", "on", "with", "it", "its", "is", "be", "this", "that", "so", "as", "by", "or"]
        func stem(_ word: String) -> String {
            for ending in ["ing", "ly", "ed", "es"] where word.count > ending.count + 3 && word.hasSuffix(ending) {
                return String(word.dropLast(ending.count))
            }
            if word.count >= 4, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
            return word
        }
        func words(_ text: String) -> Set<String> {
            Set(LoopGuard.normalize(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !small.contains($0) }.map(stem))
        }
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// Lane BF2: the repeats waiting in a note's proposals, to leave out: an item not yet placed, in a proposal still
    /// waiting, much like one before it (placed, dismissed or waiting, in that proposal or an earlier one, `alike`). The
    /// first of each stays. Each as the proposal's id and the item's.
    public static func repeats(in distills: [DistillRecord]) -> [(distill: UUID, item: UUID)] {
        var seen: [DistillItem] = []
        var found: [(distill: UUID, item: UUID)] = []
        for distill in distills {
            for item in distill.items {
                let waiting = distill.status == .proposed && item.card == nil && !item.dropped
                if waiting, seen.contains(where: { alike(item, $0) }) {
                    found.append((distill.id, item.id))
                } else {
                    seen.append(item)
                }
            }
        }
        return found
    }

    /// How alike two titles are, from 0 to 1: the share of words they have in common, once case and small words don't
    /// count.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let small: Set<String> = ["the", "a", "an", "to", "of", "for", "and", "in", "on", "with", "it", "its"]
        func words(_ text: String) -> Set<String> {
            Set(LoopGuard.normalize(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !small.contains($0) })
        }
        let left = words(a), right = words(b)
        guard !left.isEmpty || !right.isEmpty else { return 1 }
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }
}
