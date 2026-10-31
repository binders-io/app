import Foundation
import SwiftData
import BindersKit

/// The boards of binders linked to a hub (HubLinks), through the hub's change log. The hub is the referee: its cards are
/// what this Mac shows, and this Mac's changes to them are changes in its log.
/// - coming: for each of the hub's Binders a linked binder is in, GET /api/state, then GET /api/live from that version,
///   read again after a drop (`HubCards.Board`); each card that changed is written here (`TaskCard`, its lines as
///   `TaskEvent`s, each once, by its `hubKey`). A card the hub no longer has in a linked project goes from this Mac, once the
///   hub has had it; one made here, or put back by Undo, that the hub hasn't answered for yet (`TaskCard.hubPut`) goes up
///   again, with the same change id, and stays.
/// - going: `BoardService` makes a change here at once and hands it over (`sent`): a claim as card.claim, which the hub
///   decides; a move, an answer, a decision or an edit as card.update with its first line; the lines after it as
///   card.activity; a new card as card.put; a deleted one as card.delete, and one put back by Undo as the card.put of the
///   card as the hub had it. What the hub refuses (a claim it gave someone else included) isn't sent again: the card is put
///   back as the hub has it, and a line by Binders says why. A card.put is the exception: kept on the card until the hub
///   answers it, it's sent again until it does.
///
/// The hub's agents work on its cards through its runner and /mcp, so a change that comes from the hub wakes no agent
/// here.
@MainActor
@Observable
final class HubBoard {
    static let shared = HubBoard()

    @ObservationIgnored weak var board: BoardService?
    private var account: HubAccount { .shared }
    @ObservationIgnored private var store: Store { Store.shared }

    /// Whether each of the hub's Binders is followed live now, by its id.
    private(set) var live: Set<String> = []
    /// What went wrong reaching one of the hub's Binders, in words, by its id.
    private(set) var problems: [String: String] = [:]

    /// Opens the live feed (the self-tests feed it themselves).
    @ObservationIgnored var openLive: (URLRequest) -> AsyncThrowingStream<Data, Error> = HubBoard.webSocket
    /// How long after a drop the feed is opened again, doubling to a minute.
    @ObservationIgnored var retry: Duration = .seconds(2)
    /// How long a claim waits for the feed to bring the hub's decision before the hub's state is read for it.
    @ObservationIgnored var decisionWait: Duration = .seconds(3)
    /// How long after a card.put that didn't reach the hub the ones waiting are sent again.
    @ObservationIgnored var putRetry: Duration = .seconds(30)

    /// The binders linked here, by id, and where.
    @ObservationIgnored private var linked: [UUID: HubLink.Place] = [:]
    @ObservationIgnored private var feeds: [String: Feed] = [:]
    /// Changes sent and not yet answered: the self-tests wait for them.
    @ObservationIgnored private(set) var sending = 0
    /// The card.puts on their way, by card here: one isn't sent again while it's on its way, nor taken as answered.
    @ObservationIgnored private var putting: [UUID: Int] = [:]
    /// The card.deletes on their way, by the card's id on the hub: a card put back goes after its deletion.
    @ObservationIgnored private var deleting: [String: Task<Void, Never>] = [:]
    /// The hub's Binders whose waiting card.puts are sent again soon.
    @ObservationIgnored private var retrying: Set<String> = []

    private struct Feed {
        var hub: URL
        var space: String
        var board = HubCards.Board()
        var task: Task<Void, Never>?
    }

    // MARK: Which boards

