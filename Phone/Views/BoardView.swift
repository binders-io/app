import SwiftUI
import BindersKit

/// Promises, asks and the checklists in meetings and notes. One binder's are grouped by where they came from; all of them
/// are grouped by binder, with where each came from underneath.
struct TodoBoard: View {
    @Environment(MacConnection.self) private var connection
    let binder: String?
    var allowsAdding = false
    @State private var todos: [Todo] = []
    @State private var loaded = false
    /// Nothing from the Mac yet, and no copy from last time.
    @State private var unreached = false
    @State private var newTodo = ""
    @State private var adding = false
    @State private var problem: String?
    @State private var openCard: CardLink?
    @Environment(\.binderTint) private var binderTint

    var body: some View {
        List {
            if allowsAdding {
                Section {
                    HStack {
                        TextField(binder.map { "Add a to-do to \($0)" } ?? "Add a to-do, like “call Sam tomorrow at 3”", text: $newTodo)
                            .submitLabel(.done)
                            .onSubmit(add)
                        if adding { ProgressView() } else if !newTodo.isEmpty {
                            Button("Add", action: add).buttonStyle(.borderless)
                        }
                    }
                }
                .surfaceRows()
            }
            ForEach(groups, id: \.title) { group in
                Section {
                    ForEach(group.items) { todo in
                        TodoRow(todo: todo, caption: binder == nil ? todo.source : nil) { toggle(todo) }
                            .swipeActions(edge: .trailing) {
                                if let card = todo.cardId, !card.isEmpty {
                                    Button { openCard = CardLink(id: card) } label: { Label("Card", systemImage: "rectangle.split.3x1") }
                                        .tint(swipeFill)
                                } else {
                                    Button { putOnBoard(todo) } label: { Label("Board", systemImage: "rectangle.stack.badge.plus") }
                                        .tint(swipeFill)
                                }
                            }
                            .contextMenu {
                                if let card = todo.cardId, !card.isEmpty {
                                    Button("Open Card") { openCard = CardLink(id: card) }
                                } else {
                                    Button("Add to Board") { putOnBoard(todo) }
                                }
                            }
                    }
                } header: {
                    SectionTitle(group.title)
                }
                .surfaceRows()
            }
            if !done.isEmpty {
                Section {
                    ForEach(done.prefix(15)) { todo in
                        TodoRow(todo: todo, caption: binder == nil ? todo.source : nil) { toggle(todo) }
                    }
                } header: {
                    SectionTitle("Done")
                }
                .surfaceRows()
            }
        }
        .listGround()
        .overlay {
            if loaded && open.isEmpty && done.isEmpty {
                EmptyState("Nothing to do", symbol: "checkmark.circle",
                           description: "Promises you make, asks, and the checklists in your meetings and notes show up here.")
            } else if unreached {
                WaitingForMac(what: "Your to-dos show here") { await load() }
            }
        }
        .navigationDestination(item: $openCard) { CardDetailView(id: $0.id) }
        .refreshable { await load() }
        .task(id: connection.revision("todos") + connection.revision("tasks")) { await load() }
        .problemToast($problem)
    }

    /// Behind a swipe action's white words: the brand's indigo, or the binder's colour inside a binder.
    private var swipeFill: Color { binderTint?.fill ?? Palette.accent }

    // MARK: Data

    private var mine: [Todo] { binder.map { name in todos.filter { $0.binder == name } } ?? todos }
    private var open: [Todo] { mine.filter { !$0.isDone } }
    private var done: [Todo] { mine.filter(\.isDone) }

    /// Open to-dos grouped by their source, in the order the Mac lists them (promises with deadlines first).
    private var groups: [(title: String, items: [Todo])] {
        var order: [String] = []
        var byTitle: [String: [Todo]] = [:]
        for todo in open {
            let title = binder == nil ? ((todo.binder ?? "").isEmpty ? "No binder" : todo.binder!) : (todo.source.isEmpty ? "To-dos" : todo.source)
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(todo)
        }
        return order.map { ($0, byTitle[$0] ?? []) }
    }

