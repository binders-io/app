import Foundation
import BindersKit

extension DistillService {
    // MARK: Sections that change after their cards were made

    /// A Distill note is changing, or changed, by `author` (NoteHistory says): an agent's or a teammate's change is looked
    /// at once it lands, with any typing of yours before it looked at first, as yours; your own typing once it settles.
    func noteChanged(_ id: UUID, by author: NoteAuthor) {
        if author.isYou {
            settling[id]?.cancel()
            settling[id] = Task { [weak self] in
                guard let delay = self?.settleDelay else { return }
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                self.settling[id] = nil
                if let note = Store.shared.note(id) { self.checkSections(of: note, by: .you) }
            }
            return
        }
        // Called as the change is about to land: what's there now is yours, from before it.
        if settling.removeValue(forKey: id)?.cancel() != nil, let note = Store.shared.note(id) { checkSections(of: note, by: .you) }
        Task { [weak self] in
            await Task.yield()
            guard let self, let note = Store.shared.note(id) else { return }
            self.checkSections(of: note, by: author)
        }
    }

    /// Your typing in the note, looked at now rather than once it settles: when the note is left, and for the self-tests.
    func settleNow(_ id: UUID) {
        guard settling.removeValue(forKey: id) != nil else { return }
        if let note = Store.shared.note(id) { checkSections(of: note, by: .you) }
    }

    /// Looks at the note's sections against the cards made from them: each card whose section changed since Binders last
    /// looked gets a line on its timeline by Binders, who changed it and how much, with the changed lines, from the section
    /// as Binders last said it was, so a line holds one change in the words of the one who made it. People see every line.
    /// What of it reaches an agent depends on whose change it was (`SectionChangeMark`, `DistilledFrom.forAgent`): yours
    /// is told to the agent holding the card, lines and all; a teammate's lines only to an agent that may read teammates'
    /// items, any other hearing who, where and how much; an agent's waits for a person to look (`passOn`). Who changed each
    /// section, and when, is noted for its heading. Done and closed cards are left alone. Lane DS6: the same for cards made
    /// with Put on Board from words under a "## " heading, Distill on or not; what of their changes reaches an agent is who
    /// changed which section and how much, as those cards give an agent no way into the note.
    func checkSections(of note: NoteItem, by author: NoteAuthor, at now: Date = Date()) {
        guard note.distill || DistillBoard.followsSections(note.id), let board, Store.shared.canSave else { return }
        let sections = DistillSections.sections(of: note.text)
        if note.distill {
            var index = NoteHistory.index(of: note.id, note: note)
            if !index.stamp(note.text, by: author, at: now).isEmpty { NoteHistory.save(index, for: note.id) }
        }
        var changed = false
        for card in DistillBoard.cards(of: note.id) where card.column != .done {
            guard var from = card.distilledFrom, from.closed == nil, from.followsSection else { continue }
            let section = from.section == nil ? sections.first { $0.heading == nil } : sections.first { $0.heading == from.section }
            let hash = section?.hash ?? DistilledFrom.gone
            guard hash != from.seenHash else { continue }
            // What changed: from the section as Binders last said it was (the first time, as the distill read it) to the
            // section now.
            let before = from.seenText
                ?? from.version.flatMap { NoteHistory.text(of: $0, note: note) }.flatMap { DistillSections.section(from.section, in: $0)?.text } ?? ""
            let change = DistillSections.change(from: before, to: section?.text ?? "")
            let gone = section == nil
            let line = DistilledFrom.line(section: from.section, note: note.title, by: author.phrase, added: change.added, removed: change.removed,
                                          gone: gone, lines: change.lines)
            let mark = SectionChangeMark(author, added: change.added, removed: change.removed, withoutNote: !from.opensNote)
            // A person who changes the section after an agent did has looked at it: those lines wait no more.
            if !author.isAgent, from.held == true { release(card) }
            board.note(card, text: line, sectionChange: mark)
            from.noticedHash = hash
            from.seenText = section?.text ?? ""
            from.change = DistilledFrom.Notice(by: author.phrase, byAgent: author.isAgent, at: now, added: change.added, removed: change.removed, gone: gone)
            from.held = author.isAgent
            card.distilledFrom = from
            changed = true
            // A person's change reaches the agent holding the card, as your comment would, as much of it as that agent may
            // hear; an agent's waits for a look.
            if !author.isAgent { controller?.agents.tell(card, notice: .init(line: line, mark: mark)) }
        }
        if changed {
            Store.shared.save()
            boardRevision += 1
        }
    }

    /// The card's lines about an agent's change that wait for a person, no longer waiting: what then reaches an agent of
    /// them is who changed which section and how much, never their lines. Returns their marks, oldest first.
    @discardableResult
    private func release(_ card: TaskCard) -> [SectionChangeMark] {
        var released: [SectionChangeMark] = []
        for event in board?.timeline(card.id) ?? [] {
            guard var mark = SectionChangeMark(json: event.sectionChange), mark.held == true else { continue }
            mark.held = false
            event.sectionChange = mark.json
            released.append(mark)
        }
        return released
    }

