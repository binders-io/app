import SwiftUI

/// The to-do board on its own tab: everything, with a field to add to-dos.
struct BoardView: View {
    var body: some View {
        NavigationStack {
            TodoBoard(binder: nil, allowsAdding: true)
                .navigationTitle("To-dos")
                .macToolbar()
        }
    }
}

/// Promises, asks and the checklists in meetings and notes, grouped by where they came from; all of them, or one binder's.
struct TodoBoard: View {
    @Environment(MacConnection.self) private var connection
    let binder: String?
    var allowsAdding = false
    @State private var todos: [Todo] = []
    @State private var loaded = false
    @State private var newTodo = ""
    @State private var adding = false
    @State private var problem: String?

    var body: some View {
        List {
            if allowsAdding {
                Section {
                    HStack {
                        TextField("Add a to-do, like “call Sam tomorrow at 3”", text: $newTodo)
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
                        TodoRow(todo: todo) { toggle(todo) }
                    }
                }
            }
            if !done.isEmpty {
                Section("Done") {
                    ForEach(done.prefix(15)) { todo in
                        TodoRow(todo: todo) { toggle(todo) }
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
        .refreshable { await load() }
        .task(id: connection.revision("todos")) { await load() }
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
            let title = todo.source.isEmpty ? "To-dos" : todo.source
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

    private func add() {
        let text = newTodo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                _ = try await connection.call("add_todo", ["text": text])
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
                HStack(spacing: 8) {
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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
            .font(.caption)
            .foregroundStyle(urgent ? Color.red : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill((urgent ? Color.red : Color.secondary).opacity(0.12)))
    }
}
