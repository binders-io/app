import Foundation

// Notes on the team database (lane DB3), as rows and calls: a shared note's row, its changes and versions, who's in it,
// folders, Distill's records, and the calls migration 6 adds. Pure, so it's tested without a database; the Mac's
// TeamNotes turns them into its notes, folders and distills.

/// Who made something in a team folder, as an import keeps it: their id there and their name.
public struct TeamImportedAuthor: Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public init?(_ json: TeamJSON?) {
        guard let name = json?["name"]?.string else { return nil }
        self.init(id: json?["id"]?.string ?? "", name: name)
    }

    public var json: TeamJSON { ["id": .string(id), "name": .string(name)] }
}

// MARK: Rows

/// A shared note (`binders.notes`), as the Mac reads it. Its words live in its Automerge document; `body` is the copy
/// saved last, for anyone reading the database.
public struct TeamNoteRow: Equatable, Sendable {
    public var id: UUID
    public var binderID: UUID
    public var folderID: UUID?
    public var title: String
    public var body: String
    public var properties: [String: TeamJSON]
    public var distill: Bool
    public var document: Data?
    public var documentHeads: [String]
    public var documentChanges: Int
    public var originHeads: [String]
    public var createdBy: UUID?
    public var createdByAgent: UUID?
    public var importedAuthor: TeamImportedAuthor?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var deletedAt: Date?

    /// Whether the row was read with its document and body (lane DB10): a feed read leaves them out
    /// (TeamQueries.noteRowHeavyColumns), and a Mac reads the row whole when it makes the note's document from it.
    public static func isWhole(_ row: TeamRow) -> Bool { row["document"] != nil }

    public init?(row: TeamRow) {
        guard let id = row["id"]?.uuid, let binderID = row["binder_id"]?.uuid else { return nil }
        self.id = id
        self.binderID = binderID
        folderID = row["folder_id"]?.uuid
        title = row["title"]?.string ?? ""
        body = row["body"]?.string ?? ""
        properties = row["properties"]?.object ?? [:]
        distill = row["distill"]?.bool ?? false
        document = row["document"]?.bytes
        documentHeads = row["document_heads"]?.strings ?? []
        documentChanges = row["document_changes"]?.int ?? 0
        originHeads = row["origin_heads"]?.strings ?? []
        createdBy = row["created_by"]?.uuid
        createdByAgent = row["created_by_agent"]?.uuid
        importedAuthor = TeamImportedAuthor(row["imported_author"])
        createdAt = row["created_at"]?.date
        updatedAt = row["updated_at"]?.date
        deletedAt = row.deletedAt
    }
}

/// One change of a note's document (`binders.note_changes`): its bytes, its hash and what it depends on, who made it
/// (the member whose login sent it, and the agent, for an agent's), and what it did.
public struct TeamNoteChangeRow: Equatable, Sendable {
    public var id: UUID
    public var binderID: UUID
    public var noteID: UUID
    public var memberID: UUID?
    public var agentID: UUID?
    public var change: Data
    public var hash: String
    public var deps: [String]
    public var linesAdded: Int
    public var linesRemoved: Int
    public var sections: [String]
    public var versionID: UUID?
    public var createdAt: Date?

    public init?(row: TeamRow) {
        guard let id = row["id"]?.uuid, let binderID = row["binder_id"]?.uuid, let noteID = row["note_id"]?.uuid,
              let change = row["change"]?.bytes, let hash = row["hash"]?.string else { return nil }
        self.id = id
        self.binderID = binderID
        self.noteID = noteID
        memberID = row["member_id"]?.uuid
        agentID = row["agent_id"]?.uuid
        self.change = change
        self.hash = hash
        deps = row["deps"]?.strings ?? []
        linesAdded = row["lines_added"]?.int ?? 0
        linesRemoved = row["lines_removed"]?.int ?? 0
        sections = row["sections"]?.strings ?? []
        versionID = row["version_id"]?.uuid
        createdAt = row["created_at"]?.date
    }
}

