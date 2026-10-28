import Foundation
import BindersKit

/// What the Manager deleted or changed, kept with its change as JSON, so Undo can make it again after a restart.
struct ManagerCardSnapshot: Codable {
    var id: UUID
    var title: String
    var details: String
    var column: String
    var binder: UUID?
    var links: [String]
    var meantFor: String?
    var due: Date?
    var sourceKind: String?
    var sourceID: String?
    var sourceTitle: String?

    @MainActor
    init(_ card: TaskCard) {
        id = card.id
        title = card.title
        details = card.details
        column = card.column.rawValue
        binder = card.binderID
        links = card.links
        meantFor = card.meantFor
        due = card.dueAt
        sourceKind = card.sourceKind
        sourceID = card.sourceID
        sourceTitle = card.sourceTitle
    }

    var json: String { ManagerSnapshotJSON.text(self) }
    static func read(_ text: String?) -> ManagerCardSnapshot? { ManagerSnapshotJSON.read(text) }
}

struct ManagerNoteSnapshot: Codable {
    var id: UUID
    var text: String
    var binder: UUID?
    var folder: UUID?
    var createdAt: Date
    var madeBy: String?
    var staysUnshared: Bool

    init(_ entry: NoteTrash.Entry) {
        id = entry.id
        text = entry.text
        binder = entry.binderID
        folder = entry.folderID
        createdAt = entry.createdAt
        madeBy = entry.madeBy
        staysUnshared = entry.staysUnshared
    }

    var json: String { ManagerSnapshotJSON.text(self) }
    static func read(_ text: String?) -> ManagerNoteSnapshot? { ManagerSnapshotJSON.read(text) }
}

struct ManagerBinderSnapshot: Codable {
    var name: String
    var color: Int
    var archived: Bool

    @MainActor
    init(_ binder: BinderRecord) {
        name = binder.name
        color = binder.colorIndex
        archived = binder.archived
    }

    var json: String { ManagerSnapshotJSON.text(self) }
    static func read(_ text: String?) -> ManagerBinderSnapshot? { ManagerSnapshotJSON.read(text) }
}

enum ManagerSnapshotJSON {
    static func text(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func read<T: Decodable>(_ text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
}
