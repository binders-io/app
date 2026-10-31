import SwiftData
import SwiftUI
import BindersKit

/// What waits on you, at the top of Home and Today: agents' questions and requests for your approval, finished work to
/// check, agents' suggestions of who should take a card, and captures with something to look at. Nothing at all when
/// nothing waits. One item opens straight away, but for an approval, decided in the list; several open a short list.
struct NeedsYouStrip: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(DictationController.self) private var controller
    @Query private var cards: [TaskCard]
    @Query private var captures: [MeetingRecord]
    @State private var listing: NeedsYou.Kind?

    init() {
        let blocked = BoardColumn.blocked.rawValue, review = BoardColumn.review.rawValue, done = BoardColumn.done.rawValue
        _cards = Query(filter: #Predicate<TaskCard> { $0.columnRaw == blocked || $0.columnRaw == review || ($0.meantForByAgent && $0.columnRaw != done) },
                       sort: [SortDescriptor(\.updatedAt, order: .reverse)])
        let kind = MeetingRecord.conversationKind
        let since = Date().addingTimeInterval(-3 * 86_400)
        _captures = Query(filter: #Predicate<MeetingRecord> { $0.kind == kind && $0.createdAt > since },
                          sort: [SortDescriptor(\.createdAt, order: .reverse)])
    }

    private var questions: [TaskCard] { cards.filter { $0.column == .blocked } }
    private var reviews: [TaskCard] { cards.filter { $0.column == .review } }

    /// An agent's suggestion of who should take it, with nobody on it yet.
    private var handOffs: [TaskCard] {
        cards.filter { $0.meantForByAgent && $0.column != .done && !BoardRules.isClaimed($0.state, at: .now) }
    }
    /// Captures with a card or an idea offered and not answered, or that couldn't be written up.
    private var waitingCaptures: [MeetingRecord] {
        captures.filter { record in
            record.suggestions.contains { $0.kind != .answer && $0.status == .offered }
                || (record.status == "ready" && record.summary.trimmed.isEmpty && !(record.errorMessage ?? "").isEmpty)
        }
    }

    private var needs: NeedsYou {
        NeedsYou(questions: questions.count, reviews: reviews.count, handOffs: handOffs.count, captures: waitingCaptures.count)
    }

    var body: some View {
        let needs = needs
        let kinds = NeedsYou.Kind.allCases.filter { needs.count($0) > 0 }
        // Something new that needs you files in, and its count rolls.
        Group {
            if !needs.isEmpty {
                strip(needs, kinds: kinds)
                    .transition(.filed)
            }
        }
        .filing(kinds)
    }

    private func strip(_ needs: NeedsYou, kinds: [NeedsYou.Kind]) -> some View {
        // On one line while it fits; on a narrow page the chips carry on to the next.
        Wrapping(spacing: 10, lineSpacing: 8) {
            Label("Needs you", systemImage: "bell.badge").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(BindersTheme.needsYou)
            ForEach(kinds, id: \.self) { kind in
                Button { tapped(kind) } label: {
                    Label(kind.line(needs.count(kind)), systemImage: kind.symbol)
                        .rollingCount(needs.count(kind))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                // Each kind waits on you, finished work to check too: amber, as on the iPhone.
                .tint(BindersTheme.needsYou)
                .popover(isPresented: Binding(get: { listing == kind }, set: { if !$0 { listing = nil } }), arrowEdge: .bottom) {
                    list(kind)
                }
                .transition(.filed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tapped(_ kind: NeedsYou.Kind) {
        switch kind {
        // A request for your approval is decided right here, with exactly what it asks in front of you.
        case .questions where questions.count == 1 && questions[0].waitingApproval() == nil: open(questions[0])
        case .reviews where reviews.count == 1: open(reviews[0])
        case .handOffs where handOffs.count == 1: open(handOffs[0])
        case .captures where waitingCaptures.count == 1: open(waitingCaptures[0])
        default: listing = kind
        }
    }

    @ViewBuilder
    private func list(_ kind: NeedsYou.Kind) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch kind {
            case .questions:
                ForEach(questions) { card in
                    if let waiting = card.waitingApproval() {
                        VStack(alignment: .leading, spacing: 4) {
                            row(card.title, detail: nil) { open(card) }
                            ApprovalBox(card: card, event: waiting.event, approval: waiting.approval, compact: true)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 6)
                        }
                    } else {
                        row(card.title, detail: question(on: card)) { open(card) }
                    }
                }
            case .reviews:
                ForEach(reviews) { card in row(card.title, detail: card.assignee.map { "From \($0)" }) { open(card) } }
            case .handOffs:
                ForEach(handOffs) { card in
                    HStack {
                        row(card.title, detail: card.meantFor.map { "Suggested for \($0)" }) { open(card) }
                        if let name = card.meantFor {
                            Button("Give to \(name)") {
                                // As on the card: yours now, and from Backlog to Ready, which wakes it at once.
                                controller.board.give(card, to: name, by: .you)
                            }
                                .buttonStyle(.borderedProminent)
                                .padding(.trailing, 10)
                        }
                    }
                }
            case .captures:
                ForEach(waitingCaptures) { record in
                    row(record.title, detail: record.errorMessage ?? record.suggestions.first { $0.kind != .answer && $0.status == .offered }.map { "Put this on the board? \($0.text)" }) {
                        open(record)
                    }
                }
            case .moments:
                // What you said near the iPhone is offered and answered there: this Mac doesn't count it.
                EmptyView()
            }
        }
        .padding(.vertical, 6)
        .frame(width: 420)
    }

    private func row(_ title: String, detail: String?, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    /// The question a blocked card waits on, as its agent asked it.
    private func question(on card: TaskCard) -> String? {
        let timeline = controller.board.timeline(card.id)
        guard let index = BoardRules.waitingQuestion(in: timeline.map { (kind: $0.kindRaw, to: $0.toColumn ?? "") }) else { return nil }
        return "\(timeline[index].author) asks: \(timeline[index].text)"
    }

    private func open(_ card: TaskCard) {
        listing = nil
        navigation.open(card: card)
    }

    private func open(_ record: MeetingRecord) {
        listing = nil
        navigation.open(meeting: record)
    }
}

extension HubNavigation {
    /// A card, in its own window: the page you're on stays as it is.
    func open(card: TaskCard) {
        CardWindows.shared.open(card)
    }

    /// The board a card is on, in the Binders window.
    func showOnBoard(_ card: TaskCard) {
        binderID = card.binderID ?? Store.shared.defaultBinder().id
        pendingBinderTab = .board
        selection = .binder
        HubWindowController.shared.show()
    }

    /// A meeting or capture, in its binder.
    func open(meeting: MeetingRecord) {
        binderID = meeting.binderID ?? Store.shared.defaultBinder().id
        pendingBinderTab = .listing(meeting)
        pendingMeetingID = meeting.id
        selection = .binder
    }
}
