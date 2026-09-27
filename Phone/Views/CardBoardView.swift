import SwiftUI
import BindersKit

/// Opens a card when pushed onto the navigation stack.
struct CardLink: Hashable, Identifiable {
    let id: String
}

/// A binder's board, or every binder's: what needs you first (an agent's question, finished work to check), then what's
/// in progress, ready and waiting. Swipe to approve, start or promote a card; tap one for its story.
struct CardBoardView: View {
    @Environment(MacConnection.self) private var connection
    /// One binder's board; every binder's when nil.
    let binder: String?
    @State private var cards: [Card] = []
    @State private var done: [Card] = []
    @State private var loaded = false
    @State private var newCard = ""
    @State private var adding = false
    @State private var problem: String?
    @State private var opened: CardLink?

    /// Attention first: the cards waiting on you, then the work in hand, then the queue.
    static let order: [BoardColumn] = [.blocked, .review, .inProgress, .ready, .backlog]

    var body: some View {
        List {
            if let binder {
                Section {
                    HStack {
                        TextField("Add a card to \(binder)", text: $newCard)
                            .submitLabel(.done)
                            .onSubmit(add)
                        if adding { ProgressView() } else if !newCard.isEmpty {
                            Button("Add", action: add).buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        OfflineBanner()
                        Text("New cards start in Backlog. Swipe one right to make it Ready for an agent to pick up.")
                    }
                }
            } else {
                OfflineBanner()
            }
            ForEach(Self.order, id: \.self) { column in
                let items = cards.filter { $0.board == column }
                if !items.isEmpty {
                    Section("\(column.title) · \(items.count)") {
                        ForEach(items) { row($0) }
                    }
                }
            }
            if !done.isEmpty {
                Section("Done") {
                    ForEach(done.prefix(10)) { row($0) }
                }
            }
        }
        .overlay {
            if loaded && cards.isEmpty && done.isEmpty {
                ContentUnavailableView("No cards yet", systemImage: "rectangle.split.3x1",
                                       description: Text("Cards are work that you or an agent picks up. Add one here, or swipe a to-do onto the board."))
            }
        }
        .navigationDestination(item: $opened) { CardDetailView(id: $0.id) }
        .refreshable { await load() }
        .task(id: connection.revision("tasks")) { await load() }
        .alert("Couldn't update the Mac", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private func row(_ card: Card) -> some View {
        NavigationLink(value: CardLink(id: card.id)) {
            CardRow(card: card, showsBinder: binder == nil)
        }
        .swipeActions(edge: .leading) {
            switch card.board {
            case .review:
                Button { perform("update_task", ["id": card.id, "column": "done"]) } label: { Label("Approve", systemImage: "checkmark") }
                    .tint(.green)
            case .ready:
                Button { perform("claim_task", ["id": card.id]) } label: { Label("Start", systemImage: "play") }
                    .tint(.accentColor)
            case .backlog:
                Button { perform("update_task", ["id": card.id, "column": "ready"]) } label: { Label("Ready", systemImage: "arrow.right") }
                    .tint(.accentColor)
            default:
                EmptyView()
            }
        }
        .contextMenu {
            Menu("Move to") {
                ForEach(BoardColumn.allCases.filter { $0 != card.board }, id: \.self) { column in
                    Button(column.title) { perform("update_task", ["id": card.id, "column": column.rawValue]) }
                }
            }
            if card.board != .done {
                if card.assignee.isEmpty {
                    Button("Take It") { perform("claim_task", ["id": card.id]) }
                } else if card.assignee == "You" {
                    Button("Let Go") { perform("release_task", ["id": card.id]) }
                }
            }
        }
    }

    // MARK: Data

    private func load() async {
        var arguments: [String: Any] = [:]
        if let binder { arguments["binder"] = binder }
        let key = binder ?? "all"
        if let value = await connection.fetch("list_tasks", arguments, cache: "tasks-\(key)", as: [Card].self).value { cards = value }
        arguments["column"] = "done"
        if let value = await connection.fetch("list_tasks", arguments, cache: "tasks-done-\(key)", as: [Card].self).value { done = value }
        loaded = true
        openForDevelopment()
    }

    private func perform(_ tool: String, _ arguments: [String: Any]) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                _ = try await connection.call(tool, arguments)
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func add() {
        let title = newCard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let binder, !title.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                _ = try await connection.call("create_task", ["title": title, "binder": binder, "column": "backlog"])
                newCard = ""
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// For development: `-openCard blocked` (or any column) opens the first card there, once.
    private static var openedForDevelopment = false
    private func openForDevelopment() {
        guard !Self.openedForDevelopment, let wanted = UserDefaults.standard.string(forKey: "openCard"),
              let card = cards.first(where: { $0.column == wanted }) else { return }
        Self.openedForDevelopment = true
        opened = CardLink(id: card.id)
    }
}

struct CardRow: View {
    let card: Card
    var showsBinder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.title)
                .strikethrough(card.board == .done)
                .foregroundStyle(card.board == .done ? .secondary : .primary)
            // Icon and words close together; a Label in a list row sets the icon apart.
            if card.board == .blocked {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.bubble")
                    Text("Waiting for your answer")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            } else if card.board == .review {
                HStack(spacing: 5) {
                    Image(systemName: "eye")
                    Text("Ready for you to check")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
            }
            let due = Date(iso: card.due)
            if !card.assignee.isEmpty || due != nil || card.links > 0 || showsBinder {
                HStack(spacing: 8) {
                    if !card.assignee.isEmpty {
                        let left = card.board == .inProgress ? card.minutesLeft.map { " · \($0) min" } ?? "" : ""
                        Chip(text: card.assignee + left, symbol: card.assigneeIsAgent ? "sparkles" : "person")
                    }
                    if let due {
                        Chip(text: due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), symbol: "calendar",
                             urgent: due < .now && card.board != .done)
                    }
                    if card.links > 0 { Chip(text: "\(card.links)", symbol: "link") }
                    if showsBinder { Text(card.binder).font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One card: who has it, what it's about, its links and its story, with a box to answer an agent's question or comment.
struct CardDetailView: View {
    @Environment(MacConnection.self) private var connection
    let id: String
    @State private var card: CardDetail?
    @State private var reply = ""
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var replying: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OfflineBanner()
                if let card {
                    header(card)
                    if let question = card.question { questionBox(question) }
                    if card.board == .review { reviewBox(card) }
                    if !card.details.isEmpty { MarkdownText(markdown: card.details) }
                    if !card.links.isEmpty { links(card.links) }
                    if !card.source.isEmpty || !(card.todo ?? "").isEmpty { origin(card) }
                    timeline(card)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(card?.binder ?? "Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let card {
                ToolbarItem(placement: .topBarTrailing) { actions(card) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if card != nil { composer }
        }
        .task(id: connection.revision("tasks")) { await load() }
        .alert("Couldn't update the Mac", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    // MARK: Parts

    private func header(_ card: CardDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.title).font(.title2.weight(.bold))
            HStack(spacing: 8) {
                Text(card.board.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint(card.board).opacity(0.15)))
                    .foregroundStyle(tint(card.board))
                if !card.assignee.isEmpty {
                    Chip(text: card.assignee, symbol: card.assigneeIsAgent ? "sparkles" : "person")
                }
                if let due = Date(iso: card.due) {
                    Chip(text: due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), symbol: "calendar",
                         urgent: due < .now && card.board != .done)
                }
            }
        }
    }

    private func questionBox(_ question: CardEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(question.who) asked", systemImage: "questionmark.bubble")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(question.text).textSelection(.enabled)
            Text("Your answer sends the card back to work.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    private func reviewBox(_ card: CardDetail) -> some View {
        let summary = card.timeline.last { $0.kind == "completed" }
        return VStack(alignment: .leading, spacing: 10) {
            Label(summary.map { "\($0.who) finished it" } ?? "Ready for you to check", systemImage: "eye")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            if let summary, !summary.text.isEmpty { Text(summary.text).textSelection(.enabled) }
            HStack {
                Button { perform("update_task", ["column": "done"]) } label: { Label("Approve", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                Button("Send Back") {
                    perform("update_task", ["column": "in_progress"])
                    replying = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }

    private func links(_ links: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Links").font(.headline)
            ForEach(links, id: \.self) { link in
                if let url = URL(string: link), url.scheme != nil {
                    Link(destination: url) { Label(link, systemImage: "link").lineLimit(1).truncationMode(.middle) }
                } else {
                    Label(link, systemImage: "doc").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func origin(_ card: CardDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !card.source.isEmpty { Label("From \(card.source)", systemImage: "arrow.turn.down.right") }
            if !(card.todo ?? "").isEmpty { Label("Its to-do is ticked off when this card is done.", systemImage: "checklist") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func timeline(_ card: CardDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timeline").font(.headline)
            ForEach(Array(card.timeline.enumerated()), id: \.offset) { _, event in CardEventRow(event: event) }
        }
    }

    private func actions(_ card: CardDetail) -> some View {
        Menu {
            if card.board != .done {
                if card.assignee.isEmpty {
                    Button("Take It") { perform("claim_task", [:]) }
                } else if card.assignee == "You" {
                    Button("Let Go") { perform("release_task", [:]) }
                }
            }
            Section("Move to") {
                ForEach(BoardColumn.allCases.filter { $0 != card.board }, id: \.self) { column in
                    Button(column.title) { perform("update_task", ["column": column.rawValue]) }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .disabled(!connection.isConnected)
        .accessibilityLabel("Card actions")
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(card?.question.map { "Answer \($0.who)" } ?? "Add a comment", text: $reply, axis: .vertical)
                .lineLimit(1...5)
                .focused($replying)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
            if sending {
                ProgressView().padding(.bottom, 6)
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connection.isConnected)
                .accessibilityLabel(card?.question != nil ? "Send answer" : "Send comment")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func tint(_ column: BoardColumn) -> Color {
        switch column {
        case .blocked: .orange
        case .review, .inProgress: .accentColor
        case .done: .green
        default: .secondary
        }
    }

    // MARK: Data

    private func load() async {
        let result = await connection.fetch("get_task", ["id": id], cache: "task-\(id)", as: CardDetail.self)
        card = result.value
        // For development, as the Simulator can't be typed into from a script: `-reply "…"` sends that, once, when connected.
        if !Self.repliedForDevelopment, result.fresh, let text = UserDefaults.standard.string(forKey: "reply"), !text.isEmpty {
            Self.repliedForDevelopment = true
            reply = text
            send()
        }
    }

    private static var repliedForDevelopment = false

    private func perform(_ tool: String, _ arguments: [String: Any]) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        var arguments = arguments
        arguments["id"] = id
        Task {
            do {
                _ = try await connection.call(tool, arguments)
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                _ = try await connection.call("comment_task", ["id": id, "text": text])
                reply = ""
                replying = false
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

/// One line of a card's story, as on the Mac.
struct CardEventRow: View {
    let event: CardEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(event.kind == "question" ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(event.who).font(.caption.weight(.semibold))
                    if event.agent { Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.accentColor) }
                    Text(headline).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let date = Date(iso: event.when) {
                        Text(date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var column: String { BoardColumn(rawValue: event.to)?.title ?? "" }

    private var headline: String {
        switch event.kind {
        case "created": "added it\(column.isEmpty ? "" : " to \(column)")"
        case "moved": "moved it to \(column)"
        case "claimed": "picked it up"
        case "released": "let it go"
        case "lapsed": "went quiet"
        case "progress": "reported progress"
        case "question": "asked"
        case "answer": "answered"
        case "completed": column == "Done" ? "finished it" : "finished it, for review"
        case "edited": "edited it"
        default: "commented"
        }
    }

    private var symbol: String {
        switch event.kind {
        case "created": "plus.circle"
        case "moved": "arrow.right.circle"
        case "claimed": "hand.raised"
        case "released", "lapsed": "arrow.uturn.backward.circle"
        case "progress": "chart.line.uptrend.xyaxis"
        case "question": "questionmark.bubble"
        case "answer": "text.bubble"
        case "completed": "checkmark.circle"
        case "edited": "pencil"
        default: "bubble.left"
        }
    }
}
