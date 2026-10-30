import CryptoKit
import Foundation

// Keeping a linked binder's notes and folders the same here and on the hub (the Binders server), through its change
// log: GET /api/state to start, GET /api/live?since= (a WebSocket) for every change after a version, POST
// /api/changes to send. The hub, the web app and this Mac apply a change with the same rules (shared/notes.ts), so they
// end up agreeing. Here: what can be checked without the hub, the store or Automerge.
//
// - `State` is the hub's notes and folders as this Mac last heard them, for every project in one of the hub's Binders,
//   kept on disk with the version it's at, so a Mac that was away catches up from there.
// - `plan` compares a binder here with that state and says what goes: folder.put and folder.delete, note.put,
//   note.move and note.delete; which notes' words changed (an edit, made as Automerge changes by the app); and what the
//   hub has that this Mac doesn't yet.
// - `Outbox` keeps what's waiting to go, in order, through being offline and quitting. Each change has an id of its own
//   under the link's client, so sending it twice puts it once.

public enum HubSync {
    // MARK: What the hub holds

    public struct Binder: Codable, Equatable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Folder: Codable, Equatable, Sendable {
        public var id: String
        public var binderId: String
        public var name: String
        public var parentId: String?

        public init(id: String, binderId: String, name: String, parentId: String? = nil) {
            self.id = id
            self.binderId = binderId
            self.name = name
            self.parentId = parentId
        }
    }

    public struct WorkLink: Codable, Equatable, Sendable {
        public var itemId: String
        public var quote: String
    }

    public struct Note: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var binderId: String
        public var folderId: String?
        public var editedAt: String
        public var editors: [String]
        public var text: String
        public var work: [WorkLink]?