    /// Follows the hub for every linked binder whose link has finished, and stops for the rest: at launch, and after
    /// signing in or out, linking or unlinking.
    func follow() {
        var places: [UUID: HubLink.Place] = [:]
        if account.isSignedIn, let hub = account.address {
            for binder in store.binders(includeArchived: true) {
                guard let place = HubLinks.place(of: binder), place.uploaded, place.hub == hub else { continue }
                places[binder.id] = place
            }
        }
        linked = places
        let wanted = Set(places.values.map(\.space))
        for (space, feed) in feeds where !wanted.contains(space) {
            feed.task?.cancel()
            feeds[space] = nil
            live.remove(space)
            problems[space] = nil
        }
        for space in wanted {
            if let feed = feeds[space] {
                // A binder linked into a Binder already followed: what the hub has for it is written here now.
                apply(space, cards: Set(feed.board.cards.keys), full: true)
                continue
            }
            guard let place = places.values.first(where: { $0.space == space }) else { continue }
            feeds[space] = Feed(hub: place.hub, space: space)
            feeds[space]?.task = Task { [weak self] in await self?.run(space) }
        }
    }

    func stop() {
        for feed in feeds.values { feed.task?.cancel() }
        feeds = [:]
        linked = [:]
        live = []
    }

    /// Whether a card is on a linked binder's board, so the hub decides what becomes of it.
    func covers(_ card: TaskCard) -> Bool {
        card.binderID.map(covers(binder:)) ?? false
    }

    func covers(binder: UUID) -> Bool { linked[binder] != nil }

    private func binder(forProject project: String, in space: String) -> UUID? {
        linked.first { $0.value.space == space && $0.value.binder == project }?.key
    }

    /// The hub's cards in a binder linked here, for the self-tests.
    func hubCards(in binder: UUID) -> [HubCards.Card] {
        guard let place = linked[binder] else { return [] }
        return feeds[place.space]?.board.cards(in: place.binder) ?? []
    }

    // MARK: Coming

    private func run(_ space: String) async {
        var wait = retry
        while !Task.isCancelled, feeds[space] != nil {
            do {
                try await load(space)
                guard let hub = feeds[space]?.hub, let version = feeds[space]?.board.version,
                      var request = account.authorized("api/live") else { return }
                var parts = URLComponents(url: hub.appendingPathComponent("api/live"), resolvingAgainstBaseURL: false)
                parts?.scheme = hub.scheme == "https" ? "wss" : "ws"
                parts?.queryItems = [URLQueryItem(name: "since", value: String(version))]
                guard let url = parts?.url else { return }
                request.url = url
                request.setValue(space, forHTTPHeaderField: "x-binders-space")
                request.timeoutInterval = 60
                live.insert(space)
                problems[space] = nil
                wait = retry
                for try await message in openLive(request) {
                    guard feeds[space] != nil, let entries = HubCards.entries(fromLive: message), !entries.isEmpty else { continue }
                    guard let touched = feeds[space]?.board.apply(entries) else { continue }
                    apply(space, cards: touched)
                }
                live.remove(space)
            } catch is CancellationError {
                live.remove(space)
                return
            } catch {
                live.remove(space)
                problems[space] = error is Refusal || error is HubLinks.Problem ? Self.words(of: error) : "Lost the hub: \(error.localizedDescription). Trying again."
                if !account.isSignedIn { return }
            }
            try? await Task.sleep(for: wait)
            wait = min(wait * 2, .seconds(60))
        }
    }

    /// The hub's state, read afresh and written here.
    private func load(_ space: String) async throws {
        let (data, _) = try await ask("api/state", space: space)
        guard let board = HubCards.Board(state: data) else { throw HubLinks.Problem("The hub sent something that isn't its state.") }
        guard feeds[space] != nil else { return }
        feeds[space]?.board = board
        apply(space, cards: Set(board.cards.keys), full: true)
    }

