import Foundation
import BindersKit

extension DistillService {
    /// Place on Board: the ticked items become cards in Ready (or Backlog), each saying which note it was distilled from
    /// with a link back to its section, recording that section and its version, waiting for the cards of the items it
    /// waits for, and meant for whoever was picked, by you. Every card is made first and its waits set before anyone is
    /// meant for it, so the dispatcher's wake for a card in Ready already sees what it waits for. The items not ticked stay
    /// in the proposal. `agentPlaced`: an agent placed them itself, in a binder that lets it (Agents may place work items):
    /// as Place on Board does, in Ready, each meant for whoever it picked (an assignment by Binders that says the agent
    /// placed it), waiting as proposed, so agents take them in order, each as its own start switch allows; their briefs
    /// say no one reviewed them. On a board shared through a team database the cards show here at once and go as one call
    /// (`place_work_items`), which checks the binder's setting itself (`operation` is its id). Returns the cards, in the
    /// items' order.
    @discardableResult
    func place(_ distill: DistillRecord, items chosen: Set<UUID>, column: BoardColumn, by actor: BoardActor = .you,
               agentPlaced: Bool = false) -> [TaskCard] {
        guard let board = controller?.board, let note = Store.shared.note(distill.note), Store.shared.canSave else { return [] }
        var record = distill
        // Distill again's offers as kept: the review takes or lets them be just before it places.
        if let stored = store.distill(distill.id, of: distill.note) { record.updates = stored.updates }
        let placing = record.items.filter { chosen.contains($0.id) && $0.card == nil && !$0.dropped }
        guard !placing.isEmpty else { return [] }
        let column: BoardColumn = agentPlaced ? .ready : (column == .backlog ? .backlog : .ready)
        // Cards from before, for waits on items placed earlier.
        var cardOf: [UUID: UUID] = [:]
        for earlier in store.file(for: note.id).distills { for item in earlier.items { if let card = item.card { cardOf[item.id] = card } } }
        var made: [(item: DistillItem, card: TaskCard)] = []
        let team = controller?.teamBoard
        let shared = team?.covers(note.binderID) == true
        let work = {
            for item in placing {
                let card = board.create(title: DistillCards.title(item),
                                        details: DistillCards.details(item, note: note.id, noteTitle: note.title, placedByAgent: agentPlaced ? actor.name : nil),
                                        binderID: note.binderID, column: column, source: ("note", note.id.uuidString, note.title), by: actor)
                card.distilledFrom = DistilledFrom(note: note.id, distill: record.id, item: item.id, section: item.section,
                                                   sectionHash: item.sectionHash, version: record.version, quote: item.quote)
                made.append((item, card))
                cardOf[item.id] = card.id
            }
            Store.shared.save()
            for (item, card) in made where !item.waitsFor.isEmpty {
                let ids = item.waitsFor.compactMap { cardOf[$0] }.filter { $0 != card.id }
                guard !ids.isEmpty else { continue }
                do {
                    try board.setWaits(card, to: ids, by: actor)
                } catch {
                    board.note(card, text: "Its waits were left out: \(error.localizedDescription)")
                }
            }
            for (item, card) in made {
                guard let who = item.meantFor?.trimmingCharacters(in: .whitespaces), !who.isEmpty else { continue }
                // Yours: an assignment Binders acts on. An agent's own placing, where the binder lets it: an assignment too,
                // by Binders, saying which agent placed it.
                if agentPlaced {
                    board.assign(card, to: who, by: BoardService.binders, placedBy: actor.name)
                } else {
                    board.assign(card, to: who, by: .you)
                }
            }
        }
        // An agent's placing wakes an agent only as that agent's start switch allows (TeamWakeRule).
        board.wakeCause = agentPlaced ? .placedByAgent(fromTeammate: false) : .yours
        if shared, let team {
            let lines = board.batchForTeam(work)
            let items = made.map { item, card in
                TeamPlacing.item(card: card.id, title: card.title, details: card.details, position: card.position, note: note.id, noteTitle: note.title,
                                 item: item.id, section: item.section, distilled: card.distilledFrom,
                                 waitsFor: card.waitsFor.compactMap(UUID.init(uuidString:)), meantFor: team.directory.teamName(card.meantFor))
            }
            team.place(binder: note.binderID ?? UUID(), items: items, column: column, agent: agentPlaced ? team.agentID(for: actor) : nil, lines: lines)
            board.sendDeferredTeamChanges()
        } else {
            work()
        }
        board.wakeCause = .yours
        for index in record.items.indices {
            if let card = made.first(where: { $0.item.id == record.items[index].id })?.card { record.items[index].card = card.id }
        }
        record.status = record.waitsForReview ? .proposed : .placed
        if agentPlaced { record.placedByAgent = true }
        store.save(record)
        // The version it read says how many were placed (versionMark).
        boardRevision += 1
        return made.map(\.card)
    }

