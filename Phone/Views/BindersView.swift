import SwiftUI

/// Home: the binders, as on the Mac, each holding its to-dos, board, meetings and notes. Above them, the same across every
/// binder; Ask is a button, since it looks across all of it.
struct BindersView: View {
    @Environment(MacConnection.self) private var connection
    @State private var binders: [BinderInfo] = []
    @State private var openTodos: Int?
    @State private var todosByBinder: [String: Int] = [:]
    /// Cards waiting on you: an agent's question, or finished work to check.
    @State private var needsYou = 0
    @State private var path = NavigationPath()
    @State private var asking = UserDefaults.standard.string(forKey: "open") == "ask"
    @State private var dictating = UserDefaults.standard.string(forKey: "open") == "dictate"
    @State private var settingUpKeyboard = UserDefaults.standard.string(forKey: "open") == "keyboard"
    @State private var writing = UserDefaults.standard.string(forKey: "open") == "newnote"

    enum Place: Hashable {
        case allTodos, allTasks, allMeetings, allNotes
        case binder(BinderInfo)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                OfflineBanner()
                KeyboardMicBanner()
                Section("Everything") {
                    NavigationLink(value: Place.allTodos) {
                        HStack {
                            Label("To-dos", systemImage: "checklist")
                            Spacer()
                            if let openTodos, openTodos > 0 { Text("\(openTodos)").foregroundStyle(.secondary) }
                        }
                    }
                    NavigationLink(value: Place.allTasks) {
                        HStack {
                            Label("Board", systemImage: "rectangle.split.3x1")
                            Spacer()
                            if needsYou > 0 { Text("\(needsYou) need you").foregroundStyle(.orange) }
                        }
                    }
                    NavigationLink(value: Place.allMeetings) { Label("Meetings", systemImage: "person.2.wave.2") }
                    NavigationLink(value: Place.allNotes) { Label("Notes", systemImage: "note.text") }
                }
                Section("Binders") {
                    ForEach(binders.filter { !$0.archived }) { binder in
                        NavigationLink(value: Place.binder(binder)) { BinderRow(binder: binder, openTodos: todosByBinder[binder.name] ?? 0) }
                    }
                }
                let archived = binders.filter(\.archived)
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { binder in
                            NavigationLink(value: Place.binder(binder)) { BinderRow(binder: binder, openTodos: todosByBinder[binder.name] ?? 0) }
                        }
                    }
                }
                Section {
                    Button { settingUpKeyboard = true } label: { Label("Dictate in Any App", systemImage: "keyboard") }
                }
            }
            .navigationTitle("Binders")
            .navigationDestination(for: Place.self) { place in
                switch place {
                case .allTodos: TodoBoard(binder: nil, allowsAdding: true).navigationTitle("To-dos")
                case .allTasks: CardBoardView(binder: nil).navigationTitle("Board")
                case .allMeetings: MeetingsList(binder: nil).navigationTitle("Meetings")
                case .allNotes: NotesList(binder: nil).navigationTitle("Notes")
                case .binder(let binder): BinderDetailView(binder: binder)
                }
            }
            .navigationDestination(for: NoteSummary.self) { NoteDetailView(summary: $0) }
            .navigationDestination(for: MeetingSummary.self) { MeetingDetailView(summary: $0) }
            .navigationDestination(for: CardLink.self) { CardDetailView(id: $0.id) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { asking = true } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel("Ask")
                }
                ToolbarItem(placement: .topBarTrailing) { MacStatusButton() }
            }
            .sheet(isPresented: $asking) { AskView() }
            .safeAreaInset(edge: .bottom) { DictateButton { dictating = true } }
            .sheet(isPresented: $dictating) { DictationSheet() }
            .sheet(isPresented: $settingUpKeyboard) { KeyboardSetupView() }
            .sheet(isPresented: $writing) { NewNoteSheet() }
            .refreshable { await load() }
            .task(id: connection.revision("binders") + connection.revision("notes") + connection.revision("meetings") + connection.revision("todos")
                  + connection.revision("tasks")) {
                await load()
            }
        }
    }

    private func load() async {
        let result = await connection.fetch("list_binders", cache: "binders", as: [BinderInfo].self)
        if let value = result.value { binders = value }
        if let todos = await connection.fetch("list_todos", ["status": "open"], cache: "todos-open", as: [Todo].self).value {
            let open = TodoBoard.deduplicated(todos)
            openTodos = open.count
            todosByBinder = Dictionary(grouping: open.compactMap(\.binder), by: { $0 }).mapValues(\.count)
        }
        if let cards = await connection.fetch("list_tasks", cache: "tasks-all", as: [Card].self).value {
            needsYou = cards.filter { $0.board == .blocked || $0.board == .review }.count
        }
        openForDevelopment()
    }

    /// For development, as the Simulator can't be tapped from a script: `-open todos|meetings|notes` shows that list, and
    /// `-openFirst YES` opens the binder with the most in it. (`dictate`, `keyboard` and `newnote` open those sheets.)
    private func openForDevelopment() {
        guard path.isEmpty else { return }
        switch UserDefaults.standard.string(forKey: "open") {
        case "todos": path.append(Place.allTodos)
        case "board": path.append(Place.allTasks)
        case "meetings": path.append(Place.allMeetings)
        case "notes": path.append(Place.allNotes)
        default:
            if UserDefaults.standard.bool(forKey: "openFirst"),
               let fullest = binders.filter({ !$0.archived }).max(by: { $0.meetings + $0.notes < $1.meetings + $1.notes }) {
                path.append(Place.binder(fullest))
            }
        }
    }
}

