import Foundation

/// Distill again, after the note changed: what's read now compared with the items from before, by the section each came
/// from. New sections get new items; a section whose text changed since its cards were made gets its cards' briefs to
/// update and new items for what's new in it; a section that's the same gets nothing; a card whose section is gone is
/// offered to close. The same item is never made twice.
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

        public init(item: UUID, title: String, section: String?, sectionHash: String?, card: UUID?, finished: Bool = false) {
            self.item = item
            self.title = title
            self.section = section
            self.sectionHash = sectionHash
            self.card = card
            self.finished = finished
        }
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
        /// Items left out as the same as one from before, or from a section that's the same.
        public var leftOut: Int
        /// Each section of the note now, by title, and how it stands.
        public var sections: [String: SectionState]
    }

    /// The plan: `read` is what the reader proposed now (each with its section's hash as now), `earlier` every item from
    /// before (placed or still proposed, not dropped), `sections` the note's sections now.
    public static func plan(read: [DistillItem], earlier: [Earlier], sections: [DistillSections.Section]) -> Plan {
        var states: [String: SectionState] = [:]
        for section in sections {
            let before = earlier.filter { $0.section == section.heading }
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
        var leftOut = 0
        var matched: Set<UUID> = []
        for item in read {
            let section = sections.first { $0.heading == item.section }
            let state = section.map { states[$0.title] ?? .new } ?? .new
            let before = earlier.filter { $0.section == item.section }
            // Never the same item twice: one with the title of an item from before in the same section.
            if let same = before.first(where: { similarity($0.title, item.title) >= 0.99 }) {
                if state == .changed, let card = same.card, !same.finished, !matched.contains(same.item) {
                    matched.insert(same.item)
                    updates.append(DistillUpdate(kind: .brief, card: card, item: same.item, section: item.section, sectionHash: section?.hash,
                                                 brief: item.brief, doneWhen: item.doneWhen, quote: item.quote))
                }
                leftOut += 1
                continue
            }
            switch state {
            case .same:
                leftOut += 1
            case .new:
                keep.append(item)
            case .changed:
                // What's new in a changed section: an update for the card it matches best, or a new item.
                if let best = before.filter({ !matched.contains($0.item) && $0.card != nil && !$0.finished })
                    .map({ ($0, similarity($0.title, item.title)) }).filter({ $0.1 >= 0.5 }).max(by: { $0.1 < $1.1 })?.0,
                   let card = best.card {
                    matched.insert(best.item)
                    updates.append(DistillUpdate(kind: .brief, card: card, item: best.item, section: item.section, sectionHash: section?.hash,
                                                 brief: item.brief, doneWhen: item.doneWhen, quote: item.quote))
                } else {
                    keep.append(item)
                }
            }
        }
        // Cards whose section is gone: offered to close.
        var closes: [DistillUpdate] = []
        for item in earlier where item.card != nil && !item.finished {
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
        return Plan(items: keep, updates: updates, closes: closes, leftOut: leftOut, sections: states)
    }

    /// An agent's own proposal for a note distilled before: everything it proposes, but an item the same as one from
    /// before in the same section, which is never made twice. It offers no updates or closes: those come from reading the
    /// note again (`plan`).
    public static func additions(read: [DistillItem], earlier: [Earlier]) -> (items: [DistillItem], leftOut: Int) {
        let keep = read.filter { item in
            !earlier.contains { $0.section == item.section && similarity($0.title, item.title) >= 0.99 }
        }
        let kept = Set(keep.map(\.id))
        return (keep.map { item in
            var item = item
            item.waitsFor = item.waitsFor.filter(kept.contains)
            return item
        }, read.count - keep.count)
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
