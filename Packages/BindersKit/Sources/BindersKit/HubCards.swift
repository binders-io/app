import CryptoKit
import Foundation

// The cards of a binder linked to a hub (HubLink), as the hub has them: read from GET /api/state, kept current by the
// entries of GET /api/live, and applied here with the same rules as shared/work.ts's `applyWork`, so this Mac reads the
// board the web app reads. A change made to one on this Mac goes up as a change in the hub's log: card.claim for a claim,
// card.update for a move, an answer or an edit, with its line, card.activity for the lines after the first, card.put for
// a new card and card.delete. The hub decides claims: of two agents asking at once only the first one applied gets it.
// Here: what can be checked without the hub or the store.

public enum HubCards {
    // MARK: What the hub has

    /// A line of a card's activity, as shared/work.ts writes it.
    public struct Activity: Equatable, Sendable {
        public let at: String
        /// A GitHub login, an agent's id, or "hub".
        public let by: String
        public let kind: String
        public let text: String

        public init(at: String, by: String, kind: String, text: String) {
            self.at = at
            self.by = by
            self.kind = kind
            self.text = text
        }

        init?(_ value: JSONValue) {
            guard case .object(let fields) = value, case .string(let at)? = fields["at"], case .string(let kind)? = fields["kind"] else { return nil }
            self.at = at
            self.kind = kind
            by = fields["by"]?.text ?? ""
            text = fields["text"]?.text ?? ""
        }

        var json: JSONValue { .object(["at": .string(at), "by": .string(by), "kind": .string(kind), "text": .string(text)]) }

        /// The same line, wherever it's read: its card, when, by whom, what kind and what it says.
        public func key(card: String) -> String { [card, at, by, kind, text].joined(separator: "\u{1F}") }

        public var date: Date? { HubCards.date(at) }
    }

    /// A card as the hub keeps it: its fields as JSON, merged as shared/work.ts merges them, so what this build doesn't
    /// read is kept as it came.
    public struct Card: Equatable, Sendable {
        public var fields: [String: JSONValue]

        public init(fields: [String: JSONValue]) { self.fields = fields }

        public var id: String { fields["id"]?.text ?? "" }
        public var binderId: String { fields["binderId"]?.text ?? "" }
        public var title: String { fields["title"]?.text ?? "" }
        public var brief: String { fields["brief"]?.text ?? "" }
        public var doneWhen: String { fields["doneWhen"]?.text ?? "" }
        public var stage: String { HubCards.current(fields["stage"]?.text ?? "ready") }
        public var agentId: String? { fields["agentId"]?.text.flatMap { $0.isEmpty ? nil : $0 } }
        public var meantFor: String? { fields["meantFor"]?.text.flatMap { $0.isEmpty ? nil : $0 } }
        public var needsYou: String? { fields["needsYou"]?.text.flatMap { $0.isEmpty ? nil : $0 } }
        public var noteId: String? { fields["noteId"]?.text.flatMap { $0.isEmpty ? nil : $0 } }
        public var createdBy: String { fields["createdBy"]?.text ?? "" }
        public var createdAt: Date? { fields["createdAt"]?.text.flatMap(HubCards.date) }
        public var updatedAt: Date? { fields["updatedAt"]?.text.flatMap(HubCards.date) }
        public var waitsFor: [String] {
            guard case .array(let items)? = fields["waitsFor"] else { return [] }
            return items.compactMap(\.text)
        }
        public var activity: [Activity] {
            guard case .array(let items)? = fields["activity"] else { return [] }
            return items.compactMap(Activity.init)
        }

        /// Where it is on this Mac's board.
        public var column: BoardColumn { HubCards.column(stage) }

        /// Fields merged in: one set to null is cleared (shared/work.ts's `merge`).
        mutating func merge(_ changes: [String: JSONValue]) {
            for (key, value) in changes {
                if value == .null { fields[key] = nil } else { fields[key] = value }
            }
            if let stage = fields["stage"]?.text { fields["stage"] = .string(HubCards.current(stage)) }
        }

        /// A line added, the oldest dropped past `activityKept`, and the card updated when it was written.
        mutating func add(_ line: Activity) {
            var lines: [JSONValue] = if case .array(let items)? = fields["activity"] { items } else { [] }
            lines.append(line.json)
            fields["activity"] = .array(Array(lines.suffix(HubCards.activityKept)))
            fields["updatedAt"] = .string(line.at)
        }
    }

