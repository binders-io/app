import Foundation
import SwiftData
import BindersKit

/// Everything that changes a board goes through here, so the rules hold the same for you in the window, for the phone
/// and for agents over MCP, and every change leaves a line on the card's timeline.
@MainActor
@Observable
final class BoardService {
    @ObservationIgnored private var sweeper: Timer?
    @ObservationIgnored private var store: Store { Store.shared }

    /// Every minute, cards whose agent went quiet go back to Ready.
    func start() {
        sweep()
        sweeper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
    }

    // MARK: Reading

    func card(_ id: UUID) -> TaskCard? {
        (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.id == id })))?.first
    }

    func cards(in binderID: UUID?) -> [TaskCard] {
        let all = (try? store.context.fetch(FetchDescriptor<TaskCard>(sortBy: [SortDescriptor(\.position)]))) ?? []
        return binderID.map { id in all.filter { $0.binderID == id } } ?? all
    }

    func timeline(_ id: UUID) -> [TaskEvent] {
        (try? store.context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.taskID == id }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    private func agentsMayFinish(_ card: TaskCard) -> Bool {
        store.binder(card.binderID)?.agentsMayFinish ?? false
    }

    // MARK: Changing

    @discardableResult
    func create(title: String, details: String = "", binderID: UUID?, column: BoardColumn = .backlog, due: Date? = nil,
                source: (kind: String, id: String, title: String)? = nil, by actor: BoardActor) -> TaskCard {
        let card = TaskCard(title: title.trimmingCharacters(in: .whitespacesAndNewlines), binderID: binderID ?? store.defaultBinder().id,
                            column: column == .done ? .backlog : column)
        card.details = details
        card.dueAt = due
        card.createdBy = actor.name
        if let source {
            card.sourceKind = source.kind
            card.sourceID = source.id
            card.sourceTitle = source.title
        }
        store.context.insert(card)
        log(card, .created, by: actor, text: source.map { "From \($0.title)" } ?? "", to: card.column)
        return card
    }

    func claim(_ card: TaskCard, by actor: BoardActor) throws {
        let before = card.column
        card.state = try BoardRules.claim(card.state, by: actor, at: Date())
        log(card, .claimed, by: actor, from: before, to: card.column)
    }

    func move(_ card: TaskCard, to column: BoardColumn, by actor: BoardActor) throws {
        let before = card.column
        guard before != column else { return }
        card.state = try BoardRules.move(card.state, to: column, by: actor, agentsMayFinish: agentsMayFinish(card), at: Date())
        card.position = Date().timeIntervalSinceReferenceDate
        log(card, .moved, by: actor, from: before, to: column)
    }

    /// A progress report, with any links it brings. Keeps an agent's claim alive.
    func report(_ card: TaskCard, progress: String, links: [String] = [], by actor: BoardActor) {
        let added = links.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !card.links.contains($0) }
        card.links += added
        card.state = BoardRules.renew(card.state, by: actor, at: Date())
        var text = progress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !added.isEmpty { text += (text.isEmpty ? "" : "\n") + added.map { "→ \($0)" }.joined(separator: "\n") }
        log(card, .progress, by: actor, text: text)
    }

    func ask(_ card: TaskCard, question: String, by actor: BoardActor) throws {
        let before = card.column
        card.state = try BoardRules.ask(card.state, by: actor, at: Date())
        log(card, .question, by: actor, text: question, from: before, to: card.column)
    }

    /// A comment. From a person on a blocked card, it's the answer, and the card goes back to work.
    func comment(_ card: TaskCard, text: String, by actor: BoardActor) {
        let before = card.column
        card.state = BoardRules.answered(BoardRules.renew(card.state, by: actor, at: Date()), by: actor)
        let answered = before == .blocked && card.column != .blocked
        log(card, answered ? .answer : .comment, by: actor, text: text, from: answered ? before : nil, to: answered ? card.column : nil)
    }

    func release(_ card: TaskCard, note: String = "", by actor: BoardActor) throws {
        let before = card.column
        card.state = try BoardRules.release(card.state, by: actor, at: Date())
        log(card, .released, by: actor, text: note, from: before, to: card.column)
    }

    func complete(_ card: TaskCard, summary: String, by actor: BoardActor) throws {
        let before = card.column
        card.state = try BoardRules.complete(card.state, by: actor, agentsMayFinish: agentsMayFinish(card), at: Date())
        card.position = Date().timeIntervalSinceReferenceDate
        log(card, .completed, by: actor, text: summary, from: before, to: card.column)
    }

    func edit(_ card: TaskCard, title: String? = nil, details: String? = nil, due: Date?? = nil, by actor: BoardActor) {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { card.title = title }
        if let details { card.details = details }
        if let due { card.dueAt = due }
        card.updatedAt = Date()
        store.save()
    }

    func delete(_ card: TaskCard) {
        for event in timeline(card.id) { store.context.delete(event) }
        store.context.delete(card)
        store.save()
    }

    /// Hands lapsed agents' cards back to Ready.
    func sweep(now: Date = Date()) {
        let held = (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.assigneeIsAgent }))) ?? []
        for card in held {
            guard let next = BoardRules.expire(card.state, at: now) else { continue }
            let who = card.assignee ?? "The agent"
            let before = card.column
            card.state = next
            log(card, .lapsed, by: BoardActor(name: who, kind: .agent), text: "\(who) went quiet for \(Int(BoardRules.lease / 60)) minutes, so the card is free again.",
                from: before, to: card.column)
        }
    }

    private func log(_ card: TaskCard, _ kind: TaskEvent.Kind, by actor: BoardActor, text: String = "", from: BoardColumn? = nil, to: BoardColumn? = nil) {
        card.updatedAt = Date()
        store.context.insert(TaskEvent(taskID: card.id, kind: kind, author: actor, text: text, from: from, to: to))
        store.save()
    }
}