    /// A person looked at an agent's change to the card's section ("Looked at It · Tell", or Make It Mine on the note): the
    /// agent holding the card is told who changed it and how much, without the other agent's words, and pointed at the
    /// section as it is now.
    func passOn(_ card: TaskCard, note: NoteItem? = nil) {
        guard var from = card.distilledFrom, from.held == true, let note = note ?? Store.shared.note(from.note) else { return }
        from.held = false
        card.distilledFrom = from
        let released = release(card)
        Store.shared.save()
        var who: [String] = []
        for mark in released where !who.contains(mark.by) { who.append(mark.by) }
        let by = who.isEmpty ? from.change?.by ?? "an agent" : DistillProgress.list(who)
        let added = released.isEmpty ? from.change?.added ?? 0 : released.map(\.added).reduce(0, +)
        let removed = released.isEmpty ? from.change?.removed ?? 0 : released.map(\.removed).reduce(0, +)
        let line = DistilledFrom.passedOn(section: from.section, note: note.title, by: by, added: added, removed: removed, opensNote: from.opensNote)
        if card.assigneeIsAgent, BoardRules.isClaimed(card.state, at: Date()) {
            controller?.board.note(card, text: "You looked at the change. Binders told \(card.assignee ?? "the agent") to work from the section as it is now.")
            controller?.agents.tell(card, notice: .init(line: line, mark: nil))
        }
        boardRevision += 1
    }

    /// Every card from the note whose change waits for a person: passed on, as Make It Mine says the agent's words are yours.
    func passOnAll(of note: NoteItem) {
        for card in DistillBoard.cards(of: note.id) where card.distilledFrom?.held == true { passOn(card, note: note) }
    }

    /// Hovering a heading: who last changed its section and when, and the cards made from it with where each stands.
    func headingTip(_ heading: String, in note: NoteItem) -> String? {
        guard note.distill else { return nil }
        let index = NoteHistory.index(of: note.id, note: note)
        var parts: [String] = []
        if let stamp = index.sections[heading] {
            parts.append("Changed by \(stamp.by.phrase), \(stamp.at.formatted(.relative(presentation: .named))).")
        }
        let cards = DistillBoard.cards(of: note.id).filter { $0.distilledFrom?.section == heading }
        if !cards.isEmpty {
            parts.append("Cards from it: " + cards.prefix(6).map { "“\($0.title)” (\($0.column.title))" }.joined(separator: ", ")
                         + (cards.count > 6 ? " and \(cards.count - 6) more." : "."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Notifications

    /// The cards meant for you whose waits are all done now, in Ready: your turn.
    func yourTurn(_ note: UUID) -> Set<UUID> {
        guard let board else { return [] }
        return Set(DistillBoard.cards(of: note).filter { card in
            card.column == .ready && card.meantFor == BoardActor.you.name && !card.waitsFor.isEmpty && board.openWaits(of: card).isEmpty
        }.map(\.id))
    }

    /// The cards that wait on you in Blocked with only a reason, no question or request for approval, put there by someone
    /// other than you: the board rings for a question, an approval and a run that stopped, never for these.
    func blockedOnYou(_ cards: [DistillProgress.Card]) -> Set<UUID> {
        Set(cards.filter { card in
            card.column == .blocked && !card.closed && card.question == nil && card.waitsOn == nil
                && card.blockedBy.map { !BoardRules.isReserved($0) } == true
        }.compactMap { UUID(uuidString: $0.id) })
    }

    /// What the notifications follow of a note now (`Seen`).
    func watch(_ note: UUID, cards given: [DistillProgress.Card]? = nil) -> Seen {
        let cards = given ?? DistillBoard.progressCards(of: note)
        return Seen(counts: DistillProgress.counts(cards, at: Date()), yourTurn: yourTurn(note), blocked: blockedOnYou(cards))
    }

    /// The board changed: each Distill note's numbers again, with a word when something of a spec waits on you (a card meant
    /// for you whose last wait is done, or one blocked on you with only a reason) and when a whole spec is done. Questions,
    /// approvals, reviews and a run that stopped ring on their own already, so never a second word for them.
    func boardChanged() {
        boardRevision += 1
        for note in DistillBoard.notes(in: nil) {
            let cards = DistillBoard.progressCards(of: note.id)
            let now = watch(note.id, cards: cards)
            // Out of Blocked: what a run's end said of a card is old news.
            for card in cards where card.column != .blocked { if let id = UUID(uuidString: card.id) { _ = controller?.agents.takeSaidBlocked(id) } }
            let before = seen[note.id]
            seen[note.id] = now
            guard let before else { continue }
            let newly = now.yourTurn.subtracting(before.yourTurn)
            if let first = newly.first, let card = board?.card(first) {
                notify(title: "Your turn in “\(note.title)”", body: newly.count == 1 ? "“\(card.title)” is ready for you." : "\(newly.count) cards are ready for you.",
                       note: note)
            }
            // Blocked on you, once each: not one a run's end put there, which rang already (or which you stopped).
            let blocked = now.blocked.subtracting(before.blocked).filter { !(controller?.agents.takeSaidBlocked($0) ?? false) }
            if let first = blocked.first, let card = board?.card(first) {
                notify(title: "“\(note.title)” waits on you", body: blocked.count == 1 ? "“\(card.title)” is blocked." : "\(blocked.count) of its cards are blocked.",
                       note: note)
            }
            if now.counts.isDone, !before.counts.isDone {
                notify(title: "“\(note.title)” is done", body: now.counts.total == 1 ? "Its card is done." : "All \(now.counts.total) of its cards are done.", note: note)
            }
        }
    }

    private func notify(title: String, body: String, note: NoteItem) {
        posted.append(title)
        MacNotifications.shared.post(spec: title, body: body, note: note.id)
    }

    // MARK: Ask

    /// "How's the checkout spec going?", from Ask or Command Mode: the report of the Distill note it names, in sentences.
    /// Nil when it isn't such a question.
    static func answer(_ question: String) -> String? {
        let notes = DistillBoard.notes(in: nil)
        guard let title = DistillAsk.note(in: question, titles: notes.map(\.title)), let note = notes.first(where: { $0.title == title }) else {
            return nil
        }
        return DistillBoard.progress(of: note).report.summary
    }
}
