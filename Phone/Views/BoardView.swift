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
    @State private var newTodo = ""
    @State private var adding = false
    @State private var problem: String?
    @State private var openCard: CardLink?

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
                } footer: {
                    OfflineBanner()
                }
            } else {
                OfflineBanner()
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { todo in
                        TodoRow(todo: todo, caption: binder == nil ? todo.source : nil) { toggle(todo) }
                            .swipeActions(edge: .trailing) {
                                if let card = todo.cardId, !card.isEmpty {
                                    Button { openCard = CardLink(id: card) } label: { Label("Card", systemImage: "rectangle.split.3x1") }
                                        .tint(.accentColor)
                                } else {
                                    Button { putOnBoard(todo) } label: { Label("Board", systemImage: "rectangle.stack.badge.plus") }
                                        .tint(.accentColor)
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
                }
            }
            if !done.isEmpty {
                Section("Done") {
                    ForEach(done.prefix(15)) { todo in
                        TodoRow(todo: todo, caption: binder == nil ? todo.source : nil) { toggle(todo) }
                    }
                }
            }
        }
        .overlay {
            if loaded && open.isEmpty && done.isEmpty {
                ContentUnavailableView("Nothing to do", systemImage: "checkmark.circle",
                                       description: Text("Promises you make, asks, and the checklists in your meetings and notes show up here."))
            }
        }
        .navigationDestination(item: $openCard) { CardDetailView(id: $0.id) }
        .refreshable { await load() }
        .task(id: connection.revision("todos") + connection.revision("tasks")) { await load() }
        .alert("Couldn't update the Mac", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
    }

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
        let result = await connection.fetch("list_todos", ["status": "all"], cache: "todos", as: [Todo].self)
        if let value = result.value { todos = Self.deduplicated(value.filter { $0.status != "dismissed" }) }
        loaded = true
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                _ = try await connection.call("create_task", ["todo": todo.id, "column": "ready"])
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
            do {
                var arguments: [String: Any] = ["text": text]
                if let binder { arguments["binder"] = binder }
                _ = try await connection.call("add_todo", arguments)
                newTodo = ""
                await load()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

struct TodoRow: View {
    let todo: Todo
    /// Where it came from, when the list isn't already grouped that way.
    var caption: String? = nil
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? "Mark as not done" : "Mark as done")
            VStack(alignment: .leading, spacing: 4) {
                Text(todo.task)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(todo.isDone ? .secondary : .primary)
                if let caption, !caption.isEmpty {
                    Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if !todo.isDone, todo.isOnBoard {
                        Chip(text: "On board · " + (todo.cardColumn.flatMap(BoardColumn.init(rawValue:))?.title ?? ""), symbol: "rectangle.split.3x1",
                             tint: .accentColor)
                    }
                    if let owner = todo.ownerName { Chip(text: owner, symbol: "person") }
                    if let due = todo.dueDate { Chip(text: due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), symbol: "calendar", urgent: due < .now && !todo.isDone) }
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
    var urgent = false
    var tint: Color = .secondary

    var body: some View {
        let color = urgent ? Color.red : tint
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text).lineLimit(1)
        }
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