/// A version of a note (`binders.note_versions`): one person's or one agent's editing session, as the database groups
/// the changes.
public struct TeamNoteVersionRow: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var binderID: UUID
    public var noteID: UUID
    public var firstChangeID: UUID?
    public var lastChangeID: UUID?
    public var firstHash: String?
    public var lastHash: String?
    public var memberID: UUID?
    public var agentID: UUID?
    public var startedAt: Date?
    public var endedAt: Date?
    public var linesAdded: Int
    public var linesRemoved: Int
    public var sections: [String]
    public var name: String?
    public var distillID: UUID?
    public var restoredFrom: UUID?
    public var imported: Bool
    public var deletedAt: Date?

    public init?(row: TeamRow) {
        guard let id = row["id"]?.uuid, let binderID = row["binder_id"]?.uuid, let noteID = row["note_id"]?.uuid else { return nil }
        self.id = id
        self.binderID = binderID
        self.noteID = noteID
        firstChangeID = row["first_change_id"]?.uuid
        lastChangeID = row["last_change_id"]?.uuid
        firstHash = row["first_hash"]?.string
        lastHash = row["last_hash"]?.string
        memberID = row["member_id"]?.uuid
        agentID = row["agent_id"]?.uuid
        startedAt = row["started_at"]?.date
        endedAt = row["ended_at"]?.date
        linesAdded = row["lines_added"]?.int ?? 0
        linesRemoved = row["lines_removed"]?.int ?? 0
        sections = row["sections"]?.strings ?? []
        name = row["name"]?.string
        distillID = row["distill_id"]?.uuid
        restoredFrom = row["restored_from"]?.uuid
        imported = row["imported"]?.bool ?? false
        deletedAt = row.deletedAt
    }

    /// How long after its last change a version still takes the next one by the same author: the database's rule.
    public static let session: TimeInterval = 5 * 60

    /// Whether a change by this member (and agent) at `now` goes in this version, as the database decides it: the same
    /// author, its last change less than 5 minutes ago, and it wasn't named, read by a distill, put back or brought in.
    public func takes(member: UUID?, agent: UUID?, at now: Date = Date()) -> Bool {
        guard deletedAt == nil, memberID == member, agentID == agent, name == nil, distillID == nil, restoredFrom == nil, !imported,
              let endedAt else { return false }
        return now.timeIntervalSince(endedAt) < Self.session
    }
}

/// Viewing a note, or reviewing one of its Distill proposals.
public enum TeamPresenceKind: String, Sendable {
    case viewing, reviewing
}

/// Someone in a note (`binders.note_presence`): who, which note, viewing or reviewing, and when they were last seen there.
public struct TeamPresenceRow: Equatable, Sendable {
    public var id: UUID
    public var binderID: UUID
    public var noteID: UUID
    public var memberID: UUID
    public var kind: TeamPresenceKind
    public var distillID: UUID?
    public var seenAt: Date?
    public var deletedAt: Date?

    public init?(row: TeamRow) {
        guard let id = row["id"]?.uuid, let binderID = row["binder_id"]?.uuid, let noteID = row["note_id"]?.uuid,
              let memberID = row["member_id"]?.uuid else { return nil }
        self.id = id
        self.binderID = binderID
        self.noteID = noteID
        self.memberID = memberID
        kind = row["kind"]?.string.flatMap(TeamPresenceKind.init(rawValue:)) ?? .viewing
        distillID = row["distill_id"]?.uuid
        seenAt = row["seen_at"]?.date
        deletedAt = row.deletedAt
    }

    /// How long someone counts as in a note after they were last seen there: their Mac says so every 45 seconds while
    /// the note is open, so a Mac that quit or dropped off goes after this.
    public static let lasts: TimeInterval = 120
    /// How often a Mac says it's still in a note.
    public static let heartbeat: TimeInterval = 45

    /// In the note now: not marked left, and seen within `lasts`.
    public func isHere(at now: Date = Date(), lasts: TimeInterval = TeamPresenceRow.lasts) -> Bool {
        guard deletedAt == nil, let seenAt else { return false }
        return now.timeIntervalSince(seenAt) < lasts
    }

    /// "Dana is in this note", "Dana and Robin are in this note".
    public static func line(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "\(names.formatted(.list(type: .and))) \(names.count == 1 ? "is" : "are") in this note"
    }

    /// "Dana is reviewing these items", for a Distill proposal.
    public static func reviewingLine(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "\(names.formatted(.list(type: .and))) \(names.count == 1 ? "is" : "are") reviewing these items"
    }
}

/// A folder in a shared binder (`binders.folders`).
public struct TeamFolderRow: Equatable, Sendable {
    public var id: UUID
    public var binderID: UUID
    public var parentID: UUID?
    public var name: String
    public var position: Double
    public var deletedAt: Date?
    public var updatedAt: Date?