    private func load() async {
        // Last time's list straight away, while the Mac answers.
        if !loaded, todos.isEmpty, let copy = connection.cached("todos", as: [Todo].self) {
            todos = Self.deduplicated(copy.filter { $0.status != "dismissed" })
            loaded = true
        }
        let result = await connection.fetch("list_todos", ["status": "all"], cache: "todos", as: [Todo].self)
        if let value = result.value {
            todos = Self.deduplicated(value.filter { $0.status != "dismissed" })
            loaded = true
        }
        // Only the Mac, or last time's copy, says there's nothing to do.
        unreached = !loaded
    }

    /// A note's digest often repeats the checklist in the note itself; show each task once.
    static func deduplicated(_ todos: [Todo]) -> [Todo] {
        var seen = Set<String>()
        return todos.filter { todo in
            let key = "\(todo.sourceId ?? todo.source)|\(todo.task.lowercased().filter { $0.isLetter || $0.isNumber })"
            return seen.insert(key).inserted
        }
    }

    private func toggle(_ todo: Todo) {
        guard let index = todos.firstIndex(where: { $0.id == todo.id }) else { return }
        let status = todo.isDone ? "open" : "done"
        todos[index].status = status
        Haptics.shared.tap()
        Task {
            do {
                _ = try await connection.call("set_todo_status", ["id": todo.id, "status": status])
            } catch {
                if let again = todos.firstIndex(where: { $0.id == todo.id }) { todos[again].status = todo.status }
                problem = error.localizedDescription
            }
        }
    }

    /// A card in Ready on the to-do's binder's board. The to-do stays open until the card is done.
    private func putOnBoard(_ todo: Todo) {
        Task {
            do {
                _ = try await connection.call("create_task", ["todo": todo.id, "column": "ready"])
                // A card added: filed, by touch.
                Haptics.shared.success()
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func add() {
        let text = newTodo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            // Out of reach, it waits on this iPhone and goes to the Mac when it's back, as dictated ones do.
            let sent = await connection.save("add_todo", text: text, binder: binder)
            newTodo = ""
            if sent {
                // Added to its binder: filed, by touch.
                Haptics.shared.success()
                await load()
            } else {
                problem = "Kept on this iPhone; it goes to \(MacConnection.brainWords) when it's back."
            }
        }
    }
}

struct TodoRow: View {
    let todo: Todo
    /// Where it came from, when the list isn't already grouped that way.
    var caption: String? = nil
    let toggle: () -> Void
    @Environment(\.binderTint) private var binderTint

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: toggle) {
                // Green is done, and nothing else.
                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.isDone ? Palette.done : Palette.faint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 4) {
                // Said to yourself: your own words, as Binders quotes them, as the Mac's to-dos do.
                Text(todo.task)
                    .font(todo.isSaidToYourself ? Typeface.quote() : nil)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(todo.isDone ? Palette.muted : Palette.ink)
                if let caption, !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if !todo.isDone, todo.isOnBoard {
                        // Words, not something to tap: muted grey on a binder's pages, as the Mac's, the accent's elsewhere.
                        Chip(text: "On board · " + (todo.cardColumn.flatMap(BoardColumn.init(rawValue:))?.title ?? ""), symbol: "rectangle.split.3x1",
                             tint: binderTint == nil ? Palette.accentText : Palette.muted)
                    }
                    if let owner = todo.ownerName { Chip(text: owner, symbol: "person") }
                    if let due = todo.dueDate { Chip(text: due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), symbol: "calendar", urgent: Chip.isDue(due) && !todo.isDone) }
                    else if let said = todo.dueAsSaid, !said.isEmpty { Chip(text: said, symbol: "calendar") }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct Chip: View {
    let text: String
    let symbol: String
    /// Due today or overdue: amber, as it needs you.
    var urgent = false
    var tint: Color = Palette.muted

    /// Due by the end of today, or already past.
    static func isDue(_ date: Date) -> Bool { date < .now || Calendar.current.isDateInToday(date) }

    var body: some View {
        let color = urgent ? Palette.needsYou : tint
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).lineLimit(1)
        }
            .font(.caption.monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