        public init(id: String, title: String, binderId: String, folderId: String? = nil, editedAt: String, editors: [String], text: String,
                    work: [WorkLink]? = nil) {
            self.id = id
            self.title = title
            self.binderId = binderId
            self.folderId = folderId
            self.editedAt = editedAt
            self.editors = editors
            self.text = text
            self.work = work
        }
    }

    /// An edit of a note's words: `changes` are Automerge changes to its document (base64, in order). The hub sends it on
    /// with `text` and `title` as merged.
    public struct Edit: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
        public var title: String
        public var by: String
        public var at: String
        public var changes: [String]?

        public init(id: String, text: String, title: String, by: String, at: String, changes: [String]?) {
            self.id = id
            self.text = text
            self.title = title
            self.by = by
            self.at = at
            self.changes = changes
        }
    }

    /// A change in the hub's log, as shared/notes.ts writes it. Anything else in the log (cards, agents) is `other`.
    public enum Change: Codable, Equatable, Sendable {
        case binderPut(Binder)
        case binderDelete(String)
        case folderPut(Folder)
        case folderDelete(String)
        case notePut(Note)
        case noteEdit(Edit)
        case noteLink(String, WorkLink)
        case noteMove(String, binderId: String, folderId: String?)
        case noteDelete(String)
        case noteSaved(String)
        case other(String)

        private enum Keys: String, CodingKey { case type, binder, folder, note, id, link, binderId, folderId, text, title, by, at, changes }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "binder.put": self = .binderPut(try c.decode(Binder.self, forKey: .binder))
            case "binder.delete": self = .binderDelete(try c.decode(String.self, forKey: .id))
            case "folder.put": self = .folderPut(try c.decode(Folder.self, forKey: .folder))
            case "folder.delete": self = .folderDelete(try c.decode(String.self, forKey: .id))
            case "note.put": self = .notePut(try c.decode(Note.self, forKey: .note))
            case "note.edit": self = .noteEdit(try Edit(from: decoder))
            case "note.link": self = .noteLink(try c.decode(String.self, forKey: .id), try c.decode(WorkLink.self, forKey: .link))
            case "note.move":
                self = .noteMove(try c.decode(String.self, forKey: .id), binderId: try c.decode(String.self, forKey: .binderId),
                                 folderId: try c.decodeIfPresent(String.self, forKey: .folderId))
            case "note.delete": self = .noteDelete(try c.decode(String.self, forKey: .id))
            case "note.saved": self = .noteSaved(try c.decode(String.self, forKey: .id))
            default: self = .other(type)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .binderPut(let binder):
                try c.encode("binder.put", forKey: .type)
                try c.encode(binder, forKey: .binder)
            case .binderDelete(let id):
                try c.encode("binder.delete", forKey: .type)
                try c.encode(id, forKey: .id)
            case .folderPut(let folder):
                try c.encode("folder.put", forKey: .type)
                try c.encode(folder, forKey: .folder)
            case .folderDelete(let id):
                try c.encode("folder.delete", forKey: .type)
                try c.encode(id, forKey: .id)
            case .notePut(let note):
                try c.encode("note.put", forKey: .type)
                try c.encode(note, forKey: .note)
            case .noteEdit(let edit):
                try c.encode("note.edit", forKey: .type)
                try c.encode(edit.id, forKey: .id)
                try c.encode(edit.text, forKey: .text)
                try c.encode(edit.title, forKey: .title)
                try c.encode(edit.by, forKey: .by)
                try c.encode(edit.at, forKey: .at)
                try c.encodeIfPresent(edit.changes, forKey: .changes)
            case .noteLink(let id, let link):
                try c.encode("note.link", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(link, forKey: .link)
            case .noteMove(let id, let binderId, let folderId):
                try c.encode("note.move", forKey: .type)
                try c.encode(id, forKey: .id)
                try c.encode(binderId, forKey: .binderId)
                try c.encodeIfPresent(folderId, forKey: .folderId)
            case .noteDelete(let id):
                try c.encode("note.delete", forKey: .type)
                try c.encode(id, forKey: .id)
            case .noteSaved(let id):
                try c.encode("note.saved", forKey: .type)
                try c.encode(id, forKey: .id)
            case .other(let type):
                try c.encode(type, forKey: .type)
            }
        }
    }

    /// One change in the log: its version, and who sent it (`user:<login>:<client>` for a person's app).
    public struct Entry: Decodable, Equatable, Sendable {
        public var version: Int
        public var id: String
        public var client: String
        public var change: Change

        public init(version: Int, id: String, client: String, change: Change) {
            self.version = version
            self.id = id
            self.client = client
            self.change = change
        }
    }

    /// What /api/live sends: entries after the version asked for, then each one as it's appended. Nil for anything else
    /// (presence), or what can't be read.
    public static func entries(fromLive data: Data) -> [Entry]? {
        struct Message: Decodable { let type: String; let entries: [Lenient]? }
        // One entry that can't be read (a change of a kind this Mac doesn't know the shape of) doesn't stop the rest.
        struct Lenient: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: data), message.type == "entries" else { return nil }
        return (message.entries ?? []).compactMap(\.entry)
    }

    /// The client a person's app writes as in the log: an entry from it is this Mac's own.
    public static func logClient(login: String, client: String) -> String { "user:\(login):\(client)" }

    // MARK: The state, as this Mac last heard it

    public struct State: Codable, Equatable, Sendable {
        /// The last version of the log taken in.
        public var version: Int
        public var binders: [Binder]
        public var folders: [String: Folder]
        public var notes: [String: Note]
        /// The notes and folders this Mac and the hub have both had: one of them gone from here since was deleted here.
        /// One the hub has that isn't in it is new to this Mac, and comes.
        public var shared: Set<String>

        public init(version: Int = 0, binders: [Binder] = [], folders: [String: Folder] = [:], notes: [String: Note] = [:],
                    shared: Set<String> = []) {
            self.version = version
            self.binders = binders
            self.folders = folders
            self.notes = notes
            self.shared = shared
        }

        /// GET /api/state's answer: its version and its notes and folders. Nil when it isn't the hub's state.
        public init?(hubState data: Data) {
            struct Answer: Decodable {
                struct Inner: Decodable {
                    let binders: [Lenient<Binder>]?
                    let folders: [Lenient<Folder>]?
                    let notes: [Lenient<Note>]?
                }
                let version: Int
                let state: Inner
            }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return nil }
            self.init(version: answer.version, binders: (answer.state.binders ?? []).compactMap(\.value),
                      folders: Dictionary((answer.state.folders ?? []).compactMap(\.value).map { ($0.id, $0) }, uniquingKeysWith: { $1 }),
                      notes: Dictionary((answer.state.notes ?? []).compactMap(\.value).map { ($0.id, $0) }, uniquingKeysWith: { $1 }))
        }

        /// A change applied as shared/notes.ts applies it.
        public mutating func apply(_ change: Change) {
            switch change {
            case .binderPut(let binder):
                if let index = binders.firstIndex(where: { $0.id == binder.id }) { binders[index] = binder } else { binders.append(binder) }
            case .binderDelete(let id):
                binders.removeAll { $0.id == id }
            case .folderPut(let folder):
                folders[folder.id] = folder
            case .folderDelete(let id):
                // A folder goes with what's inside it moved up to where the folder was.
                guard let folder = folders.removeValue(forKey: id) else { return }
                for (key, child) in folders where child.parentId == id { folders[key]?.parentId = folder.parentId }
                for (key, note) in notes where note.folderId == id { notes[key]?.folderId = folder.parentId }
                shared.remove(id)
            case .notePut(let note):
                notes[note.id] = note
            case .noteEdit(let edit):
                guard var note = notes[edit.id] else { return }
                note.text = edit.text
                note.title = edit.title
                note.editedAt = edit.at
                if !note.editors.contains(edit.by) { note.editors.append(edit.by) }
                notes[edit.id] = note
            case .noteLink(let id, let link):
                guard var note = notes[id], !(note.work ?? []).contains(where: { $0.itemId == link.itemId }) else { return }
                note.work = (note.work ?? []) + [link]
                notes[id] = note
            case .noteMove(let id, let binderId, let folderId):
                notes[id]?.binderId = binderId
                notes[id]?.folderId = folderId
            case .noteDelete(let id):
                notes[id] = nil
                shared.remove(id)
            case .noteSaved, .other:
                break
            }
        }

        public func folders(in binder: String) -> [Folder] { folders.values.filter { $0.binderId == binder } }
        public func notes(in binder: String) -> [Note] { notes.values.filter { $0.binderId == binder } }
    }

    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    // MARK: Ids

    /// The id a hub's note or folder has here: the same UUID when it's one (a Mac's), else one made from it, the same
    /// on every Mac (the web app's ids are `note-…` and `folder-…`).
    public static func localID(_ hubID: String) -> UUID {
        if let uuid = UUID(uuidString: hubID) { return uuid }
        var bytes = Array(SHA256.hash(data: Data("binders-hub:\(hubID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50    // a name-based UUID
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Hub ids by the id they have here, for every note and folder in the state.
    public static func hubIDs(in state: State) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for id in state.folders.keys { out[localID(id)] = id }
        for id in state.notes.keys { out[localID(id)] = id }
        return out
    }

    // MARK: What goes

    /// A folder here, in the hub's ids.
    public struct LocalFolder: Equatable, Sendable {
        public var id: String
        public var parent: String?
        public var name: String

        public init(id: String, parent: String?, name: String) {
            self.id = id
            self.parent = parent
            self.name = name
        }
    }

    /// A note here, in the hub's ids.
    public struct LocalNote: Equatable, Sendable {
        public var id: String
        public var folder: String?
        public var text: String

        public init(id: String, folder: String?, text: String) {
            self.id = id
            self.folder = folder
            self.text = text
        }
    }

    public struct Plan: Equatable, Sendable {
        /// What goes, in the order the hub should apply it.
        public var changes: [Change] = []
        /// Notes whose words here aren't what the hub last said: each goes as an edit if its document says so too.
        public var edited: [String] = []
        /// The hub's that aren't here yet, and come.
        public var newFolders: [String] = []
        public var newNotes: [String] = []

        public init() {}
    }

    /// What's different between a binder here (its folders and notes, the hub's ids) and its project in the state: what
    /// goes (folders a parent before its child, then notes put, moved and deleted, then folders deleted), what was
    /// written, and what comes. `person`: who's signed in, as a new note's editor. `elsewhere`: notes in another binder
    /// here linked to the same hub's Binder, whose plan moves them, so they aren't deleted from this one.
    public static func plan(project: String, state: State, folders: [LocalFolder], notes: [LocalNote], person: String,
                            elsewhere: Set<String> = [], at date: Date = Date()) -> Plan {
        var plan = Plan()
        let localFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localNotes = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // A folder or note goes where this Mac has it, else to the top.
        func known(_ folder: String?) -> String? { folder.flatMap { localFolders[$0] == nil ? nil : $0 } }

        for folder in parentsFirst(folders) {
            let put = Folder(id: folder.id, binderId: project, name: folder.name, parentId: known(folder.parent))
            if state.folders[folder.id] != put { plan.changes.append(.folderPut(put)) }
        }
        for note in notes {
            guard let hub = state.notes[note.id] else {
                plan.changes.append(.notePut(Note(id: note.id, title: title(of: note.text), binderId: project, folderId: known(note.folder),
                                                  editedAt: HubLink.iso(date), editors: [person], text: note.text)))
                continue
            }
            if hub.binderId != project || hub.folderId != known(note.folder) {
                plan.changes.append(.noteMove(note.id, binderId: project, folderId: known(note.folder)))
            }
            if hub.text != note.text { plan.edited.append(note.id) }
        }
        let hubNotes = state.notes(in: project).sorted { $0.id < $1.id }
        for note in hubNotes where localNotes[note.id] == nil && !elsewhere.contains(note.id) {
            if state.shared.contains(note.id) { plan.changes.append(.noteDelete(note.id)) } else { plan.newNotes.append(note.id) }
        }
        // Deleted here: children before their parents, so each goes with nothing of this Mac's moved up into it.
        let hubFolders = state.folders(in: project)
        let gone = hubFolders.filter { localFolders[$0.id] == nil && state.shared.contains($0.id) }
        plan.changes += parentsFirst(gone.map { LocalFolder(id: $0.id, parent: $0.parentId, name: $0.name) }).reversed().map { .folderDelete($0.id) }
        plan.newFolders = parentsFirst(hubFolders.filter { localFolders[$0.id] == nil && !state.shared.contains($0.id) }
            .map { LocalFolder(id: $0.id, parent: $0.parentId, name: $0.name) }).map(\.id)
        return plan
    }

    /// Folders with each one's parent before it; one whose parent isn't among them (or that's in a loop) goes first.
    static func parentsFirst(_ folders: [LocalFolder]) -> [LocalFolder] {
        let known = Set(folders.map(\.id))
        var left = folders.sorted { $0.id < $1.id }
        var placed = Set<String>()
        var out: [LocalFolder] = []
        while !left.isEmpty {
            var ready = left.filter { folder in folder.parent.map { !known.contains($0) || placed.contains($0) } ?? true }
            // Only a loop is left: it's broken where it's first met.
            if ready.isEmpty { ready = [left[0]] }
            out += ready
            placed.formUnion(ready.map(\.id))
            left.removeAll { placed.contains($0.id) }
        }
        return out
    }

    /// A note's title as the hub makes it (titleOf): its first top heading, or the start of its first words with the
    /// Markdown taken off.
    public static func title(of text: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") || trimmed.hasPrefix("#\t") else { continue }
            var heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            while heading.hasSuffix("#") { heading.removeLast() }
            heading = heading.trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return String(heading.prefix(120)) }
        }
        let first = text.components(separatedBy: "\n").lazy.map { line -> String in
            var words = line.replacingOccurrences(of: #"^\s*(#{1,6}\s+|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+|>\s*)"#, with: "",
                                                  options: .regularExpression)
            words = words.replacingOccurrences(of: #"[*_`~\[\]]"#, with: "", options: .regularExpression)
            return words.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty }
        return first.map { String($0.prefix(60)) } ?? "Untitled"
    }

    // MARK: What's waiting to go

    /// A change waiting to go, under the client of the link it's for. An edit keeps the words it was made from and to,
    /// so one the hub turns down (its note's document was set aside meanwhile) can be made again on the hub's document.
    public struct Pending: Codable, Equatable, Sendable {
        public var id: String
        public var client: String
        public var change: Change
        public var base: String?

        public init(id: String = "sync-" + UUID().uuidString.lowercased(), client: String, change: Change, base: String? = nil) {
            self.id = id
            self.client = client
            self.change = change
            self.base = base
        }

        /// The note it's about, for an edit.
        public var editedNote: String? {
            if case .noteEdit(let edit) = change { return edit.id }
            return nil
        }
    }

    /// What's waiting to go, in order: a run of one client's changes goes in one request, at most `maxCount`.
    public static func nextBatch(_ outbox: [Pending], maxCount: Int = 100) -> [Pending] {
        guard let client = outbox.first?.client else { return [] }
        return Array(outbox.prefix { $0.client == client }.prefix(maxCount))
    }

    /// POST /api/changes's body for a batch, all under its first one's client.
    public static func body(_ batch: [Pending]) -> Data {
        struct Outgoing: Encodable { let id: String; let change: Change }
        struct Body: Encodable { let client: String; let changes: [Outgoing] }
        return (try? JSONEncoder.hub.encode(Body(client: batch.first?.client ?? "", changes: batch.map { Outgoing(id: $0.id, change: $0.change) }))) ?? Data()
    }

    /// /api/live's address for a hub, from a version: ws:// for http://, wss:// for https://.
    public static func liveURL(hub: URL, since version: Int) -> URL? {
        guard var parts = URLComponents(url: hub.appendingPathComponent("api/live"), resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        parts.queryItems = [URLQueryItem(name: "since", value: String(max(0, version)))]
        return parts.url
    }

    /// How long to wait before trying the hub again after `failures` tries in a row: 1, 2, 4… up to 30 seconds.
    public static func retryDelay(after failures: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, failures - 1))))
    }
}