    public init?(row: TeamRow) {
        guard let id = row["id"]?.uuid, let binderID = row["binder_id"]?.uuid, let name = row["name"]?.string else { return nil }
        self.id = id
        self.binderID = binderID
        parentID = row["parent_id"]?.uuid
        self.name = name
        position = row["position"]?.double ?? 0
        deletedAt = row.deletedAt
        updatedAt = row["updated_at"]?.date
    }
}

// MARK: What travels with a note

/// What a shared note's document keeps beside its words (`ROOT.props`): its properties, and the agent's mark (the agent
/// that wrote it, and the one that last changed it and when), each key on its own. Names are as the team names them
/// ("Claude Code (Sam)"); the Mac turns them into its own.
public struct TeamNoteProps: Equatable, Sendable {
    public var properties: NoteProperties
    public var mark: TeamNoteMark

    public init(properties: NoteProperties = NoteProperties(), mark: TeamNoteMark = TeamNoteMark()) {
        self.properties = properties
        self.mark = mark
    }

    /// Every key the document's props can hold.
    public static let keys = ["status", "owner", "due", "distill", "made_by", "edited_by", "edited_at"]

    /// From the document's props: missing keys and nulls are none; a key a later Binders writes is let be.
    public init(values: [String: TeamJSON]) {
        properties = NoteProperties(status: values["status"]?.string, owner: values["owner"]?.string, due: values["due"]?.date,
                                    distill: values["distill"]?.bool ?? false)
        mark = TeamNoteMark(madeBy: values["made_by"]?.string, editedBy: values["edited_by"]?.string, editedAt: values["edited_at"]?.date)
    }

    /// As the document keeps them: every key, null for none, so taking one away is a change too.
    public var values: [String: TeamJSON] {
        ["status": TeamJSON(properties.status), "owner": TeamJSON(properties.owner), "due": TeamJSON(properties.due),
         "distill": .bool(properties.distill), "made_by": TeamJSON(mark.madeBy), "edited_by": TeamJSON(mark.editedBy),
         "edited_at": TeamJSON(mark.editedAt)]
    }

    /// As the note's row keeps them, for anyone reading the database: only what's set.
    public var rowProperties: [String: TeamJSON] { values.filter { $0.key != "distill" && !$0.value.isNull } }
}

/// What a change, or a version, did to a note: lines added and removed (`NoteVersions.change`) and the sections it
/// touched (`DistillSections.touched`).
public struct TeamNoteStats: Equatable, Sendable {
    public var added: Int
    public var removed: Int
    public var sections: [String]

    public init(added: Int = 0, removed: Int = 0, sections: [String] = []) {
        self.added = added
        self.removed = removed
        self.sections = sections
    }

    public static func between(_ old: String, _ new: String) -> TeamNoteStats {
        let change = NoteVersions.change(from: old, to: new)
        return TeamNoteStats(added: change.added, removed: change.removed, sections: DistillSections.touched(from: old, to: new).sorted())
    }
}

/// A change of a note's document as a Mac sends it: its bytes, hash and dependencies, what it did, and, when it expects to
/// extend a version, that version's first change and the whole version's numbers.
public struct TeamNoteChange: Equatable, Sendable {
    public var id: UUID
    public var hash: String
    public var deps: [String]
    public var bytes: Data
    public var stats: TeamNoteStats
    /// The first change of the version it expects to extend, and that version's numbers with it.
    public var versionFirst: String?
    public var versionStats: TeamNoteStats?

    public init(id: UUID = UUID(), hash: String, deps: [String], bytes: Data, stats: TeamNoteStats = TeamNoteStats(),
                versionFirst: String? = nil, versionStats: TeamNoteStats? = nil) {
        self.id = id
        self.hash = hash
        self.deps = deps
        self.bytes = bytes
        self.stats = stats
        self.versionFirst = versionFirst
        self.versionStats = versionStats
    }

    public var json: TeamJSON {
        var object: [String: TeamJSON] = ["id": TeamJSON(id), "hash": .string(hash), "deps": TeamJSON(deps), "change": TeamJSON(bytes: bytes),
                                          "lines_added": .number(Double(stats.added)), "lines_removed": .number(Double(stats.removed)),
                                          "sections": TeamJSON(stats.sections)]
        if let versionFirst, let versionStats {
            object["version_first"] = .string(versionFirst)
            object["version_added"] = .number(Double(versionStats.added))
            object["version_removed"] = .number(Double(versionStats.removed))
            object["version_sections"] = TeamJSON(versionStats.sections)
        }
        return .object(object)
    }
}

