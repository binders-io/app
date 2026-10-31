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
    /// For keeping promises when their cards are done.
    @ObservationIgnored weak var commitments: CommitmentService?
    /// Wakes the agent a card is meant for; told of every change.
    @ObservationIgnored weak var dispatcher: AgentDispatcher?
    /// Boards of binders linked to a hub (HubBoard): a change to one of their cards is made here, then sent to the hub's
    /// log, which has the last word.
    @ObservationIgnored weak var hub: HubBoard?
    /// Changes to a hub's cards made while another was being made: they go after it, so the hub has the card first.
    @ObservationIgnored private var hubDeferred: [(() -> Void)?] = []
    /// The lines each change being made writes, while it's made (one list per change, as changes can nest).
    @ObservationIgnored private var changeLines: [[TaskEvent]] = []
    /// Why the changes being made might wake an agent: yours, unless an agent's placing (Agents may place work items).
    @ObservationIgnored var wakeCause: AgentWakeCause = .yours

    /// Every minute, cards whose agent went quiet go back to Ready. The dispatcher starts asking status addresses too.
    func start() {
        sweep()
        sweeper = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        dispatcher?.start()
    }

    // MARK: Reading

    func card(_ id: UUID) -> TaskCard? {
        (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.id == id })))?.first
    }

    func cards(in binderID: UUID?) -> [TaskCard] {
        let all = (try? store.context.fetch(FetchDescriptor<TaskCard>(sortBy: [SortDescriptor(\.position)]))) ?? []
        return binderID.map { id in all.filter { $0.binderID == id } } ?? all
    }

    /// The card made from this to-do, if there is one.
    func card(forTodo id: String) -> TaskCard? {
        (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.sourceRef == id })))?.first
    }

    func timeline(_ id: UUID) -> [TaskEvent] {
        (try? store.context.fetch(FetchDescriptor<TaskEvent>(predicate: #Predicate { $0.taskID == id }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    private func agentsMayFinish(_ card: TaskCard) -> Bool {
        store.binder(card.binderID)?.agentsMayFinish ?? false
    }

    // MARK: The hub's boards

    /// A change to a card: made here as on any board; on a binder linked to a hub it's then sent to the hub's log.
    private func boardChange(_ card: TaskCard, by actor: BoardActor, change: () throws -> Void) rethrows {
        if let hub, hub.covers(card) { return try hubChange(card, by: actor, hub: hub, change: change) }
        try change()
    }

    /// A change to a card on a binder linked to a hub: made here, then sent to the hub with the lines it wrote
    /// (`HubBoard.sent`), after the change it was made inside, if any.
    private func hubChange(_ card: TaskCard, by actor: BoardActor, hub: HubBoard, before: HubBoard.Before? = nil,
                           change: () throws -> Void) rethrows {
        let before = before ?? HubBoard.Before(card)
        // Its place among the changes being made, kept before the ones made inside it.
        let slot = hubDeferred.count
        hubDeferred.append(nil)
        changeLines.append([])
        do {
            try change()
        } catch {
            changeLines.removeLast()
            if changeLines.isEmpty { flushDeferred() }
            throw error
        }
        let lines = changeLines.removeLast()
        hubDeferred[slot] = { [weak hub] in hub?.sent(card, before: before, lines: lines, by: actor) }
        if changeLines.isEmpty { flushDeferred() }
    }

    private func flushDeferred() {
        // A hub's changes go in the order they were begun, the outermost first.
        let hubWaiting = hubDeferred
        hubDeferred = []
        for send in hubWaiting { send?() }
    }

    // MARK: Waits

    /// What a card waits for, as the board has those cards now; one that's gone is waited for no longer.
    func waits(of card: TaskCard) -> [CardWaits.Wait] {
        guard !card.waitsFor.isEmpty else { return [] }
        let ids = card.waitsFor.compactMap(UUID.init(uuidString:))
        let found = (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        return ids.compactMap { id in found.first { $0.id == id } }.map { CardWaits.Wait(id: $0.id.uuidString, title: $0.title, column: $0.column) }
    }

    /// What it still waits for: the cards it waits for that aren't Done.
    func openWaits(of card: TaskCard) -> [CardWaits.Wait] {
        CardWaits.open(waits(of: card))
    }

    /// The titles of those, for the wait rule.
    private func waitingOn(_ card: TaskCard) -> [String] {
        openWaits(of: card).map(\.title)
    }

    /// The cards that wait for this one.
    func waiting(on card: TaskCard) -> [TaskCard] {
        let id = card.id.uuidString
        return ((try? store.context.fetch(FetchDescriptor<TaskCard>())) ?? []).filter { $0.waitsFor.contains(id) }
    }

    enum WaitProblem: LocalizedError {
        case circle
        var errorDescription: String? { "A card can't wait for itself, directly or through the cards it waits for." }
    }

    /// Sets what a card waits for, by the ids of other cards: refused when that would make a card wait for itself. A line
    /// on its timeline says what it waits for now, which wakes no one.
    func setWaits(_ card: TaskCard, to ids: [UUID], by actor: BoardActor, quietly: Bool = false) throws {
        let wanted = ids.map(\.uuidString).reduce(into: [String]()) { list, id in if !list.contains(id) { list.append(id) } }
        guard wanted != card.waitsFor else { return }
        let all = (try? store.context.fetch(FetchDescriptor<TaskCard>())) ?? []
        let graph = Dictionary(all.map { ($0.id.uuidString, $0.waitsFor) }, uniquingKeysWith: { a, _ in a })
        if CardWaits.makesCycle(card: card.id.uuidString, waitsFor: wanted, graph: graph) { throw WaitProblem.circle }
        // On a hub's board, what it waits for goes up with its line, as any change does.
        if let hub, hub.covers(card) {
            let before = HubBoard.Before(card)
            card.waitsFor = wanted
            guard !quietly else {
                card.updatedAt = Date()
                store.save()
                return hub.sent(card, before: before, lines: [], by: actor)
            }
            return hubChange(card, by: actor, hub: hub, before: before) {
                log(card, .edited, by: actor, text: CardWaits.line(waits(of: card)).map { $0 + "." } ?? "Waits for nothing now.")
            }
        }
        card.waitsFor = wanted
        guard !quietly else {
            card.updatedAt = Date()
            store.save()
            return
        }
        log(card, .edited, by: actor, text: CardWaits.line(waits(of: card)).map { $0 + "." } ?? "Waits for nothing now.")
    }

    // MARK: Changing

    @discardableResult
    func create(title: String, details: String = "", binderID: UUID?, column: BoardColumn = .backlog, due: Date? = nil,
                source: (kind: String, id: String, title: String)? = nil, sourceRef: String? = nil, id: UUID? = nil,
                distilled: DistilledFrom? = nil, by actor: BoardActor) -> TaskCard {
        let card = TaskCard(title: title.trimmingCharacters(in: .whitespacesAndNewlines), binderID: binderID ?? store.defaultBinder().id,
                            column: column == .done ? .backlog : column)
        // Made from something with an id of its own (a moment), it takes that id, so making it twice finds it.
        if let id { card.id = id }
        card.details = details
        card.dueAt = due
        card.createdBy = actor.name
        if let source {
            card.sourceKind = source.kind
            card.sourceID = source.id
            card.sourceTitle = source.title
        }
        card.sourceRef = sourceRef
        // Its note, as a card made with Put on Board has it (lane DS6).
        if let distilled { card.distilledFrom = distilled }
        store.context.insert(card)
        boardChange(card, by: actor) {
            log(card, .created, by: actor, text: source.map { "From \($0.title)" } ?? "", to: card.column)
        }
        return card
    }

    /// A card for a to-do, linked to it so the to-do is ticked off when the card is done. A to-do that already has a card
    /// gets that one back.
    @discardableResult
    func create(from todo: TodoItem, column: BoardColumn = .ready, binderID: UUID? = nil, title: String? = nil, details: String = "",
                by actor: BoardActor) -> (card: TaskCard, existed: Bool) {
        if let card = card(forTodo: todo.id) { return (card, true) }
        let owner = todo.owner.flatMap { $0.isEmpty || $0 == TranscriptSegment.you ? nil : $0 }
        let card = create(title: title ?? todo.text, details: details.isEmpty ? (owner.map { "For \($0)." } ?? "") : details,
                          binderID: binderID ?? todo.binderID, column: column, due: todo.due,
                          source: (todo.sourceKind, todo.sourceID.uuidString, todo.sourceTitle), sourceRef: todo.id, by: actor)
        return (card, false)
    }

    /// Put on Board: a card in the note's binder, in Backlog, with the note's title and, in its details, its first lines
    /// and a link back (NoteCards). It says it's from the note, as a to-do's card says where the to-do came from, and is
    /// among the note's cards (lane DS6), shown after the note's title.
    @discardableResult
    func create(from note: NoteItem, by actor: BoardActor) -> TaskCard {
        create(title: NoteCards.title(note.title), details: NoteCards.details(text: note.text, noteID: note.id.uuidString, agent: note.agentMark),
               binderID: note.binderID, column: .backlog, source: (NoteWorkCards.noteKind, note.id.uuidString, note.title),
               distilled: .put(note: note.id), by: actor)
    }

    /// Put on Board from words selected in the note (lane DS6): one card for `selection`, or with `eachLine` one for each
    /// of its lines, in the note's binder, in Backlog, each titled from its first line, with the words and the way back to
    /// them in its details, and marked in the note at them (`NoteSelectionCards`). An empty selection puts the whole note.
    @discardableResult
    func create(from note: NoteItem, selection: NSRange, eachLine: Bool = false, by actor: BoardActor) -> [TaskCard] {
        guard selection.length > 0 else { return [create(from: note, by: actor)] }
        return NoteSelectionCards.pieces(text: note.text, selection: selection, noteID: note.id, eachLine: eachLine, agent: note.agentMark).map { piece in
            create(title: piece.title, details: piece.details, binderID: note.binderID, column: .backlog,
                   source: (NoteWorkCards.noteKind, note.id.uuidString, note.title),
                   distilled: .put(note: note.id, section: piece.section, sectionText: piece.sectionText, quote: piece.quote), by: actor)
        }
    }

    /// Taking a card. `note` goes on the timeline when nothing else does: Binders holding a card for an agent says so.
    func claim(_ card: TaskCard, by actor: BoardActor, note: String = "") throws {
        // A hub gives its cards out itself, to its agents through its /mcp: it takes no claim from a person's Mac.
        if let hub, hub.covers(card) { throw ClaimProblem.hub }
        try boardChange(card, by: actor) {
            try claimHere(card, by: actor, note: note)
        }
    }

    private func claimHere(_ card: TaskCard, by actor: BoardActor, note: String) throws {
        let before = card.column
        // Taken over from whoever had it: the timeline says so, for them and for you.
        let from = BoardRules.isClaimed(card.state, at: Date()) ? card.assignee.flatMap { $0 == actor.name ? nil : $0 } : nil
        card.state = try BoardRules.claim(card.state, by: actor, at: Date(), waitingOn: actor.isAgent ? waitingOn(card) : [])
        // You took it over: a run Binders started for it stops, which the router's record notes.
        if !actor.isAgent, from != nil {
            dispatcher?.stop(card.id)
            RouterLogFile.shared.outcome("stopped", card: card.id, todo: card.sourceRef)
        }
        log(card, .claimed, by: actor, text: from.map { "Took it over from \($0)." } ?? note, from: before, to: card.column)
    }

    /// Moving a card, with `note` on the timeline to say why when there's a reason to give: a run that stopped, or what an
    /// agent's status address said.
    func move(_ card: TaskCard, to column: BoardColumn, by actor: BoardActor, note: String = "") throws {
        guard card.column != column else { return }
        try boardChange(card, by: actor) {
            try moveHere(card, to: column, by: actor, note: note)
        }
    }

    private func moveHere(_ card: TaskCard, to column: BoardColumn, by actor: BoardActor, note: String) throws {
        lapseIfQuiet(card, before: actor)
        let before = card.column
        guard before != column else { return }
        card.state = try BoardRules.move(card.state, to: column, by: actor, agentsMayFinish: agentsMayFinish(card), at: Date(),
                                         waitingOn: actor.isAgent ? waitingOn(card) : [])
        card.position = Date().timeIntervalSinceReferenceDate
        // Back from Review to the agent that did it: the timeline tells the agent, whose claim starts over.
        let sentBack = !actor.isAgent && before == .review && column == .inProgress && card.assigneeIsAgent
        log(card, .moved, by: actor, text: sentBack ? "Sent back to \(card.assignee ?? "the agent")." : note, from: before, to: column)
        follow(card, from: before)
    }

    /// A progress report, with any links it brings. Keeps an agent's claim alive, unless it's the last word of a run that's
    /// ending (`renewing` false).
    func report(_ card: TaskCard, progress: String, links: [String] = [], by actor: BoardActor, renewing: Bool = true) {
        boardChange(card, by: actor) {
            reportHere(card, progress: progress, links: links, by: actor, renewing: renewing)
        }
    }

    private func reportHere(_ card: TaskCard, progress: String, links: [String], by actor: BoardActor, renewing: Bool) {
        let added = links.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !card.links.contains($0) }
        card.links += added
        if renewing { card.state = BoardRules.renew(card.state, by: actor, at: Date()) }
        var text = progress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !added.isEmpty { text += (text.isEmpty ? "" : "\n") + added.map { "→ \($0)" }.joined(separator: "\n") }
        log(card, .progress, by: actor, text: text)
    }

    /// An agent's word that it's still at it, with nothing new to say (its status address said working again), or
    /// Binders keeping a card it holds for one while agents are paused: its claim is kept alive, and the timeline gets no
    /// line for it.
    func keepAlive(_ card: TaskCard, by actor: BoardActor, at now: Date = Date()) {
        let next = BoardRules.renew(card.state, by: actor, at: now)
        guard next != card.state else { return }
        boardChange(card, by: actor) {
            card.state = next
            if let holder = card.assignee, card.assigneeIsAgent, dispatcher?.registry.movedByHand(holder) == true {
                card.claimExpiresAt = nil
            }
            store.save()
        }
    }

    /// An agent's question: the card waits in Blocked, and the question rings on this Mac with a box to answer it.
    func ask(_ card: TaskCard, question: String, by actor: BoardActor) throws {
        try boardChange(card, by: actor) {
            try askHere(card, question: question, by: actor)
        }
    }

    private func askHere(_ card: TaskCard, question: String, by actor: BoardActor) throws {
        lapseIfQuiet(card, before: actor)
        let before = card.column
        // A question asked while another still waits replaces it without ringing again.
        let replacing = before == .blocked
            && BoardRules.waitingQuestion(in: timeline(card.id).map { (kind: $0.kindRaw, to: $0.toColumn ?? "") }) != nil
        card.state = try BoardRules.ask(card.state, by: actor, at: Date())
        log(card, .question, by: actor, text: question, from: before, to: card.column)
        if actor.isAgent { MacNotifications.shared.post(question: question, on: card, by: actor.name, quietly: replacing) }
    }

    // MARK: Approvals

    /// Posted when an agent asks your approval, with the card's id ("card") and the request's ("approval"), for the phone
    /// link to tell phones that read it.
    static let approvalAsked = Notification.Name("BindersApprovalAsked")

    /// Why an approval can't be asked or decided, in words for whoever tried.
    enum ApprovalProblem: LocalizedError {
        case notAnAgent, nothingWaits, changed, notYou
        var errorDescription: String? {
            switch self {
            case .notAnAgent: "Only an agent asks for the user's approval."
            case .nothingWaits: "Nothing on this card waits for your approval now."
            case .changed: "It asks about something else now. Look at it again before you decide."
            case .notYou: "Only the user decides on an approval."
            }
        }
    }

    /// An agent asks your approval before it sends, posts, buys or deletes something outside Binders: the card waits in
    /// Blocked, as for a question, with exactly what it asks on its timeline. It rings on this Mac, and on phones that read
    /// approvals, in words safe for the Lock Screen. A new request while one waits replaces it. Returns the request.
    @discardableResult
    func requestApproval(_ card: TaskCard, _ approval: AgentApproval, by actor: BoardActor) throws -> TaskEvent {
        guard actor.isAgent else { throw ApprovalProblem.notAnAgent }
        var asked: TaskEvent?
        try boardChange(card, by: actor) {
            lapseIfQuiet(card, before: actor)
            let before = card.column
            card.state = try BoardRules.ask(card.state, by: actor, at: Date())
            asked = log(card, .approval, by: actor, text: approval.timelineText, from: before, to: card.column)
        }
        guard let event = asked else { throw ApprovalProblem.nothingWaits }
        MacNotifications.shared.post(approval: approval, on: card, by: actor.name)
        NotificationCenter.default.post(name: Self.approvalAsked, object: nil, userInfo: ["card": card.id, "approval": event.id])
        return event
    }

    /// Your decision on what the card waits for your approval on, here or from your iPhone (`device` is its name): first
    /// the receipt, by Binders, with who decided, where, when and exactly what; then your answer, "Approved" or "Declined:
    /// <reason>", which sends the card back to work and wakes its agent as any answer does. `approval`, the request's id
    /// when the decision came from somewhere that showed it, must still be the one waiting. Returns what to tell you.
    @discardableResult
    func decide(_ card: TaskCard, approval: UUID? = nil, approve: Bool, reason: String = "", by actor: BoardActor, on device: String) throws -> String {
        guard !actor.isAgent else { throw ApprovalProblem.notYou }
        guard let waiting = card.waitingApproval(events: timeline(card.id)) else { throw ApprovalProblem.nothingWaits }
        if let approval, approval != waiting.event.id { throw ApprovalProblem.changed }
        let agent = waiting.event.author
        let now = Date()
        boardChange(card, by: actor) {
            log(card, .decision, by: Self.binders, text: waiting.approval.receipt(approved: approve, reason: reason, by: actor.name, on: device, at: now))
            let before = card.column
            card.state = BoardRules.answered(card.state, by: actor, at: now)
            log(card, .answer, by: actor, text: AgentApproval.answer(approved: approve, reason: reason), from: before, to: card.column)
        }
        return approve ? "Approved. \(agent) can go ahead with exactly that." : "Declined. \(agent) hears that it shouldn't."
    }

    /// A comment. From a person on a blocked card, it's the answer, and the card goes back to work. On a card an agent
    /// holds in progress, it wakes that agent (`AgentDispatcher`), unless `wake` turns that off (a phone's comment).
    /// Returns why it wasn't made, or nil.
    @discardableResult
    func comment(_ card: TaskCard, text: String, by actor: BoardActor, wake: CommentWake = .asTheBoardSays) -> String? {
        boardChange(card, by: actor) {
            let before = card.column
            let now = Date()
            card.state = BoardRules.answered(BoardRules.renew(card.state, by: actor, at: now), by: actor, at: now)
            let answered = before == .blocked && card.column != .blocked
            log(card, answered ? .answer : .comment, by: actor, text: text, from: answered ? before : nil, to: answered ? card.column : nil, wake: wake)
        }
        return nil
    }

    func release(_ card: TaskCard, note: String = "", by actor: BoardActor) throws {
        try boardChange(card, by: actor) {
            let before = card.column
            card.state = try BoardRules.release(card.state, by: actor, at: Date())
            log(card, .released, by: actor, text: note, from: before, to: card.column)
        }
    }

    func complete(_ card: TaskCard, summary: String, by actor: BoardActor) throws {
        try boardChange(card, by: actor) {
            try completeHere(card, summary: summary, by: actor)
        }
    }

    private func completeHere(_ card: TaskCard, summary: String, by actor: BoardActor) throws {
        let before = card.column
        card.state = try BoardRules.complete(card.state, by: actor, agentsMayFinish: agentsMayFinish(card), at: Date(),
                                             waitingOn: actor.isAgent ? waitingOn(card) : [])
        card.position = Date().timeIntervalSinceReferenceDate
        log(card, .completed, by: actor, text: summary, from: before, to: card.column)
        follow(card, from: before)
    }

    /// Who a card is meant for: a name, or nil for no one in particular. From you it's an assignment Binders can act on.
    /// From an agent, or from Binders itself on something it heard (`suggesting`), it's a suggestion that waits for your
    /// tap, and it never replaces your own choice: false when it was refused for that. The only writer of `meantFor`.
    /// `why`, for Binders' own suggestion, goes after it on the timeline: "Suggested for Codex: it looks like Codex's
    /// work."
    /// `placedBy`: an agent placed the card under the binder's Agents may place work items: the assignment is by
    /// Binders, saying so ("Meant for X: placed by Y, which this binder lets place work items.").
    @discardableResult
    func assign(_ card: TaskCard, to name: String?, by actor: BoardActor, suggesting: Bool = false, why: String? = nil,
                placedBy: String? = nil) -> Bool {
        var assigned = true
        boardChange(card, by: actor) {
            assigned = assignHere(card, to: name, by: actor, suggesting: suggesting, why: why, placedBy: placedBy)
        }
        return assigned
    }

    private func assignHere(_ card: TaskCard, to name: String?, by actor: BoardActor, suggesting: Bool, why: String?, placedBy: String? = nil) -> Bool {
        let name = name.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
        let suggestion = actor.isAgent || suggesting
        if suggestion, card.meantFor != nil, !card.meantForByAgent { return card.meantFor == name }
        let byAgent = name != nil && suggestion
        guard card.meantFor != name || card.meantForByAgent != byAgent else { return true }
        card.meantFor = name
        card.meantForByAgent = byAgent
        let line = name.map { who in
            if let placedBy, !byAgent { return "Meant for \(who): placed by \(placedBy), which this binder lets place work items." }
            return byAgent ? (why.map { reason in "Suggested for \(who): \(reason)" } ?? "Suggested for \(who).") : "Meant for \(who)."
        }
        log(card, .assigned, by: actor, text: line ?? "Meant for no one in particular.")
        return true
    }

    /// Give to, your tap on a card, in Needs you or on a notification: meant for `name` by you, and from Backlog into Ready,
    /// where the hand-off happens. An explicit hand-off, so the agent is woken at once rather than after the moment an
    /// edit waits. A tap that changes nothing wakes nothing; Wake Now does that. Returns what the hand-off did, for
    /// Binders' own start, which says so on the card only once the agent was woken.
    @discardableResult
    func give(_ card: TaskCard, to name: String, by actor: BoardActor) -> AgentDispatcher.HandOff {
        let before = (card.column, card.meantFor, card.meantForByAgent)
        assign(card, to: name, by: actor)
        if card.column == .backlog { try? move(card, to: .ready, by: actor) }
        // Your Give to, for the router's record of what became of its decisions.
        if !actor.isAgent, actor.name != Self.binders.name {
            RouterLogFile.shared.outcome("gave", card: card.id, todo: card.sourceRef, to: AgentRegistry.shared.agent(named: name)?.id)
        }
        // A teammate's card that waits for your Give to (Take cards from teammates, or the start switch, off): this is it.
        if !actor.isAgent, actor.name != Self.binders.name, before == (card.column, card.meantFor, card.meantForByAgent),
           dispatcher?.waitsForYourGiveTo(card) == true {
            return dispatcher?.handOff(card) ?? .notWoken("Binders isn't waking agents now.")
        }
        guard !actor.isAgent, before != (card.column, card.meantFor, card.meantForByAgent) else { return .notWoken("Nothing changed on the card.") }
        return dispatcher?.handOff(card) ?? .notWoken("Binders isn't waking agents now.")
    }

    /// Why a card can't be taken here.
    enum ClaimProblem: LocalizedError {
        case hub
        var errorDescription: String? {
            "This board is linked to a hub, where cards are taken: an agent the hub knows takes it there, with claim_task on the hub's /mcp. Nothing changed here."
        }
    }

    /// Why a card can't move to another binder now, in words for whoever asked; nil when it can.
    enum MoveProblem: LocalizedError {
        case held(String), done, hub
        var errorDescription: String? {
            switch self {
            case .hub: "A card doesn't move to or from a binder linked to a hub. Make a new card on the other board instead."
            case .held(let binder): "Someone is working on it, so it stays on the \(binder) board until they let it go."
            case .done: "It's done, so it stays where it was finished."
            }
        }
    }

    /// Move to: the card goes to another binder's board, with its to-do. Not while someone holds it, and not once it's
    /// done. Binders' own suggestion goes when the new binder's agents don't include that one. It logs an edit, which
    /// wakes no one.
    func moveBinder(_ card: TaskCard, to binder: BinderRecord, by actor: BoardActor, takes: (String, UUID) -> Bool = { _, _ in true }) throws {
        guard card.binderID != binder.id else { return }
        let from = store.binder(card.binderID)?.name ?? "General"
        if BoardRules.isClaimed(card.state, at: Date()) { throw MoveProblem.held(from) }
        if card.column == .done { throw MoveProblem.done }
        if let hub, hub.covers(card) || hub.covers(binder: binder.id) { throw MoveProblem.hub }
        card.binderID = binder.id
        if let todo = card.sourceRef, let commitment = store.commitments().first(where: { $0.id.uuidString == todo }) {
            commitment.binderID = binder.id
        }
        log(card, .edited, by: actor, text: "Moved from the \(from) board to the \(binder.name) board.")
        if card.meantForByAgent, let suggested = card.meantFor, !takes(suggested, binder.id) {
            card.meantFor = nil
            card.meantForByAgent = false
            log(card, .assigned, by: Self.binders, text: "Meant for no one in particular: \(suggested) doesn't take the \(binder.name) board's cards.")
        }
    }

    // MARK: What Binders found in the binder

    /// Who writes what the card's binder knows on it: Binders itself, neither you nor an agent.
    static let binders = BoardActor(name: "Binders", kind: .person)

    /// What Binders wrote on the card from its binder when it first went to an agent ("From your binders"), or nil. One
    /// you deleted is still here, empty, so it isn't written again.
    func contextNote(on card: TaskCard) -> TaskEvent? {
        timeline(card.id).first { $0.kind == .context }
    }

    /// Writes it: once a card, by Binders, so it wakes no one.
    func addContext(_ card: TaskCard, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, contextNote(on: card) == nil else { return }
        log(card, .context, by: Self.binders, text: text)
    }

    /// Your edit of it, or Binders taking out what an agent may not read. Empty deletes it, and it stays deleted.
    func editContext(_ event: TaskEvent, text: String) {
        guard event.kind == .context else { return }
        event.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let card = card(event.taskID) { card.updatedAt = Date() }
        store.save()
    }

    /// A note by Binders itself on the card's timeline: why a run didn't start, what Binders committed when a run ended. It
    /// changes nothing on the card and wakes no one, in whatever column the card is: unlike a comment, it never answers a
    /// card that waits in Blocked, and never wakes the agent that holds the card. On a binder linked to a hub it stays on
    /// this Mac (what a run here did, where it wrote, why a change here didn't go through), unless it's for the team
    /// (`toTeam`: why a teammate's card waits, which card is ready now). `sectionChange`: the line says
    /// the card's section changed (`SectionChangeMark`), kept with it for what reaches an agent.
    func note(_ card: TaskCard, text: String, toTeam: Bool = false, sectionChange: SectionChangeMark? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard toTeam else {
            changeLines.append([])
            log(card, .comment, by: Self.binders, text: text, sectionChange: sectionChange)
            changeLines.removeLast()
            if changeLines.isEmpty { flushDeferred() }
            return
        }
        boardChange(card, by: Self.binders) {
            log(card, .comment, by: Self.binders, text: text)
        }
    }

    /// The receipt for a wake: who was woken, how, and where its run writes what it says (linked on the card). By the
    /// agent, as a lapse is, so it wakes nothing.
    func woke(_ card: TaskCard, agent: String, text: String, log file: URL?) {
        // On a hub's board the receipt stays on this Mac, with its log file: it says how the agent was woken and where
        // (a web hook's host, a run's folder), which isn't the team's.
        if let file, !card.links.contains(file.absoluteString) { card.links.append(file.absoluteString) }
        changeLines.append([])
        log(card, .woke, by: BoardActor(name: agent, kind: .agent), text: text)
        changeLines.removeLast()
        if changeLines.isEmpty { flushDeferred() }
    }

    // MARK: The Manager's tidying (lane MG1)

    /// A card's title, description or links, changed by the Manager or put back by its Undo, with a line on the timeline by
    /// whoever did it. An edit wakes no one.
    func tidy(_ card: TaskCard, title: String? = nil, details: String? = nil, links: [String]? = nil, by actor: BoardActor, line: String) {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { card.title = title }
        if let details { card.details = details }
        if let links { card.links = links }
        log(card, .edited, by: actor, text: line)
    }

    /// A card the Manager closes, or its Undo opens again, between Backlog, Ready and Done: moved by Binders, which wakes no
    /// one, with whose doing it was in the note.
    func tidyMove(_ card: TaskCard, to column: BoardColumn, note: String) throws {
        try move(card, to: column, by: Self.binders, note: note)
    }

    func edit(_ card: TaskCard, title: String? = nil, details: String? = nil, due: Date?? = nil, by actor: BoardActor) {
        let before = hub?.covers(card) == true ? HubBoard.Before(card) : nil
        defer { if let before { hub?.sent(card, before: before, lines: [], by: actor) } }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { card.title = title }
        if let details { card.details = details }
        if let due { card.dueAt = due }
        card.updatedAt = Date()
        store.save()
    }

    /// Returns why it wasn't deleted, or nil.
    @discardableResult
    func delete(_ card: TaskCard) -> String? {
        // On a hub's board, it goes for everyone.
        if let hub, hub.covers(card) { hub.deleted(card) }
        removeHere(card)
        return nil
    }

    /// A card gone from this Mac only: deleted here, or by the hub (`HubBoard`).
    func removeHere(_ card: TaskCard) {
        // Its window goes first, with what it shows, so no view reads the card once it's gone.
        CardWindows.shared.cardDeleted(card.id)
        MacNotifications.shared.withdrawQuestion(card.id)
        MacNotifications.shared.withdrawStatus(card.id)
        dispatcher?.forget(card.id)
        // The cards that waited for it wait for it no longer: one whose last wait it was may be ready for its agent now.
        let waiting = waiting(on: card)
        for event in timeline(card.id) { store.context.delete(event) }
        store.context.delete(card)
        store.save()
        for other in waiting { dispatcher?.waitEnded(on: other) }
    }

    /// Hands lapsed agents' cards back to Ready. A card waiting on you in Blocked or Review has no lease: one left there by
    /// an earlier version loses it, so no one reads a time that means nothing.
    func sweep(now: Date = Date()) {
        let held = (try? store.context.fetch(FetchDescriptor<TaskCard>(predicate: #Predicate { $0.assigneeIsAgent }))) ?? []
        var cleared = false
        for card in held {
            if card.claimExpiresAt != nil, let holder = card.assignee, dispatcher?.registry.movedByHand(holder) == true {
                // An agent whose cards you move yourself has no time limit on them, one set before it was told so included.
                card.claimExpiresAt = nil
                cleared = true
            } else if let next = BoardRules.expire(card.state, at: now) {
                lapse(card, to: next)
            } else if card.claimExpiresAt != nil, card.column == .blocked || card.column == .review {
                card.claimExpiresAt = nil
                cleared = true
            }
        }
        if cleared { store.save() }
    }

    /// A card whose agent went quiet is let go before someone else acts on it, as the sweep would within the minute.
    private func lapseIfQuiet(_ card: TaskCard, before actor: BoardActor) {
        guard card.assignee != actor.name, card.assignee.map({ dispatcher?.registry.movedByHand($0) == true }) != true,
              let next = BoardRules.expire(card.state, at: Date()) else { return }
        lapse(card, to: next)
    }

    private func lapse(_ card: TaskCard, to next: CardState) {
        let who = card.assignee ?? "The agent"
        let before = card.column
        card.state = next
        log(card, .lapsed, by: BoardActor(name: who, kind: .agent), text: "\(who) went quiet for \(Int(BoardRules.lease / 60)) minutes, so the card is free again.",
            from: before, to: card.column)
    }

    /// A card's to-do is ticked off when the card reaches Done, and opened again if the card leaves Done.
    /// Also for a hub's card, as the hub moves it (HubBoard).
    func follow(_ card: TaskCard, from before: BoardColumn) {
        guard let todo = card.sourceRef, (before == .done) != (card.column == .done) else { return }
        if Todos.setDone(todo, card.column == .done, commitments: commitments) == nil {
            Log.app.info("A card's to-do has changed or is gone, so it wasn't ticked")
        }
    }

    @discardableResult
    private func log(_ card: TaskCard, _ kind: TaskEvent.Kind, by actor: BoardActor, text: String = "", from: BoardColumn? = nil, to: BoardColumn? = nil,
                     wake: CommentWake = .asTheBoardSays, sectionChange: SectionChangeMark? = nil) -> TaskEvent {
        // An agent whose cards you move yourself has no lease to keep: a claim, an answer or a send-back doesn't start one.
        if card.claimExpiresAt != nil, card.assigneeIsAgent, let holder = card.assignee,
           dispatcher?.registry.movedByHand(holder) == true {
            card.claimExpiresAt = nil
        }
        card.updatedAt = Date()
        let event = TaskEvent(taskID: card.id, kind: kind, author: actor, text: text, from: from, to: to)
        event.sectionChange = sectionChange?.json
        store.context.insert(event)
        // A line of a change being made on a hub's board waits with it; what Binders found in your binders stays here.
        if !changeLines.isEmpty, kind != .context { changeLines[changeLines.count - 1].append(event) }
        store.save()
        // Answered, moved, taken over or let go: the question it was waiting on no longer needs you.
        if from == .blocked, card.column != .blocked { MacNotifications.shared.withdrawQuestion(card.id) }
        // An agent picked up a card you handed it, or finished one for you to check: a word, quiet for the first.
        if actor.isAgent, let to,
           let news = BoardRules.news(before: from, now: to, byAgent: true, meantFor: card.meantFor, confirmed: !card.meantForByAgent) {
            MacNotifications.shared.post(status: .init(news), on: card, by: actor.name, summary: kind == .completed ? text : "")
        }
        if from == .review, card.column != .review { MacNotifications.shared.withdrawStatus(card.id) }
        // A hub's agents take its cards through its runner and /mcp: nothing here is woken for them.
        if hub?.covers(card) != true {
            dispatcher?.noticed(card, kind, by: actor, from: from, to: to, wake: wake, cause: wakeCause)
        }
        return event
    }
}

/// Whom a comment of yours may wake: the agent the board's rules say (a comment on this Mac, or from `Binders --mcp`), only
/// the agent a phone named as the one it asked you about (`to`, from a phone that lists `LinkFeatures.commentsAskFirst`),
/// or no one (a phone that doesn't ask first). It only ever narrows a comment's wake, so nothing can use it to wake one.
enum CommentWake: Equatable {
    case asTheBoardSays
    /// Only this agent, by name: "" when the phone named no one.
    case only(String)
    case none

    /// As a comment's request carries it to the app (`wake_for`): "none", or "only:" and the name. Nil for the board's rule.
    var field: String? {
        switch self {
        case .asTheBoardSays: nil
        case .only(let name): "only:" + name
        case .none: "none"
        }
    }

    /// From a request's `wake_for`; the board's rule when it has none. Anything else it says wakes no one.
    init(field: String?) {
        guard let field else {
            self = .asTheBoardSays
            return
        }
        self = field.hasPrefix("only:") ? .only(String(field.dropFirst("only:".count))) : .none
    }
}