    /// Not now, for good: what wasn't placed is put aside. What was placed stays on the board.
    func dismiss(_ distill: DistillRecord) {
        var record = store.distill(distill.id, of: distill.note) ?? distill
        record.status = .dismissed
        store.save(record)
        boardRevision += 1
    }

    /// Keeps the review sheet's edits: titles, briefs, waits, who each is for, what's dropped, the order.
    func save(_ distill: DistillRecord) {
        store.save(distill)
    }

    /// Distill again's offer, taken: a card's brief brought up to date with its section as it is now (it caught up), or a
    /// card closed as its section is gone (moved to Done by you, with why, counted as closed rather than done).
    func take(_ update: DistillUpdate, of distill: DistillRecord) {
        guard let board = controller?.board, let card = board.card(update.card) else { return }
        var from = card.distilledFrom
        switch update.kind {
        case .brief:
            board.edit(card, details: DistillCards.updating(card.details, brief: update.brief, doneWhen: update.doneWhen), by: .you)
            if let hash = update.sectionHash { from?.sectionHash = hash }
            from?.noticedHash = nil
            from?.briefUpdated = Date()
            // Where the note now says it (lane DS4): the words the new reading found it in.
            if let quote = update.quote { from?.quote = quote }
            // The section as Distill again read it, which the brief now follows: the next change is told from there.
            if let note = Store.shared.note(distill.note) {
                from?.seenText = distill.version.flatMap { NoteHistory.text(of: $0, note: note) }.flatMap { DistillSections.section(update.section, in: $0)?.text }
            }
            card.distilledFrom = from
            board.note(card, text: "Its brief was brought up to date with the \(update.section.map { "“\($0)” section" } ?? "note's opening") as it is now.")
        case .close:
            from?.closed = Date()
            card.distilledFrom = from
            try? board.move(card, to: .done, by: .you, note: "Closed without doing it: the \(update.section.map { "“\($0)” section" } ?? "note's opening") is gone from the note.")
        }
        var record = store.distill(distill.id, of: distill.note) ?? distill
        if let index = record.updates.firstIndex(where: { $0.id == update.id }) { record.updates[index].taken = true }
        Self.finishIfReviewed(&record)
        store.save(record)
        Store.shared.save()
        boardRevision += 1
    }

    /// Distill again's offer, let be.
    func leave(_ update: DistillUpdate, of distill: DistillRecord) {
        var record = store.distill(distill.id, of: distill.note) ?? distill
        if let index = record.updates.firstIndex(where: { $0.id == update.id }) { record.updates[index].taken = false }
        Self.finishIfReviewed(&record)
        store.save(record)
        boardRevision += 1
    }

    /// A proposal with nothing left for a person, every item placed or dropped and every offer taken or let be, is placed:
    /// it no longer waits on the Work bar.
    static func finishIfReviewed(_ record: inout DistillRecord) {
        if record.status == .proposed, !record.waitsForReview { record.status = .placed }
    }

    /// "Distilled by Binders' model (gemma), 12 items placed": what History says beside the version a distill read. Nil
    /// for one this Mac doesn't keep.
    static func versionMark(_ distill: UUID, note: UUID) -> String? {
        guard let record = DistillStore.shared.distill(distill, of: note) else { return nil }
        let placed = record.placedCount
        let what = placed > 0 ? (placed == 1 ? "1 item placed" : "\(placed) items placed")
            : record.status == .dismissed ? "put aside" : (record.kept.count == 1 ? "1 item proposed" : "\(record.kept.count) items proposed")
        return "Distilled by \(record.readByLine), \(what)"
    }

    /// You opened the report: "finished since you last looked" counts from now next time.
    func looked(at note: NoteItem) {
        store.update(note.id) { $0.lastLooked = Date() }
    }
}
