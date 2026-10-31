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
    /// say no one reviewed them. Returns the cards, in the items' order.
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
        // Lane DS8: an item read with v2 has the note's lines for a brief: its card carries them, and its brief and done
        // when are written once it's on the board (`writeBriefs`). One for an agent in Ready goes to it after its brief.
        var briefs: [DistillBriefJob] = []
        func pending(_ item: DistillItem) -> Bool { item.briefPending == true && !agentPlaced }
        func waitsForBrief(_ item: DistillItem) -> String? {
            guard pending(item), column == .ready, let who = item.meantFor?.trimmingCharacters(in: .whitespaces),
                  AgentRegistry.shared.agent(named: who) != nil else { return nil }
            return who
        }
        let work = {
            for item in placing {
                let details = pending(item) ? DistillCards.pendingDetails(item, note: note.id, noteTitle: note.title)
                    : DistillCards.details(item, note: note.id, noteTitle: note.title, placedByAgent: agentPlaced ? actor.name : nil)
                // Its tie to the note is made with it.
                let from = DistilledFrom(note: note.id, distill: record.id, item: item.id, section: item.section,
                                         sectionHash: item.sectionHash, version: record.version, quote: item.quote,
                                         briefFor: pending(item) ? DistillSections.hash(details) : nil, briefAgent: waitsForBrief(item))
                let card = board.create(title: DistillCards.title(item), details: details, binderID: note.binderID, column: column,
                                        source: (NoteWorkCards.noteKind, note.id.uuidString, note.title), distilled: from, by: actor)
                if pending(item) { briefs.append(self.briefJob(item, card: card, noteTitle: note.title, agent: waitsForBrief(item))) }
                made.append((item, card))
                cardOf[item.id] = card.id
            }
            Store.shared.save()
            for (item, card) in made where !item.waitsFor.isEmpty {
                // A wait on a card made from the note some other way names the card itself (`DistillAgain.waits`).
                let ids = item.waitsFor.compactMap { cardOf[$0] ?? board.card($0)?.id }.filter { $0 != card.id }
                guard !ids.isEmpty else { continue }
                do {
                    try board.setWaits(card, to: ids, by: actor)
                } catch {
                    board.note(card, text: "Its waits were left out: \(error.localizedDescription)")
                }
            }
            for (item, card) in made {
                guard let who = item.meantFor?.trimmingCharacters(in: .whitespaces), !who.isEmpty else { continue }
                // Its agent gets it once its brief is written.
                if waitsForBrief(item) != nil { continue }
                // Yours: an assignment Binders acts on. An agent's own placing, where the binder lets it: an assignment too,
                // by Binders, saying which agent placed it.
                if agentPlaced {
                    board.assign(card, to: who, by: BoardService.binders, placedBy: actor.name)
                } else {
                    board.assign(card, to: who, by: .you)
                }
            }
        }
        // An agent's placing wakes an agent only as that agent's start switch allows (AgentWakeRule).
        board.wakeCause = agentPlaced ? .placedByAgent : .yours
        work()
        board.wakeCause = .yours
        writeBriefs(briefs)
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