    /// Writes the hub's cards with these ids here. `full`: everything the hub has was read, so a card in a linked binder
    /// that it doesn't have went from the hub, or never got there.
    private func apply(_ space: String, cards ids: Set<String>, full: Bool = false) {
        guard let board, let hubBoard = feeds[space]?.board else { return }
        var changed = false
        for id in ids {
            let local = board.card(HubCards.localID(id))
            guard let card = hubBoard.cards[id], let binder = binder(forProject: card.binderId, in: space) else {
                // Deleted on the hub, or moved to a project that isn't linked here. One put back here since goes up after.
                if let local, local.hubPut.isEmpty, local.binderID.flatMap({ linked[$0]?.space }) == space {
                    board.removeHere(local)
                    changed = true
                }
                continue
            }
            write(card, into: local, binder: binder, hub: hubBoard, board: board)
            changed = true
        }
        if full {
            let here = linked.filter { $0.value.space == space }
            for (binder, place) in here {
                let known = Set(hubBoard.cards(in: place.binder).map(\.id))
                for card in board.cards(in: binder) where !known.contains(hubID(of: card)) {
                    if card.hubCard.isEmpty || !card.hubPut.isEmpty {
                        // Made here, or put back, and the hub hasn't had it: it goes up now, and stays here till then.
                        resend(card, place: place)
                    } else {
                        // The hub had it, and has it no longer.
                        board.removeHere(card)
                        changed = true
                    }
                }
            }
        }
        if changed { store.save() }
    }

    private func write(_ hub: HubCards.Card, into local: TaskCard?, binder: UUID, hub board: HubCards.Board, board service: BoardService) {
        let card: TaskCard
        if let local {
            card = local
        } else {
            card = TaskCard(title: hub.title, binderID: binder, column: hub.column)
            card.id = HubCards.localID(hub.id)
            card.createdAt = hub.createdAt ?? Date()
            card.position = card.createdAt.timeIntervalSinceReferenceDate
            card.createdBy = name(hub.createdBy, on: board)
            if let note = hub.noteId.flatMap(UUID.init(uuidString:)), store.note(note) != nil {
                card.sourceKind = NoteWorkCards.noteKind
                card.sourceID = note.uuidString
                card.sourceTitle = store.note(note)?.title
            }
            store.context.insert(card)
        }
        card.hubCard = hub.id
        // The hub has it: its card.put was answered, unless one is still on its way (a card put back, before its deletion).
        if !card.hubPut.isEmpty, putting[card.id] == nil { card.hubPut = "" }
        card.binderID = binder
        if card.title != hub.title, !hub.title.isEmpty { card.title = hub.title }
        let details = HubCards.details(brief: hub.brief, doneWhen: hub.doneWhen)
        if card.details != details { card.details = details }
        card.state = CardState(column: hub.column, assignee: hub.agentId.map { board.name(of: $0) }, assigneeIsAgent: hub.agentId != nil)
        let meant = hub.meantFor.map { board.name(of: $0) }
        if card.meantFor != meant || card.meantForByAgent {
            card.meantFor = meant
            card.meantForByAgent = false
        }
        let waits = hub.waitsFor.map { HubCards.localID($0).uuidString }
        if card.waitsFor != waits { card.waitsFor = waits }
        card.updatedAt = hub.updatedAt ?? Date()

        // Its lines, each once: one written here and sent is the hub's line already.
        let timeline = service.timeline(card.id)
        var known = Set(timeline.compactMap(\.hubKey))
        var unmatched = timeline.filter { $0.hubKey == nil }
        for line in hub.activity {
            let key = line.key(card: hub.id)
            guard !known.contains(key) else { continue }
            known.insert(key)
            let kind = HubCards.localKind(line.kind)
            let at = line.date ?? Date()
            if let index = unmatched.firstIndex(where: { $0.kindRaw == kind && (kind == "created" || abs($0.createdAt.timeIntervalSince(at)) < 0.002) }) {
                unmatched[index].hubKey = key
                unmatched.remove(at: index)
                continue
            }
            let isAgent = board.isAgent(line.by)
            let event = TaskEvent(taskID: card.id, kind: TaskEvent.Kind(rawValue: kind) ?? .progress,
                                  author: BoardActor(name: name(line.by, on: board), kind: isAgent ? .agent : .person), text: line.text)
            // What a question waits on, as this Mac's rules read a timeline: it's answered once something moves the card.
            switch kind {
            case "question": event.toColumn = BoardColumn.blocked.rawValue
            case "answer", "claimed": event.toColumn = BoardColumn.inProgress.rawValue
            case "released": event.toColumn = BoardColumn.ready.rawValue
            case "completed", "moved": event.toColumn = hub.column.rawValue
            default: break
            }
            event.createdAt = at
            event.hubKey = key
            store.context.insert(event)
        }
    }