    /// An agent on the hub, as the board names it.
    public struct Agent: Equatable, Sendable {
        public let id: String
        public let name: String
        /// Who set it up (a GitHub login).
        public let owner: String
        public let revoked: Bool

        public init(id: String, name: String, owner: String = "", revoked: Bool = false) {
            self.id = id
            self.name = name
            self.owner = owner
            self.revoked = revoked
        }

        init?(_ value: JSONValue) {
            guard case .object(let fields) = value, let id = fields["id"]?.text else { return nil }
            self.id = id
            name = fields["name"]?.text ?? id
            owner = fields["owner"]?.text ?? ""
            revoked = fields["revoked"] == .bool(true)
        }
    }

    /// How many activity lines a card keeps (shared/work.ts's `activityKept`).
    public static let activityKept = 400

    /// A hub's cards and agents in one of its Binders, as of `version` in its log: what the board here is made from.
    public struct Board: Equatable, Sendable {
        public private(set) var version = 0
        public private(set) var cards: [String: Card] = [:]
        public private(set) var agents: [String: Agent] = [:]

        public init() {}

        /// The board from GET /api/state's answer. Nil when it isn't the hub's state.
        public init?(state data: Data) {
            struct Answer: Decodable {
                struct Inner: Decodable { let cards: [JSONValue]?; let agents: [JSONValue]? }
                let version: Int
                let state: Inner
            }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
            version = answer.version
            for value in answer.state.cards ?? [] {
                guard case .object(let fields) = value else { continue }
                var card = Card(fields: fields)
                card.merge([:])
                if !card.id.isEmpty { cards[card.id] = card }
            }
            for value in answer.state.agents ?? [] {
                if let agent = Agent(value) { agents[agent.id] = agent }
            }
        }

        /// The cards in one of its projects.
        public func cards(in binder: String) -> [Card] { cards.values.filter { $0.binderId == binder } }

        /// An agent's name, or what was given when it isn't one of the hub's agents (a login, or "hub").
        public func name(of id: String) -> String { agents[id]?.name ?? id }

        public func isAgent(_ id: String) -> Bool { agents[id] != nil }

        /// The hub's agent with this name, preferring one `owner` set up: what this Mac's agent is on the hub.
        public func agentID(named name: String, owner: String? = nil) -> String? {
            let named = agents.values.filter { !$0.revoked && $0.name.caseInsensitiveCompare(name) == .orderedSame }.sorted { $0.id < $1.id }
            return (named.first { $0.owner == owner } ?? named.first)?.id
        }

        /// Entries from the live feed, in order; those at or below `version` were applied already. Returns the ids of the
        /// cards they changed, deleted ones included.
        @discardableResult
        public mutating func apply(_ entries: [Entry]) -> Set<String> {
            var touched = Set<String>()
            for entry in entries where entry.version > version {
                version = entry.version
                touched.formUnion(apply(entry.change))
            }
            return touched
        }

