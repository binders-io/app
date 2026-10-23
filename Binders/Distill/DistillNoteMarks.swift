import Foundation
import BindersKit

/// Lane DS4: a note's cards, as its editor marks them at the words each came from (`NoteWork`), from the board: each card's
/// quote and section, its column, the state the Work panel gives it, who has it or is meant to, and its last update. Done
/// and closed cards go faint; items left out in the review have no card, so they show nothing. Lane DS6: any note's cards,
/// Distill on or not: those made with Put on Board from words in it are marked there; one made from the whole note, or put
/// in its group by hand, shows after the note's title.
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

    /// The note's cards, for its editor; nil for a note without any, or with Show Work in the Note off. Reads the board's
    /// revision, so a view that calls it is redrawn when a card moves.
    static func work(for note: NoteItem, controller: DictationController, shown: Bool = Self.shown, now: Date = Date()) -> NoteWork? {
        let revision = controller.distill.boardRevision
        guard shown, note.distill || DistillBoard.hasCards(note.id) else { return nil }
        let key = [revision, Int(now.timeIntervalSince1970 / 60)]
        var work: NoteWork
        if let kept = kept[note.id], kept.key == key {
            work = kept.work
        } else {
            work = NoteWork(cards: cards(of: note.id, now: now))
            kept[note.id] = (key, work)
        }
        work.open = { [weak controller] id in
            guard let card = controller?.board.card(id) else { return }
            CardWindows.shared.open(card)
        }
        return work.cards.isEmpty ? nil : work
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
