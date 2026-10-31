import CryptoKit
import Foundation

// Linking a binder on the Mac to a binder on a hub (the Binders server). On the hub a Binder holds projects, and a
// project is what holds notes, folders and cards, as a binder does here: the hub's state calls them `binders`. Linking
// picks one, or makes a new one, and the first time sends the binder's folders, notes and cards up as changes in the
// hub's log (POST /api/changes): folder.put, note.put and card.put, after a binder.put for a new one. Each change has an
// id made from what it puts and how (its version), under a client of the link's own, so sending them again after a
// failure puts nothing twice (the hub keeps one change per client and id), and something changed here since goes again
// as it is now. Here: what can be checked without the hub or the store.

public enum HubLink {
    /// Where a binder is linked: the hub, its Binder (`x-binders-space`) and the project in it, kept on the binder.
    public struct Place: Codable, Equatable, Sendable {
        public var hub: URL
        public var space: String
        public var spaceName: String
        /// The project's id in the hub's state.
        public var binder: String
        public var binderName: String
        /// The client its changes go under: the hub keeps one change per client and id.
        public var client: String
        public var linkedAt: Date
        /// Whether everything that was here when it was linked is on the hub. Until then, Send Again sends what's left.
        public var uploaded: Bool
        /// Made on the hub by this link: its binder.put goes with what's sent, again by Send Again.
        public var newProject: Bool

        public init(hub: URL, space: String, spaceName: String, binder: String, binderName: String, client: String,
                    linkedAt: Date = Date(), uploaded: Bool = false, newProject: Bool = false) {
            self.hub = hub
            self.space = space
            self.spaceName = spaceName
            self.binder = binder
            self.binderName = binderName
            self.client = client
            self.linkedAt = linkedAt
            self.uploaded = uploaded
            self.newProject = newProject
        }

        public init?(json: String) {
            guard !json.isEmpty, let place = try? JSONDecoder.hub.decode(Place.self, from: Data(json.utf8)) else { return nil }
            self = place
        }

        public var json: String { (try? JSONEncoder.hub.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    }

    // MARK: What the hub has

    /// One of the hub's Binders the person is in, from GET /api/me.
    public struct Space: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let role: String?

        public init(id: String, name: String, role: String? = nil) {
            self.id = id
            self.name = name
            self.role = role
        }
    }

    /// The hub's Binders the person is in, and the one a request without `x-binders-space` opens.
    public static func spaces(fromMe data: Data) -> (spaces: [Space], current: String?) {
        struct Me: Decodable { let space: String?; let spaces: [Space]? }
        guard let me = try? JSONDecoder().decode(Me.self, from: data) else { return ([], nil) }
        return (me.spaces ?? [], me.space)
    }

    /// A project in a hub's Binder.
    public struct Project: Decodable, Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    private struct State: Decodable {
        struct Item: Decodable { let id: String; let binderId: String? }
        struct Inner: Decodable {
            let binders: [Project]
            let folders: [Item]?
            let notes: [Item]?
            let cards: [Item]?
        }
        let state: Inner
    }

    /// Whether two addresses are the same hub: what a link was made on, and what this Mac is signed in to.
    public static func sameHub(_ one: URL, _ other: URL) -> Bool {
        func key(_ url: URL) -> String? {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host?.lowercased() else { return nil }
            let scheme = parts.scheme?.lowercased() ?? "https"
            let port = parts.port ?? (scheme == "http" ? 80 : 443)
            var path = parts.path
            while path.hasSuffix("/") { path.removeLast() }
            return "\(scheme)://\(host):\(port)\(path)"
        }
        guard let first = key(one), let second = key(other) else { return false }
        return first == second
    }

