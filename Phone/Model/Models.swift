import Foundation
import BindersKit

// What the Mac's tools return (see docs/AUTOMATIONS.md), decoded with snake_case keys.

struct Todo: Decodable, Identifiable, Hashable {
    let id: String
    let task: String
    let owner: String?
    let kind: String
    var status: String
    let due: String?
    let dueAsSaid: String?
    let to: String?
    let source: String
    let sourceId: String?
    let binder: String?
    let created: String?
    /// The card it's on, when it's on a board.
    let cardId: String?
    let cardColumn: String?

    var isDone: Bool { status == "done" }
    var isOnBoard: Bool { !(cardId ?? "").isEmpty }
    var dueDate: Date? { due.flatMap(Date.init(iso:)) }
    /// Whose it is, when it isn't simply yours.
    var ownerName: String? {
        guard let owner, !owner.isEmpty, owner != "You" else { return nil }
        return owner
    }
}

/// A card on a binder's board, as list_tasks gives it.
struct Card: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let column: String
    let assignee: String
    let assigneeIsAgent: Bool
    let claimExpires: String
    let binder: String
    let due: String
    let links: Int
    let updated: String
    let preview: String
    let todo: String?

    var board: BoardColumn { BoardColumn(rawValue: column) ?? .backlog }
    /// Minutes left on an agent's claim.
    var minutesLeft: Int? {
        guard assigneeIsAgent, let date = Date(iso: claimExpires) else { return nil }
        return max(0, Int(date.timeIntervalSinceNow / 60))
    }
}

/// One card in full, as get_task gives it.
struct CardDetail: Decodable {
    let id: String
    let title: String
    let column: String
    let assignee: String
    let assigneeIsAgent: Bool
    let claimExpires: String
    let binder: String
    let due: String
    let details: String
    let links: [String]
    let source: String
    let todo: String?
    let timeline: [CardEvent]

    var board: BoardColumn { BoardColumn(rawValue: column) ?? .backlog }
    /// The agent's question the card is waiting on.
    var question: CardEvent? { board == .blocked ? timeline.last { $0.kind == "question" } : nil }
}

struct CardEvent: Decodable, Hashable {
    let when: String
    let who: String
    let agent: Bool
    let kind: String
    let text: String
    let to: String
}

struct BinderInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let archived: Bool
    let shared: Bool
    let meetings: Int
    let notes: Int
    let color: Int?

    var counts: String {
        [meetings == 1 ? "1 meeting" : "\(meetings) meetings", notes == 1 ? "1 note" : "\(notes) notes"].joined(separator: " · ")
    }
}

struct NoteSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let updated: String
    let binder: String
    let preview: String
}

struct Note: Decodable {
    let id: String
    let title: String
    let updated: String
    let binder: String
    let text: String
    let digest: String
}

struct MeetingSummary: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let date: String
    let durationMinutes: Int
    let attendees: [String]
    let binder: String
    let status: String
    let preview: String
}

struct Meeting: Decodable {
    let id: String
    let title: String
    let date: String
    let durationMinutes: Int
    let attendees: [String]
    let app: String
    let binder: String
    let notes: String
    let ownNotes: String
}

struct Passage: Decodable, Identifiable, Hashable {
    var id: String { "\(sourceId)|\(text.prefix(40))" }
    let kind: String
    let sourceId: String
    let title: String
    let date: String
    let binder: String
    let text: String
}

struct Answer: Decodable {
    let answer: String
    let sources: [Passage]
}

extension Date {
    init?(iso text: String) {
        guard !text.isEmpty, let date = ISO8601DateFormatter().date(from: text) else { return nil }
        self = date
    }
}

extension String {
    /// "Today 3:10 PM", "Tuesday", "Sep 12": a timestamp from the Mac, as people read dates.
    var friendlyDate: String {
        guard let date = Date(iso: self) else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today \(date.formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