// MARK: Distill's records

/// A distill and its items as the team database keeps them (`distills`, `distill_items`): DS1's fields that have columns
/// in them, the rest in `extra`. Names go as the team names them and come back as this Mac names them.
public enum TeamDistillRows {
    /// The distill's row and its items' rows, in the order they're shown. `teamName` turns this Mac's names ("You",
    /// "Claude Code") into the team's ("Sam", "Claude Code (Sam)").
    public static func rows(_ record: DistillRecord, binder: UUID, teamName: (String) -> String) -> (distill: TeamRow, items: [TeamRow]) {
        var extra: [String: TeamJSON] = ["ran_by": .string(teamName(record.ranBy)), "ran_by_agent": .bool(record.ranByAgent),
                                         "read_by_agent": .bool(record.readByAgent)]
        if let version = record.version { extra["version"] = .string(version) }
        if let after = record.after { extra["after"] = TeamJSON(after) }
        if let card = record.requestCard { extra["request_card"] = TeamJSON(card) }
        if let placed = record.placedByAgent { extra["placed_by_agent"] = .bool(placed) }
        if !record.updates.isEmpty, let data = try? JSONEncoder().encode(record.updates), let updates = try? JSONDecoder().decode(TeamJSON.self, from: data) {
            extra["updates"] = updates
        }
        let distill: TeamRow = ["id": TeamJSON(record.id), "binder_id": TeamJSON(binder), "note_id": TeamJSON(record.note),
                                "reader": .string(record.readByAgent ? teamName(record.readBy) : record.readBy),
                                "read_at": TeamJSON(record.at), "note_version_id": TeamJSON(record.version.flatMap(UUID.init(uuidString:))),
                                "status": .string(record.status.rawValue), "extra": .object(extra)]
        let items: [TeamRow] = record.items.enumerated().map { index, item in
            var itemExtra: [String: TeamJSON] = ["dropped": .bool(item.dropped)]
            if let hash = item.sectionHash { itemExtra["section_hash"] = .string(hash) }
            if let how = item.meantForHow { itemExtra["meant_for_how"] = .string(how) }
            if let hint = item.hint { itemExtra["hint"] = .string(hint.rawValue) }
            if let quote = item.quote { itemExtra["quote"] = .string(quote) }
            return ["id": TeamJSON(item.id), "binder_id": TeamJSON(binder), "distill_id": TeamJSON(record.id), "position": .number(Double(index)),
                    "title": .string(item.title), "brief": .string(item.brief), "done_when": .string(item.doneWhen),
                    "section": TeamJSON(item.section), "waits_for": TeamJSON(item.waitsFor), "size": TeamJSON(item.size?.rawValue),
                    "meant_for": TeamJSON(item.meantFor.map(teamName)), "card_id": TeamJSON(item.card), "extra": .object(itemExtra)]
        }
        return (distill, items)
    }

    /// A distill read back from its rows (items in any order; those deleted left out). `localName` turns the team's names
    /// into this Mac's. Nil for a row that isn't a distill.
    public static func record(_ distill: TeamRow, items: [TeamRow], localName: (String) -> String) -> DistillRecord? {
        guard let id = distill["id"]?.uuid, let note = distill["note_id"]?.uuid else { return nil }
        let extra = distill["extra"]?.object ?? [:]
        let readByAgent = extra["read_by_agent"]?.bool ?? false
        let reader = distill["reader"]?.string ?? ""
        var updates: [DistillUpdate] = []
        if let list = extra["updates"], let data = try? JSONEncoder().encode(list) {
            updates = (try? JSONDecoder().decode([DistillUpdate].self, from: data)) ?? []
        }
        let read = items.filter { $0.deletedAt == nil && $0["distill_id"]?.uuid == id }
            .sorted { ($0["position"]?.double ?? 0) < ($1["position"]?.double ?? 0) }
        let records: [DistillItem] = read.compactMap { row in
            guard let itemID = row["id"]?.uuid, let title = row["title"]?.string else { return nil }
            let itemExtra = row["extra"]?.object ?? [:]
            return DistillItem(id: itemID, title: title, brief: row["brief"]?.string ?? "", doneWhen: row["done_when"]?.string ?? "",
                               section: row["section"]?.string, sectionHash: itemExtra["section_hash"]?.string,
                               quote: itemExtra["quote"]?.string, waitsFor: row["waits_for"]?.array?.compactMap(\.uuid) ?? [],
                               size: row["size"]?.string.flatMap(DistillItem.Size.init(rawValue:)),
                               meantFor: row["meant_for"]?.string.map(localName), meantForHow: itemExtra["meant_for_how"]?.string,
                               hint: itemExtra["hint"]?.string.flatMap(DistillItem.Hint.init(rawValue:)), card: row["card_id"]?.uuid,
                               dropped: itemExtra["dropped"]?.bool ?? false)
        }
        return DistillRecord(id: id, note: note, ranBy: localName(extra["ran_by"]?.string ?? ""), ranByAgent: extra["ran_by_agent"]?.bool ?? false,
                             readBy: readByAgent ? localName(reader) : reader, readByAgent: readByAgent,
                             at: distill["read_at"]?.date ?? distill["created_at"]?.date ?? Date(timeIntervalSince1970: 0),
                             version: extra["version"]?.string ?? distill["note_version_id"]?.uuid?.uuidString,
                             status: distill["status"]?.string.flatMap(DistillRecord.Status.init(rawValue:)) ?? .proposed,
                             items: records, after: extra["after"]?.uuid, updates: updates, requestCard: extra["request_card"]?.uuid,
                             placedByAgent: extra["placed_by_agent"]?.bool)
    }
}