struct BinderRow: View {
    let binder: BinderInfo
    var openTodos = 0

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(BinderPalette.color(binder.color ?? 0))
                .frame(width: 8, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(binder.name).font(.headline)
                    if binder.shared { Image(systemName: "person.2").font(.caption).foregroundStyle(.secondary) }
                }
                Text((openTodos > 0 ? (openTodos == 1 ? "1 to-do · " : "\(openTodos) to-dos · ") : "") + binder.counts)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One binder: its to-dos, board, meetings and notes, a tap apart. New to-dos, cards and notes go into it.
struct BinderDetailView: View {
    @Environment(MacConnection.self) private var connection
    let binder: BinderInfo
    @State private var section: Section
    @State private var writing = false
    @State private var dictating = false

    enum Section: String, CaseIterable {
        case todos = "To-dos", board = "Board", meetings = "Meetings", notes = "Notes"
    }

    init(binder: BinderInfo) {
        self.binder = binder
        let asked = UserDefaults.standard.string(forKey: "section").flatMap { Section(rawValue: $0) }
        _section = State(initialValue: asked ?? .todos)
    }

    var body: some View {
        Group {
            switch section {
            case .todos: TodoBoard(binder: binder.name, allowsAdding: true)
            case .board: CardBoardView(binder: binder.name)
            case .meetings: MeetingsList(binder: binder.name)
            case .notes: NotesList(binder: binder.name)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("Show", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 6)
            .background(.bar)
        }
        .navigationTitle(binder.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { writing = true } label: { Image(systemName: "square.and.pencil") }
                    .disabled(!connection.isConnected)
                    .accessibilityLabel("New note in \(binder.name)")
            }
        }
        .sheet(isPresented: $writing) { NewNoteSheet(binder: binder.name) }
        .safeAreaInset(edge: .bottom) { DictateButton { dictating = true } }
        .sheet(isPresented: $dictating) { DictationSheet(binder: binder.name) }
    }
}

/// The same eight colors binders have on the Mac.
enum BinderPalette {
    static let colors: [Color] = [
        .accentColor,
        Color(red: 0.16, green: 0.62, blue: 0.62),
        Color(red: 0.93, green: 0.52, blue: 0.20),
        Color(red: 0.90, green: 0.36, blue: 0.58),
        Color(red: 0.30, green: 0.66, blue: 0.36),
        Color(red: 0.26, green: 0.60, blue: 0.90),
        Color(red: 0.85, green: 0.68, blue: 0.20),
        Color(red: 0.50, green: 0.54, blue: 0.62),
    ]

    static func color(_ index: Int) -> Color { colors[abs(index) % colors.count] }
}

/// The way into dictation, at the bottom of the screen where a thumb is.
struct DictateButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Dictate", systemImage: "mic.fill")
                .font(.headline)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.accentColor))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .padding(.bottom, 8)
        .accessibilityHint("Say a note or a to-do")
    }
}