    /// Who wrote it, as this Mac's board names people: "You" for whoever is signed in, an agent by its name, Binders for
    /// the hub itself.
    private func name(_ by: String, on board: HubCards.Board) -> String {
        if by == account.person?.login { return BoardActor.you.name }
        if by == "hub" { return BoardService.binders.name }
        return board.name(of: by)
    }

    private func hubID(of card: TaskCard) -> String { card.hubCard.isEmpty ? HubLink.hubID(card.id) : card.hubCard }

    // MARK: Going

    /// A card as it was before a change made here.
    struct Before {
        let column: BoardColumn
        let assignee: String?
        let meantFor: String?
        let title: String
        let details: String
        let waitsFor: [String]

        init(_ card: TaskCard) {
            waitsFor = card.waitsFor
            column = card.column
            assignee = card.assignee
            meantFor = card.meantFor
            title = card.title
            details = card.details
        }
    }

    /// A change made here to a linked card (`BoardService`), with the lines it wrote, as the hub's change.
    func sent(_ card: TaskCard, before: Before?, lines: [TaskEvent], by actor: BoardActor) {
        guard let binder = card.binderID, let place = linked[binder], let hubBoard = feeds[place.space]?.board else { return }
        let id = hubID(of: card)
        guard hubBoard.cards[id] != nil else {
            // Not on the hub yet: it goes up whole, with what was just done to it (one put back, as the hub had it).
            if HubCards.Outgoing(json: card.hubPut).map({ !isFirstPut($0, of: card) }) == true { return resend(card, place: place) }
            return sendPut(card, place: place)
        }
        let person = account.person?.login ?? "you"
        func by(_ event: TaskEvent) -> String {
            event.authorIsAgent ? (hubBoard.agentID(named: event.author, owner: person) ?? event.author) : person
        }
        let activity: [HubCards.Activity] = lines.compactMap { event in
            guard let kind = HubCards.hubKind(event.kindRaw) else { return nil }
            let line = HubCards.Activity(at: HubCards.iso(event.createdAt), by: by(event), kind: kind, text: Self.words(of: event))
            event.hubKey = line.key(card: id)
            return line
        }

        // A claim: the hub decides who gets it.
        if let first = lines.first, first.kind == .claimed, card.column == .inProgress, let holder = card.assignee {
            // The hub writes its own line for it, at the same moment: that one takes this one's place.
            first.hubKey = nil
            guard card.assigneeIsAgent else {
                return refused(card.id, words: "On a hub's board only agents take cards. Give it to one instead.", space: place.space)
            }
            let agent = hubBoard.agentID(named: holder, owner: person) ?? holder
            let at = HubCards.iso(first.createdAt)
            var changes = [HubCards.Outgoing(change: HubCards.claim(id, agent: agent, at: at))]
            changes += activity.dropFirst().map { HubCards.Outgoing(change: HubCards.activity(id, $0)) }
            send(changes, for: card, in: place, claim: (id, agent))
            return
        }

        var fields: [String: JSONValue] = [:]
        if let before {
            if before.column != card.column { fields = HubCards.moveFields(to: card.column) }
            if card.column == .blocked, let asked = lines.last(where: { $0.kind == .question || $0.kind == .approval }) {
                fields["needsYou"] = .string(String(asked.text.prefix(1000)))
            }
            if before.title != card.title { fields["title"] = .string(String(card.title.prefix(200))) }
            if before.details != card.details {
                fields["brief"] = .string(HubCards.brief(details: card.details, doneWhen: hubBoard.cards[id]?.doneWhen ?? ""))
            }
            if before.waitsFor != card.waitsFor {
                // By the hub's ids, of the cards it has.
                let waits = card.waitsFor.compactMap(UUID.init(uuidString:)).compactMap { board?.card($0) }.map(hubID(of:)).filter { hubBoard.cards[$0] != nil }
                fields["waitsFor"] = .array(waits.map(JSONValue.string))
            }
            if before.meantFor != card.meantFor {
                if let name = card.meantFor {
                    if let agent = hubBoard.agentID(named: name, owner: person) { fields["meantFor"] = .string(agent) }
                } else {
                    fields["meantFor"] = .null
                }
            }
        }
        var changes: [HubCards.Outgoing] = []
        var rest = activity[...]
        if !fields.isEmpty {
            changes.append(HubCards.Outgoing(change: HubCards.update(id, fields: fields, activity: rest.popFirst())))
        }
        changes += rest.map { HubCards.Outgoing(change: HubCards.activity(id, $0)) }
        guard !changes.isEmpty else { return }
        send(changes, for: card, in: place)
    }

