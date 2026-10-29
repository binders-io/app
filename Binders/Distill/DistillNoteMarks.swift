import Foundation
import BindersKit

/// Lane DS4: a note's cards, as its editor marks them at the words each came from (`NoteWork`), from the board: each card's
/// quote and section, its column, the state the Work panel gives it, who has it or is meant to, and its last update. Done
/// and closed cards go faint; items left out in the review have no card, so they show nothing. Lane DS6: any note's cards,
/// Distill on or not: those made with Put on Board from words in it are marked there; one made from the whole note, or put
/// in its group by hand, shows after the note's title. The work items still waiting for review in its Distill list are
/// marked too, quietly, as proposed: a click opens the list at the item.
@MainActor
enum DistillNoteMarks {
    /// "Show Work in the Note" on the Work bar, remembered on this Mac; on unless turned off.
    nonisolated static let shownKey = "distillShowWorkInNote"

    nonisolated static var shown: Bool {
        get { AppDefaults.store.object(forKey: shownKey) as? Bool ?? true }
        set { AppDefaults.store.set(newValue, forKey: shownKey) }
    }

    /// What was last worked out for each note, kept while the board and the minute are the same: the note page asks again
    /// whenever its note changes, as you type.
    private static var kept: [UUID: (key: [Int], work: NoteWork)] = [:]

    /// The note's cards, and its work items waiting for review, for its editor; nil for a note without any, or with Show
    /// Work in the Note off. Reads the board's revision and the distills', so a view that calls it is redrawn when a card
    /// moves or an item is proposed. `popout`: the note's own window, whose Distill list a proposed item opens.
    static func work(for note: NoteItem, controller: DictationController, shown: Bool = Self.shown, popout: Bool = false, now: Date = Date()) -> NoteWork? {
        let revision = controller.distill.boardRevision
        let distills = DistillStore.shared.revision
        guard shown, note.distill || DistillBoard.hasCards(note.id) else { return nil }
        let key = [revision, distills, note.distill ? 1 : 0, Int(now.timeIntervalSince1970 / 60)]
        var work: NoteWork
        if let kept = kept[note.id], kept.key == key {
            work = kept.work
        } else {
            work = NoteWork(cards: cards(of: note.id, now: now) + (note.distill ? proposed(in: note.id) : []))
            kept[note.id] = (key, work)
        }
        let id = note.id
        work.open = { [weak controller] opened in
            guard let controller else { return }
            if let card = controller.board.card(opened) {
                CardWindows.shared.open(card)
                return
            }
            // A work item waiting for review: the Distill list, at its row.
            controller.distill.list(for: id).selected = opened
            DistillActions.open(id, popout: popout)
        }
        return work.cards.isEmpty ? nil : work
    }

    /// The work items waiting for review in the note's proposals, as the editor marks them: at the words each came from,
    /// in the "proposed" colour, by who read them.
    static func proposed(in note: UUID) -> [NoteWork.Card] {
        var seen: Set<UUID> = []
        return DistillStore.shared.file(for: note).distills.filter { $0.status == .proposed }.flatMap { record in
            record.waiting.filter { seen.insert($0.id).inserted }.map { item in
                var detail = ["Proposed by \(record.readByLine)", "Waits for your review"]
                if let who = item.meantFor { detail.append("for \(who == BoardActor.you.name ? "you" : who.shortAgentName)") }
                return NoteWork.Card(id: item.id, title: item.title, quote: item.quote, section: item.section,
                                     chip: .proposal(id: item.id.uuidString, title: item.title), state: .notStarted,
                                     detail: detail.joined(separator: " · "))
            }
        }
    }

    /// Every card of the note, as the editor marks it.
    static func cards(of note: UUID, now: Date = Date()) -> [NoteWork.Card] {
        let made = DistillBoard.cards(of: note)
        guard !made.isEmpty else { return [] }
        let progress = DistillBoard.progressCards(of: note, now: now)
        let items = Dictionary(DistillProgress.items(progress, at: now).map { ($0.card, $0) }, uniquingKeysWith: { a, _ in a })
        let byID = Dictionary(progress.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return made.compactMap { card -> NoteWork.Card? in
            // One made with Put on Board before this build has no Distill part: it shows after the note's title.
            guard let read = byID[card.id.uuidString] else { return nil }
            let from = card.noteMembership
            let item = items[card.id.uuidString]
            let state = DistillProgress.state(read, at: now)
            let who = item?.who.map { $0 == BoardActor.you.name ? "You" : $0.shortAgentName }
            let chip = DistillMarks.ChipCard(id: card.id.uuidString, title: card.title, column: card.column.rawValue, state: state,
                                             who: read.closed ? nil : who, closed: read.closed)
            return NoteWork.Card(id: card.id, title: card.title, quote: from?.quote, section: from?.section, chip: chip, state: state,
                                 detail: detail(card, read: read, item: item, now: now))
        }
    }

    /// "Web · In progress · Echo has it · Last update 5 minutes ago: Halfway through the tests": its board, column, who has
    /// it or is meant to, and its last update (or when it last changed).
    static func detail(_ card: TaskCard, read: DistillProgress.Card, item: DistillProgress.Item?, now: Date) -> String {
        var parts: [String] = []
        if let board = Store.shared.binder(card.binderID)?.name, !board.isEmpty { parts.append(board) }
        parts.append(read.closed ? "Closed without doing it" : card.column.title)
        if let item, let who = item.who {
            let name = who == BoardActor.you.name ? "you" : who.shortAgentName
            parts.append(item.meant ? "for \(name)" : (who == BoardActor.you.name ? "you have it" : "\(name) has it"))
        }
        if let item, let last = WorkItemRow.lastUpdateLine(item, now: now) {
            parts.append(last)
        } else {
            parts.append("Changed \(WorkBar.ago(read.updated, now: now))")
        }
        return parts.joined(separator: " · ")
    }
}