        /// One change, as shared/work.ts's `applyWork` makes it; what isn't about cards or agents changes nothing here.
        @discardableResult
        mutating func apply(_ change: JSONValue) -> Set<String> {
            guard case .object(let body) = change, let type = body["type"]?.text else { return [] }
            let id = body["id"]?.text ?? ""
            switch type {
            case "card.put":
                guard case .object(let fields)? = body["card"] else { return [] }
                var card = Card(fields: fields)
                card.merge([:])
                guard !card.id.isEmpty else { return [] }
                cards[card.id] = card
                return [card.id]
            case "card.update":
                guard var card = cards[id] else { return [] }
                if case .object(let fields)? = body["fields"] {
                    var changed = fields
                    changed["id"] = nil
                    changed["activity"] = nil
                    card.merge(changed)
                }
                if let line = body["activity"].flatMap(Activity.init) { card.add(line) }
                cards[id] = card
                return [id]
            case "card.claim":
                guard var card = cards[id], let agent = body["agentId"]?.text, let at = body["at"]?.text else { return [] }
                // Taken already, done, or meant for someone else: the claim does nothing.
                if let holder = card.agentId, holder != agent { return [] }
                if card.stage != "ready", !(card.stage == "working" && card.agentId == agent) { return [] }
                if let meant = card.meantFor, meant != agent { return [] }
                card.merge(["agentId": .string(agent), "stage": .string("working"), "progress": .int(0)])
                card.add(Activity(at: at, by: agent, kind: "claimed", text: "\(agents[agent]?.name ?? "An agent") took it"))
                cards[id] = card
                return [id]
            case "card.release":
                guard var card = cards[id], let agent = body["agentId"]?.text, card.agentId == agent, let at = body["at"]?.text else { return [] }
                card.merge(["agentId": .null, "stage": .string("ready"), "doing": .null, "progress": .null])
                card.add(Activity(at: at, by: agent, kind: "released", text: body["why"]?.text ?? ""))
                cards[id] = card
                return [id]
            case "card.activity":
                guard var card = cards[id], let line = body["activity"].flatMap(Activity.init) else { return [] }
                card.add(line)
                cards[id] = card
                return [id]
            case "card.delete":
                return cards.removeValue(forKey: id) == nil ? [] : [id]
            case "agent.put":
                if let agent = body["agent"].flatMap(Agent.init) { agents[agent.id] = agent }
                return []
            case "agent.revoke":
                guard let agent = agents[id] else { return [] }
                agents[id] = Agent(id: agent.id, name: agent.name, owner: agent.owner, revoked: true)
                // What it held goes back on the board.
                var touched = Set<String>()
                for (cardID, card) in cards where card.agentId == id && card.stage == "working" {
                    var next = card
                    next.merge(["agentId": .null, "stage": .string("ready"), "doing": .null, "progress": .null])
                    cards[cardID] = next
                    touched.insert(cardID)
                }
                return touched
            case "agent.delete":
                agents[id] = nil
                return []
            default:
                return []
            }
        }
    }

    /// One entry of the hub's log, as /api/live sends it.
    public struct Entry: Decodable, Equatable, Sendable {
        public let version: Int
        public let change: JSONValue

        public init(version: Int, change: JSONValue) {
            self.version = version
            self.change = change
        }
    }

    /// What /api/live sent: entries of the log, or something else (agents' presence) this board doesn't read.
    public static func entries(fromLive data: Data) -> [Entry]? {
        struct Message: Decodable { let type: String; let entries: [Entry]? }
        guard let message = try? JSONDecoder().decode(Message.self, from: data), message.type == "entries" else { return nil }
        return message.entries ?? []
    }

    // MARK: This Mac's board

    /// A stage as the log may still have it: shipping is live.
    static func current(_ stage: String) -> String { stage == "shipping" ? "live" : stage }

    /// Where a card at a stage on the hub is on this Mac's board: proposed waits in Backlog, live is Done.
    public static func column(_ stage: String) -> BoardColumn {
        switch current(stage) {
        case "proposed": .backlog
        case "working": .inProgress
        case "blocked": .blocked
        case "review": .review
        case "live": .done
        default: .ready
        }
    }