// MARK: Calls

extension TeamCall {
    /// A note shared through the database, with its first changes. `fields`: folder_id, title, body, properties, distill,
    /// document, document_heads, document_changes, origin_heads, created_at; for one from a team folder, imported_author,
    /// author, started_at, ended_at, claim. `undelete`: put back one that was deleted (Undo).
    public static func createNote(_ note: UUID, binder: UUID, fields: [String: TeamJSON], changes: [TeamNoteChange], agent: UUID? = nil,
                                  undelete: Bool = false, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "create_note", arguments: [.uuid("p_note", note), .uuid("p_binder", binder), .json("p_fields", .object(fields)),
                                                      .json("p_changes", .array(changes.map(\.json))), .uuid("p_agent", agent),
                                                      .boolean("p_undelete", undelete)], operation: operation)
    }

    /// More of a note's changes. `restores`: the version its one change puts back.
    public static func addNoteChanges(_ note: UUID, changes: [TeamNoteChange], agent: UUID? = nil, restores: UUID? = nil,
                                      operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "add_note_changes", arguments: [.uuid("p_note", note), .json("p_changes", .array(changes.map(\.json))),
                                                           .uuid("p_agent", agent), .uuid("p_restores", restores)], operation: operation)
    }

    /// The note whole: document, document_heads, document_changes, body, title, properties, distill.
    public static func saveNote(_ note: UUID, fields: [String: TeamJSON], agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "save_note", arguments: [.uuid("p_note", note), .json("p_fields", .object(fields)), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// A note to a folder (nil: the top) in its binder, or in another shared binder.
    public static func moveNote(_ note: UUID, binder: UUID?, folder: UUID?, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "move_note", arguments: [.uuid("p_note", note), .uuid("p_binder", binder), .uuid("p_folder", folder),
                                                    .uuid("p_agent", agent)], operation: operation)
    }

    public static func nameNoteVersion(_ version: UUID, name: String, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "name_note_version", arguments: [.uuid("p_version", version), .text("p_name", name), .uuid("p_agent", agent)],
                 operation: operation)
    }

    /// The version a distill read: by its id, or by the hash of the change it read the note at (the version that change
    /// went in).
    public static func markNoteVersion(_ note: UUID, version: UUID?, hash: String? = nil, distill: UUID, agent: UUID? = nil,
                                       operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "mark_note_version", arguments: [.uuid("p_note", note), .uuid("p_version", version), .uuid("p_distill", distill),
                                                            .text("p_hash", hash), .uuid("p_agent", agent)], operation: operation)
    }

    /// This person is in a note, or has left it: sent at once, never kept waiting.
    public static func beInNote(_ note: UUID, here: Bool, kind: TeamPresenceKind = .viewing, distill: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "be_in_note", arguments: [.uuid("p_note", note), .boolean("p_here", here), .text("p_kind", kind.rawValue),
                                                     .uuid("p_distill", distill)], operation: operation)
    }

    /// A folder made, renamed, moved or put back. `fields`: name, parent_id, position, imported_author.
    public static func putFolder(_ folder: UUID, binder: UUID, fields: [String: TeamJSON], agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "put_folder", arguments: [.uuid("p_folder", folder), .uuid("p_binder", binder), .json("p_fields", .object(fields)),
                                                     .uuid("p_agent", agent)], operation: operation)
    }

    /// A folder deleted; what it held moves up to where it was.
    public static func deleteFolder(_ folder: UUID, agent: UUID? = nil, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "delete_folder", arguments: [.uuid("p_folder", folder), .uuid("p_agent", agent)], operation: operation)
    }

    /// A team folder's binder, brought in once. `author`: the member who made it there, when they're in the team; `claim`,
    /// this Mac's own id in the folder.
    public static func importBinder(_ binder: UUID, name: String, fields: [String: TeamJSON], importedAuthor: TeamImportedAuthor, author: UUID?,
                                    claim: String?, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "import_binder", arguments: [.uuid("p_binder", binder), .text("p_name", name), .json("p_fields", .object(fields)),
                                                        .json("p_imported_author", importedAuthor.json), .uuid("p_author", author),
                                                        .text("p_claim", claim)], operation: operation)
    }

    /// A team folder's meeting, with its transcript (never its audio), brought in once.
    public static func importMeeting(_ meeting: UUID, binder: UUID, fields: [String: TeamJSON], segments: [TeamJSON],
                                     importedAuthor: TeamImportedAuthor, author: UUID?, claim: String?, operation: UUID = UUID()) -> TeamCall {
        TeamCall(function: "import_meeting", arguments: [.uuid("p_meeting", meeting), .uuid("p_binder", binder), .json("p_fields", .object(fields)),
                                                         .json("p_segments", .array(segments)), .json("p_imported_author", importedAuthor.json),
                                                         .uuid("p_author", author), .text("p_claim", claim)], operation: operation)
    }

    /// The note a call is about, for the calls that change a note.
    public var note: UUID? {
        guard ["create_note", "add_note_changes", "save_note", "move_note", "be_in_note", "mark_note_version"].contains(function) else { return nil }
        return argument("p_note").flatMap(UUID.init(uuidString:))
    }
}

