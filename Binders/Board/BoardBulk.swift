import Foundation
import SwiftData
import BindersKit

/// Lane DS5: acting on many cards at once, from the board's selection: Move to a column, Assign to someone, Delete, and
/// Put in a note's group or Take out of it. Each goes card by card through what the board does for one (`BoardService`),
/// so the rules that hold for one hold for each, and the team database hears of each as it would of one; the cards those
/// rules keep as they are stay, and the line it says names them and why. One Undo puts all of it back.
@MainActor
enum BoardBulk {
    /// What one bulk action did: the cards it changed, those that stayed and why, and what to say.
    struct Outcome {
        var changed: [UUID] = []
        var stays: [BoardBulkWords.Stay] = []
        var line = ""
        /// Whether Undo can put any of it back (cards deleted for everyone on the team's board can't come back).
        var undoable = false
    }

    /// Who a card is being worked on by, other than you: an agent or a person with a live claim on it. Nil when no one, or
    /// you, has it. A card someone works on doesn't move or change hands under them.
    static func workingOn(_ card: TaskCard, now: Date = Date()) -> String? {
        guard BoardRules.isClaimed(card.state, at: now), let holder = card.assignee, holder != BoardActor.you.name else { return nil }
        return card.assigneeIsAgent ? holder.shortAgentName : holder
    }

    // MARK: Move to

    /// Where a card was, for Undo.
    private struct Place {
        let id: UUID
        let column: BoardColumn
        let position: Double

        init(_ card: TaskCard) {
            id = card.id
            column = card.column
            position = card.position
        }
    }

    /// Moves each card to `column` as dragging it there would, by you. One an agent or a teammate is working on stays, as
    /// does one the board's rules or the team database keep.
    static func move(_ cards: [TaskCard], to column: BoardColumn, board: BoardService, undoManager: UndoManager?) -> Outcome {
        var outcome = Outcome()
        var already = 0
        var places: [Place] = []
        for card in cards {
            if card.column == column {
                already += 1
                continue
            }
            if let who = workingOn(card) {
                outcome.stays.append(.working(who))
                continue
            }
            let place = Place(card)
            do {
                try board.move(card, to: column, by: .you)
            } catch {
                outcome.stays.append(.refused(error.localizedDescription))
                continue
            }
            places.append(place)
            outcome.changed.append(card.id)
        }
        outcome.line = BoardBulkWords.moved(places.count, to: column, already: already, stays: outcome.stays)
        guard !places.isEmpty else { return outcome }
        outcome.undoable = true
        let ids = places.map(\.id)
        register(undoManager, name: "Move \(BoardBulkWords.cards(places.count).capitalized)", undo: {
            for place in places {
                guard let card = board.card(place.id) else { continue }
                if card.column != place.column { try? board.move(card, to: place.column, by: .you) }
                card.position = place.position
            }
            Store.shared.save()
        }, redo: {
            for id in ids { if let card = board.card(id) { try? board.move(card, to: column, by: .you) } }
        })
        return outcome
    }

    // MARK: Assign to

    /// Whom to give the cards to.
    enum Who: Equatable {
        case nobody, you
        case person(String)
        /// One of your agents, or a teammate's (its name as the team calls it, "Claude Code (Dana)"): handed over as Give to does.
        case agent(String)

        var name: String? {
            switch self {
            case .nobody: nil
            case .you: BoardActor.you.name
            case .person(let name), .agent(let name): name
            }
        }

        var isAgent: Bool { if case .agent = self { true } else { false } }
    }

    /// Who a card was for, and where it was, for Undo.
    private struct Meant {
        let id: UUID
        let meantFor: String?
        let byAgent: Bool
        let column: BoardColumn

        init(_ card: TaskCard) {
            id = card.id
            meantFor = card.meantFor
            byAgent = card.meantForByAgent
            column = card.column
        }
    }