    /// A card's id on this Mac: the same id for a card that went up from a Mac, and one made from the hub's id, the same on
    /// every Mac, for a card made on the hub.
    public static func localID(_ hubID: String) -> UUID {
        if let id = UUID(uuidString: hubID) { return id }
        var bytes = Array(SHA256.hash(data: Data("binders-hub-card:\(hubID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A line's kind on this Mac's timeline (`TaskEvent.Kind`): what the hub's agents and runner write that this Mac has
    /// no kind for is progress.
    public static func localKind(_ kind: String) -> String {
        switch kind {
        case "created", "claimed", "released", "progress", "question", "answer", "comment", "completed", "moved": kind
        case "debrief", "challenge": "comment"
        default: "progress"
        }
    }

    /// A line of this Mac's timeline as a kind of the hub's activity, or nil for what stays here: a lapse, a wake, what
    /// Binders found in your binders. A request for your approval is a question there, and your decision a comment.
    public static func hubKind(_ kind: String) -> String? {
        switch kind {
        case "created", "claimed", "released", "progress", "question", "answer", "comment", "completed", "moved": kind
        case "approval": "question"
        case "decision", "edited": "comment"
        case "assigned": "moved"
        default: nil
        }
    }

    /// The details this Mac shows for a card: its brief, and what done looks like after it.
    public static func details(brief: String, doneWhen: String) -> String {
        let done = doneWhen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !done.isEmpty else { return brief }
        return brief + (brief.isEmpty ? "" : "\n\n") + doneMark + done
    }

    /// The brief in details this Mac shows: what done looks like taken off again, as it came.
    public static func brief(details: String, doneWhen: String) -> String {
        let done = doneWhen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !done.isEmpty else { return details }
        for ending in ["\n\n" + doneMark + done, doneMark + done] where details.hasSuffix(ending) {
            return String(details.dropLast(ending.count))
        }
        return details
    }

    static let doneMark = "**Done when:** "

    // MARK: What goes up

    /// One change and its id, as POST /api/changes takes them. The hub keeps each id once: the same change sent again
    /// with it does nothing, so a change sent again until the hub has it is sent with the same id.
    public struct Outgoing: Codable, Equatable, Sendable {
        public let id: String
        public let change: JSONValue

        public init(id: String = "mac-" + UUID().uuidString.lowercased(), change: JSONValue) {
            self.id = id
            self.change = change
        }

        /// As JSON, to keep it until the hub has it (`TaskCard.hubPut`).
        public var json: String { (try? JSONEncoder.hub.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }

        public init?(json: String) {
            guard !json.isEmpty, let value = try? JSONDecoder().decode(Outgoing.self, from: Data(json.utf8)) else { return nil }
            self = value
        }
    }

    /// POST /api/changes's body.
    public static func body(client: String, changes: [Outgoing]) -> Data {
        struct Body: Encodable { let client: String; let changes: [Outgoing] }
        return (try? JSONEncoder.hub.encode(Body(client: client, changes: changes))) ?? Data()
    }

    /// The versions the hub gave what it kept, from POST /api/changes's answer: the last one is what to wait for.
    public static func versions(fromChanges data: Data) -> [Int]? {
        struct Answer: Decodable { let versions: [Int] }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.versions
    }

    /// A claim, which the hub decides.
    public static func claim(_ card: String, agent: String, at: String) -> JSONValue {
        .object(["type": .string("card.claim"), "id": .string(card), "agentId": .string(agent), "at": .string(at)])
    }

    /// Fields changed, a field set to `.null` cleared, with the first line of what was done.
    public static func update(_ card: String, fields: [String: JSONValue], activity: Activity?) -> JSONValue {
        var change: [String: JSONValue] = ["type": .string("card.update"), "id": .string(card), "fields": .object(fields)]
        if let activity { change["activity"] = activity.json }
        return .object(change)
    }

    public static func activity(_ card: String, _ line: Activity) -> JSONValue {
        .object(["type": .string("card.activity"), "id": .string(card), "activity": line.json])
    }

    public static func delete(_ card: String) -> JSONValue {
        .object(["type": .string("card.delete"), "id": .string(card)])
    }

    /// A new card, as the first upload puts one (HubLink.firstUpload).
    public static func put(_ card: HubLink.LocalCard, binder: String, person: String, known: Set<String>) -> JSONValue? {
        let changes = HubLink.firstUpload(binder: binder, newName: nil, person: person, folders: [], notes: [], cards: [card])
        guard let put = changes.first, let data = try? JSONEncoder.hub.encode(put), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let outgoing) = value, case .object(var change)? = outgoing["change"], case .object(var fields)? = change["card"] else { return nil }
        // Its note and the cards it waits for, when the hub has them: the first upload only knew the ones going with it.
        if let note = card.note { fields["noteId"] = .string(HubLink.hubID(note)) }
        fields["waitsFor"] = .array(card.waitsFor.map { $0.lowercased() }.filter(known.contains).map(JSONValue.string))
        change["card"] = .object(fields)
        return .object(change)
    }

    /// A card the hub had, put back as it had it (Undo of a deletion): its id, stage, agent and activity as they were, by a
    /// change of its own, as the hub keeps the first put of it once and wouldn't take that one again.
    public static func putBack(_ card: Card) -> Outgoing {
        Outgoing(change: .object(["type": .string("card.put"), "card": .object(card.fields)]))
    }

    /// What a move on this Mac changes on the hub, as the web app's board moves a card: a card that leaves an agent's
    /// hands for Backlog or Ready goes back to the board, and nothing waits on a person once it's moved.
    public static func moveFields(to column: BoardColumn) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["stage": .string(HubLink.stage(column)), "needsYou": .null, "doing": .null]
        if column == .backlog || column == .ready {
            fields["agentId"] = .null
            fields["progress"] = .null
        }
        return fields
    }

    // MARK: Dates

    public static func iso(_ date: Date) -> String { HubLink.iso(date) }

    public static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }
}

extension JSONValue {
    /// The value as text: a string, or a number written out.
    var text: String? {
        switch self {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): String(number)
        default: nil
        }
    }
}
