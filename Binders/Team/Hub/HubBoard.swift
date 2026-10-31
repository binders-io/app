import Foundation
import SwiftData
import BindersKit

/// The boards of binders linked to a hub (HubLinks), through the hub's change log. The hub is the referee: its cards are
/// what this Mac shows, and this Mac's changes to them are changes in its log.
/// - coming: for each of the hub's Binders a linked binder is in, GET /api/state, then GET /api/live from that version,
///   read again after a drop (`HubCards.Board`); each card that changed is written here (`TaskCard`, its lines as
///   `TaskEvent`s, each once, by its `hubKey`). A card the hub no longer has in a linked project goes from this Mac; one made
///   here that never reached the hub goes up.
/// - going: `BoardService` makes a change here at once and hands it over (`sent`): a move, an answer, a decision or an
///   edit as card.update with its first line; the lines after it as card.activity; a new card as card.put, marked as the
///   hub's (`hubCard`) once the hub has taken it; a deleted one as card.delete. What the hub refuses isn't sent again: the
///   card is put back as the hub has it, and a line by Binders says why. A new card that didn't get there is kept, and
///   goes again when the feed connects again or the card changes here.
///
/// The hub's agents work on its cards through its runner and /mcp, and only they take them: the hub takes no card.claim
/// from a person's app, so `BoardService` refuses a claim on a linked board here. A change that comes from the hub wakes no
/// agent here.
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

    /// The binders linked here, by id, and where.
    @ObservationIgnored private var linked: [UUID: HubLink.Place] = [:]
    @ObservationIgnored private var feeds: [String: Feed] = [:]
    /// Changes sent and not yet answered: the self-tests wait for them.
    @ObservationIgnored private(set) var sending = 0
    /// New cards whose card.put is on its way, or didn't get there: kept here, and not put again until the feed connects
    /// again or they change here.
    @ObservationIgnored private var unsent: Set<UUID> = []

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
                // Connected again: new cards that didn't get there go now.
                unsent = []
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
                problems[space] = (error as? HubLinks.Problem)?.words ?? "Lost the hub: \(error.localizedDescription). Trying again."
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
                // Deleted on the hub, or moved to a project that isn't linked here.
                if let local, local.binderID.flatMap({ linked[$0]?.space }) == space {
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
                    if card.hubCard.isEmpty {
                        // Made here and never reached the hub: it goes up now, unless it's on its way or just failed.
                        if !unsent.contains(card.id) { sendPut(card, place: place) }
                    } else {
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
            // Not on the hub yet: it goes up whole, with what was just done to it.
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

    /// A card deleted here goes from the hub.
    func deleted(_ card: TaskCard) {
        guard let binder = card.binderID, let place = linked[binder], feeds[place.space]?.board.cards[hubID(of: card)] != nil else { return }
        send([HubCards.Outgoing(change: HubCards.delete(hubID(of: card)))], for: nil, in: place)
    }

    private func sendPut(_ card: TaskCard, place: HubLink.Place) {
        guard let service = board else { return }
        let id = card.id
        // Binders' lines saying what the hub didn't take stay here.
        let events = service.timeline(id).filter { !($0.author == BoardService.binders.name && $0.text.hasPrefix(Self.notDone)) }
        let local = HubLink.LocalCard(
            id: card.id, title: card.title, details: card.details, column: card.column, links: card.links, createdBy: card.createdBy,
            createdAt: card.createdAt, updatedAt: card.updatedAt, waitsFor: card.waitsFor,
            note: card.sourceKind == NoteWorkCards.noteKind ? card.sourceID.flatMap(UUID.init(uuidString:)) : card.groupNote,
            events: events.map { HubLink.LocalEvent(kind: $0.kindRaw, author: $0.author, text: $0.text, at: $0.createdAt) })
        let known = Set(feeds[place.space]?.board.cards.keys.map { $0 } ?? [])
        guard let put = HubCards.put(local, binder: place.binder, person: account.person?.login ?? "you", known: known) else { return }
        let hubID = HubLink.hubID(id)
        unsent.insert(id)
        // The same id puts it once, however often it's sent.
        send([HubCards.Outgoing(id: "card-\(hubID)", change: put)], for: card, in: place) { [weak self] in
            // The hub has it: from now on, a card it doesn't have went from the hub.
            self?.unsent.remove(id)
            self?.board?.card(id)?.hubCard = hubID
            self?.store.save()
        }
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

    /// Sends changes for a card, then `taken` once the hub has them. Refused, or lost on the way, they aren't sent again:
    /// the card is put back as the hub has it, with why.
    private func send(_ changes: [HubCards.Outgoing], for card: TaskCard?, in place: HubLink.Place, taken: (() -> Void)? = nil) {
        let cardID = card?.id
        sending += 1
        Task {
            defer { sending -= 1 }
            do {
                _ = try await ask("api/changes", space: place.space, body: HubCards.body(client: place.client, changes: changes))
                taken?()
            } catch {
                refused(cardID, words: (error as? HubLinks.Problem)?.words ?? "Couldn't reach the hub: \(error.localizedDescription)", space: place.space)
            }
        }
    }

    private static let notDone = "Not done on the hub: "

    /// What the hub didn't take: the card as the hub has it, and a line by Binders, which stays here, saying why.
    private func refused(_ cardID: UUID?, words: String, space: String) {
        Log.app.info("The hub refused a change to a card: \(words, privacy: .public)")
        if let cardID, let card = board?.card(cardID) {
            board?.note(card, text: Self.notDone + words)
        }
        sending += 1
        Task {
            defer { sending -= 1 }
            try? await load(space)
        }
    }

    // MARK: Asking the hub

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
        guard status == 200 else { throw HubLinks.Problem(HubLink.error(in: data).map { "The hub said: \($0)" } ?? "The hub answered \(status).") }
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