    /// A card deleted here goes from the hub: one it has, or one on its way there.
    func deleted(_ card: TaskCard) {
        let id = hubID(of: card)
        guard let binder = card.binderID, let place = linked[binder], feeds[place.space]?.board.cards[id] != nil || !card.hubPut.isEmpty else { return }
        let task = send([HubCards.Outgoing(change: HubCards.delete(id))], for: nil, in: place)
        deleting[id] = task
        Task {
            await task.value
            if deleting[id] == task { deleting[id] = nil }
        }
    }

    /// The hub's card as it has it now, for putting it back after it's deleted here (`restored`).
    func onHub(_ card: TaskCard) -> HubCards.Card? {
        guard let binder = card.binderID, let place = linked[binder] else { return nil }
        return feeds[place.space]?.board.cards[hubID(of: card)]
    }

    /// A card deleted here and put back (Undo, `CardSnapshot`), with its id on the hub: on the hub too, as the hub had it
    /// (`was`), by a card.put of its own, after its deletion. One the hub never had goes up as one made here does.
    func restored(_ card: TaskCard, as was: HubCards.Card?) {
        guard let binder = card.binderID, let place = linked[binder] else { return }
        guard let was, was.binderId == place.binder else { return sendPut(card, place: place) }
        card.hubCard = was.id
        let put = HubCards.putBack(was)
        card.hubPut = put.json
        store.save()
        let deletion = deleting[was.id]
        sending += 1
        Task {
            defer { sending -= 1 }
            await deletion?.value
            guard board?.card(card.id)?.hubPut == put.json else { return }
            send([put], for: card, in: place, put: true)
        }
    }

    /// A card the hub hasn't had yet goes up: one made here as it is now, one put back as the hub had it. Not while it's on
    /// its way already.
    private func resend(_ card: TaskCard, place: HubLink.Place) {
        guard putting[card.id] == nil else { return }
        guard let put = HubCards.Outgoing(json: card.hubPut), !isFirstPut(put, of: card) else { return sendPut(card, place: place) }
        send([put], for: card, in: place, put: true)
    }

    /// The first card.put of a card made here: its id is the card's, so the hub puts it once however often it's sent.
    private func isFirstPut(_ put: HubCards.Outgoing, of card: TaskCard) -> Bool { put.id == "card-\(hubID(of: card))" }

    private func sendPut(_ card: TaskCard, place: HubLink.Place) {
        guard let service = board else { return }
        let id = card.id
        // Not Binders' own lines, which stay on this Mac.
        let events = service.timeline(id).filter { !($0.author == BoardService.binders.name && !$0.authorIsAgent && $0.hubKey == nil) }
        let local = HubLink.LocalCard(
            id: card.id, title: card.title, details: card.details, column: card.column, links: card.links, createdBy: card.createdBy,
            createdAt: card.createdAt, updatedAt: card.updatedAt, waitsFor: card.waitsFor,
            note: card.sourceKind == NoteWorkCards.noteKind ? card.sourceID.flatMap(UUID.init(uuidString:)) : card.groupNote,
            events: events.map { HubLink.LocalEvent(kind: $0.kindRaw, author: $0.author, text: $0.text, at: $0.createdAt) })
        let known = Set(feeds[place.space]?.board.cards.keys.map { $0 } ?? [])
        guard let put = HubCards.put(local, binder: place.binder, person: account.person?.login ?? "you", known: known) else { return }
        // Its id there from now; the hub has it once it answers. Sent again until then: the same id puts it once.
        card.hubCard = HubLink.hubID(card.id)
        let outgoing = HubCards.Outgoing(id: "card-\(card.hubCard)", change: put)
        card.hubPut = outgoing.json
        store.save()
        send([outgoing], for: card, in: place, put: true)
    }