    /// Each card is meant for `who`, by you. To an agent it's Give to, card by card: meant for it and from Backlog into
    /// Ready, where the agent is woken now, with the receipt on the card, as a tap on one card's Give to does; this tap is
    /// the only thing that wakes it. A card that's done stays, and so does one someone else is working on when it's given to
    /// an agent. The cards the agent wasn't woken for say why.
    static func assign(_ cards: [TaskCard], to who: Who, board: BoardService, undoManager: UndoManager?) -> Outcome {
        var outcome = Outcome()
        var meant: [Meant] = []
        var notWoken: [String] = []
        for card in cards {
            if card.column == .done {
                outcome.stays.append(.done)
                continue
            }
            if who.isAgent, let holder = workingOn(card), let name = who.name, !BoardRules.isNamed(holder, as: name.shortAgentName),
               !BoardRules.isNamed(name, as: holder) {
                outcome.stays.append(.working(holder))
                continue
            }
            meant.append(Meant(card))
            if who.isAgent, let name = who.name {
                if case .notWoken(let why) = board.give(card, to: name, by: .you) { notWoken.append(why) }
            } else {
                board.assign(card, to: who.name, by: .you)
            }
            outcome.changed.append(card.id)
        }
        outcome.line = [BoardBulkWords.assigned(meant.count, to: who.name, agent: who.isAgent, stays: outcome.stays),
                        BoardBulkWords.notHandedOver(notWoken)].compactMap { $0 }.joined(separator: " ")
        guard !meant.isEmpty else { return outcome }
        outcome.undoable = true
        let ids = meant.map(\.id)
        register(undoManager, name: "Assign \(BoardBulkWords.cards(meant.count).capitalized)", undo: {
            for was in meant {
                guard let card = board.card(was.id) else { continue }
                // Given to an agent from Backlog: back to Backlog while no one has taken it since.
                if who.isAgent, was.column == .backlog, card.column == .ready, workingOn(card) == nil { try? board.move(card, to: .backlog, by: .you) }
                if was.byAgent, let suggested = was.meantFor {
                    // An agent's suggestion comes back as one: no one first, as a suggestion never replaces your choice.
                    board.assign(card, to: nil, by: .you)
                    board.assign(card, to: suggested, by: .you, suggesting: true)
                } else {
                    board.assign(card, to: was.meantFor, by: .you)
                }
            }
        }, redo: {
            for id in ids {
                guard let card = board.card(id) else { continue }
                if who.isAgent, let name = who.name { board.give(card, to: name, by: .you) } else { board.assign(card, to: who.name, by: .you) }
            }
        })
        return outcome
    }

    // MARK: Delete

    /// Deletes each card as Delete Card does, the team database included: on a board shared through it, for everyone. Undo
    /// puts back the ones that were on this Mac only, timeline and all; one the team database can't delete now stays.
    static func delete(_ cards: [TaskCard], board: BoardService, undoManager: UndoManager?) -> Outcome {
        var outcome = Outcome()
        var kept: [CardSnapshot] = []
        var deleted = 0
        for card in cards {
            if let refusal = board.teamRefusal(.delete, on: card, by: .you) {
                outcome.stays.append(.refused(refusal))
                continue
            }
            let snapshot = sharedWithTeam(card, board: board) ? nil : CardSnapshot(card, events: board.timeline(card.id))
            let id = card.id
            if let refusal = board.delete(card) {
                outcome.stays.append(.refused(refusal))
                continue
            }
            deleted += 1
            outcome.changed.append(id)
            if let snapshot { kept.append(snapshot) }
        }
        outcome.line = BoardBulkWords.deleted(deleted, stays: outcome.stays)
        guard !kept.isEmpty else { return outcome }
        outcome.undoable = true
        let ids = kept.map(\.id)
        register(undoManager, name: "Delete \(BoardBulkWords.cards(kept.count).capitalized)", undo: {
            for snapshot in kept where board.card(snapshot.id) == nil { snapshot.restore() }
            Store.shared.save()
        }, redo: {
            for id in ids { if let card = board.card(id) { board.delete(card) } }
        })
        return outcome
    }

    /// On a board shared through the team database, and not kept on this Mac: deleting it deletes it for everyone.
    static func sharedWithTeam(_ card: TaskCard, board: BoardService) -> Bool {
        board.team?.sends(card) == true
    }

    // MARK: A note's group

    /// What a card's group was, for Undo.
    private struct Grouped {
        let id: UUID
        let distilled: String
        let binderID: UUID?
    }

    /// Puts each card in `note`'s group (nil: takes it out of its group). A card made from a note, by Distill or with Put
    /// on Board (lane DS6), is its note's work, so it stays in that note's group; one asking an agent to distill a note
    /// stays as it is. A card that goes in takes the note's binder when it has none, and nothing else: who it's for and
    /// where it is stay as they are.
    static func group(_ cards: [TaskCard], into note: NoteItem?, board: BoardService, undoManager: UndoManager?) -> Outcome {
        var outcome = Outcome()
        var before: [Grouped] = []
        for card in cards {
            let from = card.distilledFrom
            if let from, from.request == true {
                outcome.stays.append(.refused("It asks an agent to distill “\(card.sourceTitle ?? "a note")”"))
                continue
            }
            let member = card.noteMembership
            if let member, member.staysInGroup {
                if member.note != note?.id {
                    let title = Store.shared.note(member.note)?.title ?? card.sourceTitle ?? "its note"
                    outcome.stays.append(member.tie == .put ? .put(title) : .distilled(title))
                }
                continue
            }
            if member?.note == note?.id { continue }
            before.append(Grouped(id: card.id, distilled: card.distilledJSON, binderID: card.binderID))
            card.distilledFrom = note.map { DistilledFrom.byHand(note: $0.id) }
            if let note, card.binderID == nil { card.binderID = note.binderID }
            card.updatedAt = Date()
            outcome.changed.append(card.id)
        }
        if !before.isEmpty { Store.shared.save() }
        outcome.line = BoardBulkWords.grouped(before.count, into: note?.title, stays: outcome.stays)
        guard !before.isEmpty else { return outcome }
        outcome.undoable = true
        let noteID = note?.id, noteBinder = note?.binderID
        register(undoManager, name: note == nil ? "Take Out of Group" : "Put in Group", undo: {
            for was in before {
                guard let card = board.card(was.id) else { continue }
                card.distilledJSON = was.distilled
                card.binderID = was.binderID
                card.updatedAt = Date()
            }
            Store.shared.save()
        }, redo: {
            for was in before {
                guard let card = board.card(was.id) else { continue }
                card.distilledFrom = noteID.map { DistilledFrom.byHand(note: $0) }
                if card.binderID == nil { card.binderID = noteBinder }
                card.updatedAt = Date()
            }
            Store.shared.save()
        })
        return outcome
    }