/// Operation ids for moving a folder team over: each item once per member, however often the move runs.
public enum TeamMoveIDs {
    public static func binder(_ id: UUID, member: UUID) -> UUID { TeamOperationID.derived("move binder \(id.uuidString.lowercased()) by \(member.uuidString.lowercased())") }
    public static func folder(_ id: UUID, member: UUID) -> UUID { TeamOperationID.derived("move folder \(id.uuidString.lowercased()) by \(member.uuidString.lowercased())") }
    public static func note(_ id: UUID, member: UUID) -> UUID { TeamOperationID.derived("move note \(id.uuidString.lowercased()) by \(member.uuidString.lowercased())") }
    public static func meeting(_ id: UUID, member: UUID) -> UUID { TeamOperationID.derived("move meeting \(id.uuidString.lowercased()) by \(member.uuidString.lowercased())") }
}

// MARK: Moving a folder team over

/// What a Mac that moved its team to a team database leaves in the team folder (`_binders/moved.json`), so a newer Binders
/// still on folder sync can say what happened. An older one never reads it.
public struct TeamMoveMarker: Codable, Equatable, Sendable {
    public var version: Int
    /// The team database, as people know it: its database and server.
    public var database: String
    public var host: String
    /// Who moved first, as the team folder knows them, and when.
    public var by: TeamAuthor
    public var at: Date

    public init(version: Int = 1, database: String, host: String, by: TeamAuthor, at: Date) {
        self.version = version
        self.database = database
        self.host = host
        self.by = by
        self.at = at
    }

    public static let fileName = "moved.json"

    /// What Settings → Team says on a Mac still on folder sync.
    public var line: String {
        "\(by.name) moved this team to a team database (\(database) on \(host)) on \(at.formatted(date: .abbreviated, time: .omitted)). "
            + "Ask for an invite, then choose Move This Team to a Database, which brings over what changed here since."
    }

    /// Who in the team database a team folder's author is: the member with the same name, when there's one.
    public static func member(named name: String?, in members: [UUID: TeamDirectory.Member]) -> UUID? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let matches = members.values.filter { !$0.removed && $0.kind == "person" && $0.name.trimmingCharacters(in: .whitespaces)
            .compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return matches.count == 1 ? matches.first?.id : nil
    }
}