    /// The projects in a Binder, from GET /api/state, by name. Nil when it isn't the hub's state.
    public static func projects(fromState data: Data) -> [Project]? {
        guard let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        return state.state.binders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What of `changes` the hub's state doesn't have in `binder`, by change id: whatever didn't arrive. Nil when it isn't
    /// the hub's state. Being there is enough: a change's id has its version in it, so one the hub took (now, or before as
    /// it is now) was put as it is here, and whatever the hub has done to it since is newer.
    public static func missing(_ changes: [Outgoing], fromState data: Data, binder: String) -> [String]? {
        guard let state = try? JSONDecoder().decode(State.self, from: data).state else { return nil }
        func ids(_ items: [State.Item]?) -> Set<String> { Set((items ?? []).filter { $0.binderId == binder }.map(\.id)) }
        let folders = ids(state.folders), notes = ids(state.notes), cards = ids(state.cards)
        return changes.compactMap { outgoing in
            switch outgoing.change {
            case .binder(let put): state.binders.contains { $0.id == put.id } ? nil : outgoing.id
            case .folder(let put): folders.contains(put.id) ? nil : outgoing.id
            case .note(let put): notes.contains(put.id) ? nil : outgoing.id
            case .card(let put): cards.contains(put.id) ? nil : outgoing.id
            }
        }
    }

    /// The hub's words when it refuses something: `{ "error": "…" }`.
    public static func error(in data: Data) -> String? {
        struct Refusal: Decodable { let error: String }
        return (try? JSONDecoder().decode(Refusal.self, from: data))?.error
    }

    // MARK: What goes up

    /// A folder here, as the first upload reads it.
    public struct LocalFolder: Equatable, Sendable {
        public let id: UUID
        public let parent: UUID?
        public let name: String
        /// When it was last renamed or moved here: part of its version, as a note's and a card's are part of theirs.
        public let editedAt: Date?

        public init(id: UUID, parent: UUID?, name: String, editedAt: Date? = nil) {
            self.id = id
            self.parent = parent
            self.name = name
            self.editedAt = editedAt
        }
    }

    public struct LocalNote: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let text: String
        public let folder: UUID?
        public let editedAt: Date

        public init(id: UUID, title: String, text: String, folder: UUID?, editedAt: Date) {
            self.id = id
            self.title = title
            self.text = text
            self.folder = folder
            self.editedAt = editedAt
        }
    }

    /// A line of a card's timeline. Only what people and agents said goes up: comments, questions and answers.
    public struct LocalEvent: Equatable, Sendable {
        public let kind: String
        /// "You" for the person on this Mac, or an agent's name.
        public let author: String
        public let text: String
        public let at: Date

        public init(kind: String, author: String, text: String, at: Date) {
            self.kind = kind
            self.author = author
            self.text = text
            self.at = at
        }
    }

    public struct LocalCard: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let details: String
        public let column: BoardColumn
        public let links: [String]
        /// "You", or the agent that made it.
        public let createdBy: String
        public let createdAt: Date
        public let updatedAt: Date
        /// The cards it waits for, by id.
        public let waitsFor: [String]
        /// The note it came from, if it's one of this binder's.
        public let note: UUID?
        public let events: [LocalEvent]

        public init(id: UUID, title: String, details: String, column: BoardColumn, links: [String] = [], createdBy: String = "You",
                    createdAt: Date, updatedAt: Date, waitsFor: [String] = [], note: UUID? = nil, events: [LocalEvent] = []) {
            self.id = id
            self.title = title
            self.details = details
            self.column = column
            self.links = links
            self.createdBy = createdBy
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.waitsFor = waitsFor
            self.note = note
            self.events = events
        }
    }

    /// An id here as the hub keeps it.
    public static func hubID(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// A client for a new link: "mac-" and 24 letters and digits, which the hub takes (6 to 64 of letters, digits, - and _).
    public static func newClient() -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "mac-" + String((0..<24).map { _ in letters.randomElement()! })
    }

    /// A new project's id on the hub.
    public static func newProjectID() -> String { "binder-" + hubID(UUID()) }

    /// A card's place on the hub's board. The hub has no Backlog: a card there waits for a person as `proposed`, so the
    /// hub's agents don't take it. Done is `live`.
    public static func stage(_ column: BoardColumn) -> String {
        switch column {
        case .backlog: "proposed"
        case .ready: "ready"
        case .inProgress: "working"
        case .blocked: "blocked"
        case .review: "review"
        case .done: "live"
        }
    }

