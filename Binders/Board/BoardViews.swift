import SwiftData
import SwiftUI
import BindersKit

/// A binder's board: its cards in six columns, dragged between them by you, picked up by agents over MCP.
struct BoardView: View {
    @Environment(DictationController.self) private var controller
    @Bindable var binder: BinderRecord
    @Query private var cards: [TaskCard]
    @State private var selected: TaskCard?
    @State private var drafting: BoardColumn?
    @State private var draft = ""
    @State private var target: BoardColumn?
    @State private var problem: String?

    init(binder: BinderRecord) {
        self.binder = binder
        let id = binder.id
        _cards = Query(filter: #Predicate<TaskCard> { $0.binderID == id }, sort: [SortDescriptor(\TaskCard.position, order: .reverse)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Drag cards between columns. Agents such as Claude pick up Ready cards through Binders' MCP server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                AddTodosButton(binder: binder)
                Toggle("Agents can finish cards", isOn: $binder.agentsMayFinish)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("When this is off, an agent's finished card goes to Review for you to check.")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(BoardColumn.allCases, id: \.self) { column($0) }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        // Fill the space the binder gives the board, and no more, so the header above stays put.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $selected) { card in
            CardDetailView(card: card).environment(controller)
        }
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

    private func column(_ column: BoardColumn) -> some View {
        var items = cards.filter { $0.column == column }
        if column == .done { items = Array(items.prefix(30)) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(column.title).font(.headline)
                Text("\(cards.filter { $0.column == column }.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if column != .done {
                    Button {
                        drafting = column
                        draft = ""
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add a card to \(column.title)")
                }
            }
            if drafting == column {
                TextField("What needs doing?", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { create(in: column) }
                    .onExitCommand { drafting = nil }
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(items) { card in
                        CardTile(card: card)
                            .onTapGesture { selected = card }
                            .draggable(card.id.uuidString)
                    }
                    if items.isEmpty && drafting != column {
                        Text(Self.hint(column))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(target == column ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        .dropDestination(for: String.self) { ids, _ in
            move(ids, to: column)
            return true
        } isTargeted: { hovering in
            target = hovering ? column : (target == column ? nil : target)
        }
    }

    private static func hint(_ column: BoardColumn) -> String {
        switch column {
        case .backlog: "Ideas and work for later"
        case .ready: "Ready for someone, or some agent, to pick up"
        case .inProgress: "Being worked on"
        case .blocked: "Waiting for an answer"
        case .review: "Finished, waiting for you to check"
        case .done: "Nothing finished yet"
        }
    }

    private func create(in column: BoardColumn) {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        drafting = nil
        guard !title.isEmpty else { return }
        controller.board.create(title: title, binderID: binder.id, column: column == .done ? .backlog : column, by: .you)
        draft = ""
    }

    private func move(_ ids: [String], to column: BoardColumn) {
        for id in ids.compactMap(UUID.init(uuidString:)) {
            guard let card = controller.board.card(id) else { continue }
            do { try controller.board.move(card, to: column, by: .you) } catch { problem = error.localizedDescription }
        }
    }
}

/// A card on the board: its title, who has it, when it's due, and anything that needs you.
struct CardTile: View {
    let card: TaskCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if card.column == .blocked {
                Label("Waiting for your answer", systemImage: "questionmark.bubble")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else if card.column == .review {
                Label("Ready for you to check", systemImage: "eye")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 6) {
                if let assignee = card.assignee, BoardRules.isClaimed(card.state, at: .now) || card.column == .review || card.column == .done {
                    AssigneeChip(name: assignee, isAgent: card.assigneeIsAgent, expires: card.column == .done ? nil : card.claimExpiresAt)
                }
                if let due = card.dueAt, card.column != .done {
                    Badge(text: CommitmentService.dueLabel(due), color: due < .now ? .red : .secondary)
                }
                Spacer(minLength: 0)
                if !card.links.isEmpty {
                    Label("\(card.links.count)", systemImage: "link").font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        .contentShape(Rectangle())
    }
}

/// Who has a card: a person, or an agent with how long its claim has left.
struct AssigneeChip: View {
    let name: String
    let isAgent: Bool
    var expires: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 4) {
                Image(systemName: isAgent ? "sparkles" : "person.fill").imageScale(.small)
                Text(name).lineLimit(1)
                if isAgent, let expires, expires > context.date {
                    Text("· \(max(1, Int(expires.timeIntervalSince(context.date) / 60))) min").foregroundStyle(.secondary)
                }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill((isAgent ? Color.accentColor : Color.primary).opacity(isAgent ? 0.14 : 0.07)))
            .foregroundStyle(isAgent ? Color.accentColor : Color.primary)
        }
    }
}

/// One card, opened: edit it, move it, take it, and follow or join its timeline.
struct CardDetailView: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    @Bindable var card: TaskCard
    @Query private var events: [TaskEvent]
    @State private var reply = ""
    @State private var problem: String?
    @State private var confirmDelete = false

    init(card: TaskCard) {
        self.card = card
        let id = card.id
        _events = Query(filter: #Predicate<TaskEvent> { $0.taskID == id }, sort: [SortDescriptor(\TaskEvent.createdAt)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                TextField("Title", text: $card.title, axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 10)
            controls
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    MarkdownNoteEditor(text: $card.details, fontSize: 13, placeholder: "What's this about? What does done look like?",
                                       inset: NSSize(width: 6, height: 6), compactToolbar: true)
                        .frame(minHeight: 160)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    if !card.links.isEmpty {
                        Text("Links").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(card.links, id: \.self) { link in
                            Button { open(link) } label: {
                                Label(link, systemImage: link.hasPrefix("http") ? "link" : "doc")
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    if let source = card.sourceTitle {
                        Label("From \(source)", systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Delete Card…", role: .destructive) { confirmDelete = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(16)
                .frame(width: 320)
                Divider()
                timeline
            }
        }
        .frame(width: 760, height: 560)
        .alert("Couldn't do that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .confirmationDialog("Delete “\(card.title)”?", isPresented: $confirmDelete) {
            Button("Delete Card", role: .destructive) {
                dismiss()
                DispatchQueue.main.async { controller.board.delete(card) }
            }
        } message: { Text("Its timeline goes with it. This can't be undone.") }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Column", selection: Binding(get: { card.column }, set: { column in attempt { try controller.board.move(card, to: column, by: .you) } })) {
                ForEach(BoardColumn.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            if let assignee = card.assignee, BoardRules.isClaimed(card.state, at: .now) {
                AssigneeChip(name: assignee, isAgent: card.assigneeIsAgent, expires: card.claimExpiresAt)
                Button(assignee == BoardActor.you.name ? "Let Go" : "Take Over") {
                    attempt {
                        if assignee == BoardActor.you.name { try controller.board.release(card, by: .you) } else { try controller.board.claim(card, by: .you) }
                    }
                }
                .help(assignee == BoardActor.you.name ? "Put it back in Ready for someone else" : "Take it from \(assignee)")
            } else if card.column != .done {
                Button("Take It") { attempt { try controller.board.claim(card, by: .you) } }
            }
            Spacer()
            Toggle("Due", isOn: Binding(get: { card.dueAt != nil }, set: { card.dueAt = $0 ? Calendar.current.date(byAdding: .day, value: 1, to: .now) : nil }))
                .toggleStyle(.checkbox)
            if card.dueAt != nil {
                DatePicker("", selection: Binding(get: { card.dueAt ?? .now }, set: { card.dueAt = $0 }), displayedComponents: [.date])
                    .labelsHidden()
                    .fixedSize()
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Timeline").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding([.horizontal, .top], 16)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(events) { event in EventRow(event: event).id(event.id) }
                    }
                    .padding(16)
                }
                .onAppear { if let last = events.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: events.count) { if let last = events.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            Divider()
            HStack(spacing: 8) {
                TextField(card.column == .blocked ? "Answer the question…" : "Add a comment…", text: $reply, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button(card.column == .blocked ? "Answer" : "Send", action: send)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        controller.board.comment(card, text: text, by: .you)
        reply = ""
    }

    private func attempt(_ action: () throws -> Void) {
        do { try action() } catch { problem = error.localizedDescription }
    }

    private func open(_ link: String) {
        if let url = URL(string: link), url.scheme != nil { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: (link as NSString).expandingTildeInPath)) }
    }
}

/// One line of a card's timeline.
struct EventRow: View {
    let event: TaskEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.author).font(.caption.weight(.semibold))
                    if event.authorIsAgent { Image(systemName: "sparkles").font(.caption2).foregroundStyle(Color.accentColor) }
                    Text(headline).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(event.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                }
                if !event.text.isEmpty {
                    Text(event.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(event.kind == .question ? 8 : 0)
                        .background(event.kind == .question ? RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)) : nil)
                }
            }
        }
    }

    private var column: String { event.toColumn.flatMap(BoardColumn.init(rawValue:))?.title ?? "" }

    private var headline: String {
        switch event.kind {
        case .created: "added it\(column.isEmpty ? "" : " to \(column)")"
        case .moved: "moved it to \(column)"
        case .claimed: "picked it up"
        case .released: "let it go"
        case .lapsed: "went quiet"
        case .progress: "reported progress"
        case .question: "asked"
        case .answer: "answered"
        case .comment: "commented"
        case .completed: column == "Done" ? "finished it" : "finished it, for review"
        case .edited: "edited it"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .created: "plus.circle"
        case .moved: "arrow.right.circle"
        case .claimed: "hand.raised"
        case .released, .lapsed: "arrow.uturn.backward.circle"
        case .progress: "chart.line.uptrend.xyaxis"
        case .question: "questionmark.bubble"
        case .answer: "text.bubble"
        case .comment: "bubble.left"
        case .completed: "checkmark.circle"
        case .edited: "pencil"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .question: .orange
        case .completed: .green
        case .lapsed: .secondary
        default: .accentColor
        }
    }
}

/// "Add To-dos": the binder's open to-dos that aren't on its board yet, to pick from and turn into cards.
struct AddTodosButton: View {
    @Environment(DictationController.self) private var controller
    let binder: BinderRecord
    @Query private var meetings: [MeetingRecord]
    @Query private var notes: [NoteItem]
    @Query private var commitments: [CommitmentRecord]
    @Query(filter: #Predicate<TaskCard> { $0.sourceRef != nil }) private var linkedCards: [TaskCard]
    @State private var picking = false

    init(binder: BinderRecord) {
        self.binder = binder
        let id = binder.id
        _meetings = Query(filter: #Predicate<MeetingRecord> { $0.binderID == id }, sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
        _notes = Query(filter: #Predicate<NoteItem> { $0.binderID == id }, sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
        _commitments = Query(filter: #Predicate<CommitmentRecord> { $0.binderID == id }, sort: [SortDescriptor(\CommitmentRecord.createdAt, order: .reverse)])
    }

    /// Open to-dos from the binder's meetings, notes and promises, without the ones that already have a card.
    private var waiting: [TaskEntry] {
        let carded = Set(linkedCards.compactMap(\.sourceRef))
        return TaskCollector.collect(meetings: Array(meetings.prefix(60)), notes: Array(notes.prefix(120)), commitments: Array(commitments.prefix(100)),
                                     openMeeting: { _ in }, openNote: { _ in })
            .filter { !$0.done && !carded.contains($0.ref) }
    }

    var body: some View {
        let waiting = waiting
        Button { picking = true } label: {
            Label(waiting.isEmpty ? "Add To-dos" : "Add To-dos (\(waiting.count))", systemImage: "rectangle.stack.badge.plus")
        }
        .controlSize(.small)
        .disabled(waiting.isEmpty)
        .help(waiting.isEmpty ? "Every open to-do in this binder is on the board." : "Turn to-dos from this binder's meetings, notes and promises into cards")
        .sheet(isPresented: $picking) {
            TodoPickerSheet(binder: binder, todos: waiting).environment(controller)
        }
    }
}

/// Pick to-dos to put on the board. Each card stays linked to its to-do, which is ticked off when the card is done.
struct TodoPickerSheet: View {
    @Environment(DictationController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    let binder: BinderRecord
    let todos: [TaskEntry]
    @State private var chosen: Set<String>
    @State private var column: BoardColumn = .ready

    init(binder: BinderRecord, todos: [TaskEntry], chosen: Set<String> = []) {
        self.binder = binder
        self.todos = todos
        _chosen = State(initialValue: chosen)
    }

    private struct Source: Identifiable {
        let id: UUID
        let kind: TaskEntry.Kind
        let title: String
        let date: Date
        var todos: [TaskEntry]
    }

    private var sources: [Source] {
        var ordered: [Source] = []
        var index: [UUID: Int] = [:]
        for todo in todos {
            if let at = index[todo.sourceID] {
                ordered[at].todos.append(todo)
            } else {
                index[todo.sourceID] = ordered.count
                ordered.append(Source(id: todo.sourceID, kind: todo.kind, title: todo.sourceTitle, date: todo.sourceDate, todos: [todo]))
            }
        }
        return ordered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add to-dos to the \(binder.name) board").font(.headline)
                Text("Open to-dos from this binder's meetings, notes and promises. Each stays open where it is, marked as on the board, and is ticked off when its card is done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(chosen.count == todos.count ? "Select None" : "Select All") {
                    chosen = chosen.count == todos.count ? [] : Set(todos.map(\.ref))
                }
                Spacer()
                Picker("Add to", selection: $column) {
                    Text(BoardColumn.backlog.title).tag(BoardColumn.backlog)
                    Text(BoardColumn.ready.title).tag(BoardColumn.ready)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sources) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: source.kind == .meeting ? "person.2.wave.2" : (source.kind == .commitment ? "hand.raised" : "note.text"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(source.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(source.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(source.todos) { todo in
                                Toggle(isOn: Binding(get: { chosen.contains(todo.ref) },
                                                     set: { if $0 { chosen.insert(todo.ref) } else { chosen.remove(todo.ref) } })) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        if let owner = todo.owner { OwnerChip(name: owner) }
                                        Text(todo.text).fixedSize(horizontal: false, vertical: true)
                                        if let due = todo.due {
                                            Badge(text: CommitmentService.dueLabel(due), color: due < Date() ? .red : .secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 420)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(chosen.count == 1 ? "Add 1 Card" : "Add \(chosen.count) Cards", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// Newest on top, in the order they're listed.
    private func add() {
        for todo in todos.reversed() where chosen.contains(todo.ref) {
            controller.board.create(from: todo.todo, column: column, binderID: binder.id, by: .you)
        }
        dismiss()
    }
}
