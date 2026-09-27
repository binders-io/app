import Foundation
import SwiftData
import BindersKit

/// A card on a binder's board: a piece of work someone, or some agent, can pick up.
@Model
final class TaskCard {
    @Attribute(.unique) var id: UUID
    var binderID: UUID?
    var title: String
    /// Markdown.
    var details: String = ""
    var columnRaw: String = BoardColumn.backlog.rawValue
    /// Order within its column; lower is higher up.
    var position: Double = 0
    var assignee: String?
    var assigneeIsAgent: Bool = false
    var claimExpiresAt: Date?
    var dueAt: Date?
    /// Pull requests, files, pages: whatever the work produced or points at.
    var links: [String] = []
    /// Where it came from: "meeting", "note", "commitment"…, with the item's id and title.
    var sourceKind: String?
    var sourceID: String?
    var sourceTitle: String?
    var createdBy: String = "You"
    var createdAt: Date
    var updatedAt: Date
    /// The same card in Jira, Linear or GitHub, once one is connected.
    var externalKey: String?
    var externalURL: String?

    init(title: String, binderID: UUID?, column: BoardColumn = .backlog) {
        self.id = UUID()
        self.title = title
        self.binderID = binderID
        self.columnRaw = column.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.position = Date().timeIntervalSinceReferenceDate
    }

    var column: BoardColumn {
        get { BoardColumn(rawValue: columnRaw) ?? .backlog }
        set { columnRaw = newValue.rawValue }
    }

    var state: CardState {
        get { CardState(column: column, assignee: assignee, assigneeIsAgent: assigneeIsAgent, claimExpires: claimExpiresAt) }
        set {
            column = newValue.column
            assignee = newValue.assignee
            assigneeIsAgent = newValue.assigneeIsAgent
            claimExpiresAt = newValue.claimExpires
        }
    }
}

/// One line of a card's timeline: a move, a claim, a progress report, a question, an answer, a comment.
@Model
final class TaskEvent {
    @Attribute(.unique) var id: UUID
    var taskID: UUID
    var kindRaw: String
    var author: String
    var authorIsAgent: Bool
    var text: String
    var fromColumn: String?
    var toColumn: String?
    var createdAt: Date

    enum Kind: String {
        case created, moved, claimed, released, lapsed, progress, question, answer, comment, completed, edited
    }

    init(taskID: UUID, kind: Kind, author: BoardActor, text: String = "", from: BoardColumn? = nil, to: BoardColumn? = nil) {
        self.id = UUID()
        self.taskID = taskID
        self.kindRaw = kind.rawValue
        self.author = author.name
        self.authorIsAgent = author.isAgent
        self.text = text
        self.fromColumn = from?.rawValue
        self.toColumn = to?.rawValue
        self.createdAt = Date()
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .comment }
}