    // MARK: Undo

    /// Undo runs `undo` and offers Redo, which runs `redo` and offers Undo again, under one name in the Edit menu.
    private static func register(_ undoManager: UndoManager?, name: String, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: Store.shared) { [weak undoManager] _ in
            undo()
            register(undoManager, name: name, undo: redo, redo: undo)
        }
        undoManager.setActionName(name)
    }
}

/// A deleted card, everything it had and its timeline, as Undo puts it back: the same id, so what pointed at it (Distill's
/// item, the cards that wait for it, its note's marks) finds it again. Putting it back wakes no one.
@MainActor
struct CardSnapshot {
    let id: UUID
    private let fields: Fields
    private let events: [Event]

    private struct Fields {
        let binderID: UUID?, title: String, details: String, columnRaw: String, position: Double, assignee: String?, assigneeIsAgent: Bool
        let claimExpiresAt: Date?, dueAt: Date?, links: [String], sourceKind: String?, sourceID: String?, sourceTitle: String?
        let sourceRef: String?, createdBy: String, createdAt: Date, updatedAt: Date, externalKey: String?, externalURL: String?
        let meantFor: String?, meantForByAgent: Bool, waitsFor: [String], distilledJSON: String, teamShadow: String
    }

    private struct Event {
        let id: UUID, kindRaw: String, author: String, authorIsAgent: Bool, text: String, fromColumn: String?, toColumn: String?
        let createdAt: Date, teamOperation: String?, sectionChange: String?
    }

    init(_ card: TaskCard, events: [TaskEvent]) {
        id = card.id
        fields = Fields(binderID: card.binderID, title: card.title, details: card.details, columnRaw: card.columnRaw, position: card.position,
                        assignee: card.assignee, assigneeIsAgent: card.assigneeIsAgent, claimExpiresAt: card.claimExpiresAt, dueAt: card.dueAt,
                        links: card.links, sourceKind: card.sourceKind, sourceID: card.sourceID, sourceTitle: card.sourceTitle,
                        sourceRef: card.sourceRef, createdBy: card.createdBy, createdAt: card.createdAt, updatedAt: card.updatedAt,
                        externalKey: card.externalKey, externalURL: card.externalURL, meantFor: card.meantFor, meantForByAgent: card.meantForByAgent,
                        waitsFor: card.waitsFor, distilledJSON: card.distilledJSON, teamShadow: card.teamShadow)
        self.events = events.map {
            Event(id: $0.id, kindRaw: $0.kindRaw, author: $0.author, authorIsAgent: $0.authorIsAgent, text: $0.text, fromColumn: $0.fromColumn,
                  toColumn: $0.toColumn, createdAt: $0.createdAt, teamOperation: $0.teamOperation, sectionChange: $0.sectionChange)
        }
    }

    /// The card again, as it was, with its timeline. The caller saves.
    @discardableResult
    func restore() -> TaskCard {
        let context = Store.shared.context
        let card = TaskCard(title: fields.title, binderID: fields.binderID)
        card.id = id
        card.details = fields.details
        card.columnRaw = fields.columnRaw
        card.position = fields.position
        card.assignee = fields.assignee
        card.assigneeIsAgent = fields.assigneeIsAgent
        card.claimExpiresAt = fields.claimExpiresAt
        card.dueAt = fields.dueAt
        card.links = fields.links
        card.sourceKind = fields.sourceKind
        card.sourceID = fields.sourceID
        card.sourceTitle = fields.sourceTitle
        card.sourceRef = fields.sourceRef
        card.createdBy = fields.createdBy
        card.createdAt = fields.createdAt
        card.updatedAt = fields.updatedAt
        card.externalKey = fields.externalKey
        card.externalURL = fields.externalURL
        card.meantFor = fields.meantFor
        card.meantForByAgent = fields.meantForByAgent
        card.waitsFor = fields.waitsFor
        card.distilledJSON = fields.distilledJSON
        card.teamShadow = fields.teamShadow
        context.insert(card)
        for kept in events {
            let event = TaskEvent(taskID: id, kind: .comment, author: BoardActor(name: kept.author, kind: kept.authorIsAgent ? .agent : .person))
            event.id = kept.id
            event.kindRaw = kept.kindRaw
            event.text = kept.text
            event.fromColumn = kept.fromColumn
            event.toColumn = kept.toColumn
            event.createdAt = kept.createdAt
            event.teamOperation = kept.teamOperation
            event.sectionChange = kept.sectionChange
            context.insert(event)
        }
        return card
    }
}