    /// Everything a binder sends the first time it's linked to `binder`, in the order the hub should apply it: a new
    /// project (`newName`), its folders with each one's parent before it, its notes, then its cards. `person`: the
    /// GitHub login of who's signed in, for what's theirs here ("You").
    public static func firstUpload(binder: String, newName: String?, person: String, folders: [LocalFolder], notes: [LocalNote],
                                   cards: [LocalCard]) -> [Outgoing] {
        var out: [Outgoing] = []
        if let newName {
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Outgoing(id: "binder-\(binder)", change: .binder(.init(id: binder, name: name.isEmpty ? "New project" : name, createdBy: person))))
        }
        let known = Set(folders.map(\.id))
        for folder in parentsFirst(folders) {
            let put = Change.Folder(id: hubID(folder.id), binderId: binder, name: folder.name,
                                    parentId: folder.parent.flatMap { known.contains($0) ? hubID($0) : nil })
            out.append(versioned("folder-\(put.id)", .folder(put), editedAt: folder.editedAt))
        }
        let noteIDs = Set(notes.map(\.id))
        for note in notes {
            let put = Change.Note(id: hubID(note.id), title: note.title, binderId: binder,
                                  folderId: note.folder.flatMap { known.contains($0) ? hubID($0) : nil },
                                  editedAt: iso(note.editedAt), editors: [person], text: note.text)
            out.append(versioned("note-\(put.id)", .note(put)))
        }
        let cardIDs = Set(cards.map { hubID($0.id) })
        for card in cards {
            func who(_ name: String) -> String { name == "You" || name.isEmpty ? person : name }
            var activity = [Change.Activity(at: iso(card.createdAt), by: who(card.createdBy), kind: "created", text: "Put it on the board on a Mac")]
            activity += card.events.filter { ["comment", "question", "answer"].contains($0.kind) && !$0.text.isEmpty }
                .map { Change.Activity(at: iso($0.at), by: who($0.author), kind: $0.kind, text: $0.text) }
            var brief = card.details.trimmingCharacters(in: .whitespacesAndNewlines)
            if !card.links.isEmpty {
                brief += (brief.isEmpty ? "" : "\n\n") + card.links.map { "- \($0)" }.joined(separator: "\n")
            }
            let put = Change.Card(id: hubID(card.id), binderId: binder, title: String(card.title.prefix(200)), brief: brief, doneWhen: "",
                                  size: "M", stage: stage(card.column), createdAt: iso(card.createdAt), createdBy: who(card.createdBy),
                                  updatedAt: iso(card.updatedAt),
                                  noteId: card.note.flatMap { noteIDs.contains($0) ? hubID($0) : nil },
                                  waitsFor: card.waitsFor.map { $0.lowercased() }.filter { cardIDs.contains($0) },
                                  activity: activity)
            out.append(versioned("card-\(put.id)", .card(put)))
        }
        return out
    }

    /// A change whose id is what it puts (`name`) and a fingerprint of how: the same thing put the same way has the same
    /// id, so the hub keeps it once, and changed here since it went (even back to how it was, as `editedAt` moves on) it
    /// has a new one, which the hub puts over the old. A new project keeps its plain id: it's made once, and put again it
    /// would take back what the hub has added to it, such as its repo.
    static func versioned(_ name: String, _ change: Change, editedAt: Date? = nil) -> Outgoing {
        var bytes = (try? JSONEncoder.hub.encode(change)) ?? Data()
        if let editedAt { bytes.append(Data(iso(editedAt).utf8)) }
        let mark = SHA256.hash(data: bytes).prefix(8).map { String(format: "%02x", $0) }.joined()
        return Outgoing(id: "\(name)-\(mark)", change: change)
    }

    /// Folders with each one's parent before it; one whose parent isn't among them (or that's in a loop) goes at the top.
    static func parentsFirst(_ folders: [LocalFolder]) -> [LocalFolder] {
        let known = Set(folders.map(\.id))
        var left = folders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var placed = Set<UUID>()
        var out: [LocalFolder] = []
        while !left.isEmpty {
            let ready = left.filter { folder in folder.parent.map { !known.contains($0) || placed.contains($0) } ?? true }
            // Only a loop is left: its folders go at the top.
            let next = ready.isEmpty ? left.map { LocalFolder(id: $0.id, parent: nil, name: $0.name, editedAt: $0.editedAt) } : ready
            for folder in next {
                let top = folder.parent.map { !known.contains($0) } ?? false
                out.append(top ? LocalFolder(id: folder.id, parent: nil, name: folder.name, editedAt: folder.editedAt) : folder)
                placed.insert(folder.id)
            }
            left.removeAll { placed.contains($0.id) }
        }
        return out
    }

    /// Changes in requests the hub takes: at most 500 to one, and about `maxBytes` of JSON each (the hub takes 4 MB).
    public static func batches(_ changes: [Outgoing], maxCount: Int = 500, maxBytes: Int = 1_000_000) -> [[Outgoing]] {
        var out: [[Outgoing]] = []
        var current: [Outgoing] = []
        var bytes = 0
        for change in changes {
            let size = (try? JSONEncoder.hub.encode(change).count) ?? 0
            if !current.isEmpty, current.count >= maxCount || bytes + size > maxBytes {
                out.append(current)
                current = []
                bytes = 0
            }
            current.append(change)
            bytes += size
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// POST /api/changes's body.
    public static func body(client: String, changes: [Outgoing]) -> Data {
        struct Body: Encodable { let client: String; let changes: [Outgoing] }
        return (try? JSONEncoder.hub.encode(Body(client: client, changes: changes))) ?? Data()
    }

    /// "12 notes, 3 folders and 5 cards", of what's going up (a new project isn't counted).
    public static func counted(_ changes: [Outgoing]) -> String {
        var notes = 0, folders = 0, cards = 0
        for change in changes {
            switch change.change {
            case .note: notes += 1
            case .folder: folders += 1
            case .card: cards += 1
            case .binder: break
            }
        }
        func count(_ number: Int, _ one: String, _ many: String) -> String { "\(number) \(number == 1 ? one : many)" }
        return "\(count(notes, "note", "notes")), \(count(folders, "folder", "folders")) and \(count(cards, "card", "cards"))"
    }

    public static func iso(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: date)
    }

    // MARK: Changes

    /// One change and its id, as POST /api/changes takes them.
    public struct Outgoing: Encodable, Equatable, Sendable {
        public let id: String
        public let change: Change
    }

    /// The changes the first upload sends, as shared/notes.ts and shared/work.ts write them.
    public enum Change: Encodable, Equatable, Sendable {
        case binder(Binder)
        case folder(Folder)
        case note(Note)
        case card(Card)

        public struct Binder: Encodable, Equatable, Sendable {
            public let id: String
            public let name: String
            public let createdBy: String
        }

        public struct Folder: Encodable, Equatable, Sendable {
            public let id: String
            public let binderId: String
            public let name: String
            public let parentId: String?
        }

        public struct Note: Encodable, Equatable, Sendable {
            public let id: String
            public let title: String
            public let binderId: String
            public let folderId: String?
            public let editedAt: String
            public let editors: [String]
            public let text: String
        }

        public struct Activity: Encodable, Equatable, Sendable {
            public let at: String
            public let by: String
            public let kind: String
            public let text: String
        }

        public struct Card: Encodable, Equatable, Sendable {
            public let id: String
            public let binderId: String
            public let title: String
            public let brief: String
            public let doneWhen: String
            public let size: String
            public let stage: String
            public let createdAt: String
            public let createdBy: String
            public let updatedAt: String
            public let noteId: String?
            public let waitsFor: [String]
            public let activity: [Activity]
        }

        private enum Keys: String, CodingKey { case type, binder, folder, note, card }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case .binder(let binder):
                try container.encode("binder.put", forKey: .type)
                try container.encode(binder, forKey: .binder)
            case .folder(let folder):
                try container.encode("folder.put", forKey: .type)
                try container.encode(folder, forKey: .folder)
            case .note(let note):
                try container.encode("note.put", forKey: .type)
                try container.encode(note, forKey: .note)
            case .card(let card):
                try container.encode("card.put", forKey: .type)
                try container.encode(card, forKey: .card)
            }
        }
    }
}

extension JSONEncoder {
    /// Dates as ISO 8601, keys in order, slashes as they are.
    static var hub: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var hub: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
