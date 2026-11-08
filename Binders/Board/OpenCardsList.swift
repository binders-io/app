import SwiftUI
import SwiftData
import BindersKit

/// The cards still open on the boards, newest first: what Home, Today and a binder's Overview show where they listed
/// to-dos, now that what you said you'd do is a card. In one binder, or all; made on one day, or any. Each opens its card.
struct OpenCardsList: View {
    @Environment(HubNavigation.self) private var navigation
    @Query private var cards: [TaskCard]
    @Query private var binders: [BinderRecord]
    private let limit: Int?
    private let showsBinder: Bool

    init(binderID: UUID? = nil, madeOn day: Date? = nil, limit: Int? = nil) {
        self.limit = limit
        showsBinder = binderID == nil
        let done = BoardColumn.done.rawValue
        if let day {
            let start = Calendar.current.startOfDay(for: day)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            _cards = Query(filter: #Predicate<TaskCard> { $0.createdAt >= start && $0.createdAt < end }, sort: [SortDescriptor(\.createdAt, order: .reverse)])
        } else if let binderID {
            _cards = Query(filter: #Predicate<TaskCard> { $0.binderID == binderID && $0.columnRaw != done }, sort: [SortDescriptor(\.updatedAt, order: .reverse)])
        } else {
            _cards = Query(filter: #Predicate<TaskCard> { $0.columnRaw != done }, sort: [SortDescriptor(\.updatedAt, order: .reverse)])
        }
    }

    var body: some View {
        let shown = limit.map { Array(cards.prefix($0)) } ?? cards
        VStack(alignment: .leading, spacing: 2) {
            if shown.isEmpty {
                Text("Nothing open on the boards.").font(.callout).foregroundStyle(.secondary).padding(.vertical, 6)
            }
            ForEach(shown) { card in
                Button { navigation.open(card: card) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: card.column == .done ? "checkmark.circle.fill" : "rectangle.stack")
                            .font(.caption)
                            .foregroundStyle(card.column == .done ? Color.secondary : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title).lineLimit(2).foregroundStyle(.primary)
                            Text(line(for: card)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the card")
            }
            if let limit, cards.count > limit {
                Text("and \(cards.count - limit) more on the boards").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    /// Its column, who has it, and its binder when cards from several are shown.
    private func line(for card: TaskCard) -> String {
        var parts = [card.column.title]
        if let who = card.assignee, !who.isEmpty { parts.append(who) }
        if showsBinder, let name = binders.first(where: { $0.id == card.binderID })?.name { parts.append(name) }
        if let due = card.dueAt { parts.append("due \(CommitmentService.dueLabel(due))") }
        return parts.joined(separator: " · ")
    }
}