    /// A line's words on the hub: what was written, or what was done when nothing was.
    private static func words(of event: TaskEvent) -> String {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return text }
        switch event.kind {
        case .moved: return "Moved it to \(event.toColumn.flatMap(BoardColumn.init(rawValue:))?.title ?? "another column") on a Mac"
        case .claimed: return "Took it"
        case .released: return "Let it go"
        case .completed: return "Finished it"
        case .created: return "Put it on the board on a Mac"
        default: return text
        }
    }

    /// Sends changes for a card. Refused, or lost on the way, they aren't sent again: the card is put back as the hub has
    /// it, with why. A claim (`claim`: the card's id there and who asked) is the hub's to decide, so its answer is read back.
    /// A card.put (`put`) is kept on the card until the hub answers it, and sent again (`unsent`).
    @discardableResult
    private func send(_ changes: [HubCards.Outgoing], for card: TaskCard?, in place: HubLink.Place, claim: (card: String, agent: String)? = nil,
                      put: Bool = false) -> Task<Void, Never> {
        let cardID = card?.id
        let hubCardID = card.map(hubID(of:)) ?? ""
        if put, let cardID { putting[cardID, default: 0] += 1 }
        sending += 1
        return Task {
            defer {
                sending -= 1
                if put, let cardID { putting[cardID] = (putting[cardID] ?? 1) > 1 ? putting[cardID]! - 1 : nil }
            }
            do {
                let (data, _) = try await ask("api/changes", space: place.space, body: HubCards.body(client: place.client, changes: changes))
                if put, let cardID, let sent = changes.first?.id {
                    await landed(cardID, put: sent, hub: hubCardID, space: place.space, answer: data)
                    return
                }
                guard let claim else { return }
                // The log decides: someone else's claim may have come first.
                let version = HubCards.versions(fromChanges: data)?.max() ?? 0
                try await caughtUp(place.space, to: version)
                guard let hubCard = feeds[place.space]?.board.cards[claim.card], hubCard.agentId != claim.agent else { return }
                let words = if let holder = hubCard.agentId, let board = feeds[place.space]?.board {
                    "\(board.name(of: holder)) took it first on the hub."
                } else if hubCard.meantFor != nil {
                    "On the hub it's meant for \(feeds[place.space]?.board.name(of: hubCard.meantFor ?? "") ?? "another agent")."
                } else {
                    "The hub didn't give it out: it's \(hubCard.column.title) there."
                }
                refused(cardID, words: words, space: place.space)
            } catch {
                if put { return unsent(cardID, error: error, space: place.space) }
                let words = Self.words(of: error)
                refused(cardID, words: claim == nil ? words : "The hub didn't give it out. \(words)", space: place.space)
            }
        }
    }

    /// The hub answered a card.put: it has the card, or had it, when it had that change already. From now the hub says
    /// whether it's there: one it had and deleted since goes from here when its state is read.
    private func landed(_ cardID: UUID, put: String, hub hubCardID: String, space: String, answer: Data) async {
        guard let card = board?.card(cardID) else { return }
        if HubCards.Outgoing(json: card.hubPut)?.id == put {
            card.hubPut = ""
            store.save()
        }
        try? await caughtUp(space, to: HubCards.versions(fromChanges: answer)?.max() ?? 0)
        if feeds[space] != nil, feeds[space]?.board.cards[hubCardID] == nil { try? await load(space) }
    }

    /// A card.put the hub didn't answer, or didn't take: the card stays here, waiting, and a line by Binders says so, once.
    /// It goes again when the hub's state is next read whole, and, when the hub wasn't reached, in a little while too.
    private func unsent(_ cardID: UUID?, error: Error, space: String) {
        let words = Self.words(of: error)
        Log.app.info("A card didn't reach the hub: \(words, privacy: .public)")
        if let cardID, let card = board?.card(cardID), !card.hubPut.isEmpty {
            let said = words.hasSuffix(".") ? words : words + "."
            let text = "Not on the hub yet: \(said) It stays on this Mac, and goes up when the hub takes it."
            if board?.timeline(cardID).last?.text != text { board?.note(card, text: text) }
        }
        guard !(error is Refusal), !retrying.contains(space) else { return }
        retrying.insert(space)
        Task { [weak self] in
            try? await Task.sleep(for: self?.putRetry ?? .seconds(30))
            guard let self else { return }
            retrying.remove(space)
            guard let board, let hubBoard = feeds[space]?.board else { return }
            for (binder, place) in linked where place.space == space {
                for card in board.cards(in: binder) where !card.hubPut.isEmpty && hubBoard.cards[hubID(of: card)] == nil {
                    resend(card, place: place)
                }
            }
        }
    }

    /// Waits for the feed to bring the hub's log up to `version`, and reads the hub's state when it doesn't in time.
    private func caughtUp(_ space: String, to version: Int) async throws {
        let until = ContinuousClock.now + decisionWait
        while (feeds[space]?.board.version ?? 0) < version, ContinuousClock.now < until {
            try await Task.sleep(for: .milliseconds(50))
        }
        if (feeds[space]?.board.version ?? 0) < version { try await load(space) }
    }

    /// What the hub didn't take: the card as the hub has it, and a line by Binders, which stays here, saying why.
    private func refused(_ cardID: UUID?, words: String, space: String) {
        Log.app.info("The hub refused a change to a card: \(words, privacy: .public)")
        if let cardID, let card = board?.card(cardID) {
            board?.note(card, text: "Not done on the hub: \(words)")
        }
        sending += 1
        Task {
            defer { sending -= 1 }
            try? await load(space)
        }
    }

    // MARK: Asking the hub

    /// The hub answered, and didn't take it: sending it again as it is won't change that.
    private struct Refusal: Error {
        let words: String
    }

    private static func words(of error: Error) -> String {
        if let refusal = error as? Refusal { return refusal.words }
        return (error as? HubLinks.Problem)?.words ?? "Couldn't reach the hub: \(error.localizedDescription)"
    }

    private func ask(_ path: String, space: String, body: Data? = nil) async throws -> (Data, Int) {
        guard var request = account.authorized(path) else { throw HubLinks.Problem("Sign in to a hub in Settings → Team first.") }
        request.setValue(space, forHTTPHeaderField: "x-binders-space")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await account.send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            await account.refresh()
            throw HubLinks.Problem("The hub signed this Mac out. Sign in again in Settings → Team.")
        }
        guard status == 200 else {
            let words = HubLink.error(in: data).map { "The hub said: \($0)" } ?? "The hub answered \(status)."
            throw (400..<500).contains(status) ? Refusal(words: words) as Error : HubLinks.Problem(words)
        }
        return (data, status)
    }

    /// The hub's live feed over a WebSocket: each message's text.
    nonisolated static func webSocket(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = URLSession.shared.webSocketTask(with: request)
            @Sendable func receive() {
                task.receive { result in
                    switch result {
                    case .success(.string(let text)):
                        continuation.yield(Data(text.utf8))
                        receive()
                    case .success(.data(let data)):
                        continuation.yield(data)
                        receive()
                    case .success:
                        receive()
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel(with: .goingAway, reason: nil) }
            task.resume()
            receive()
        }
    }
}
