import BindersKit
import SwiftUI

/// Home: the binders, as on the Mac, each holding its to-dos, board, meetings and notes. Above them, the same across every
/// binder; Ask is a button, since it looks across all of it.
struct BindersView: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.talkControlShown) private var talkControlShown
    /// Opens what a tapped notification is about. In the tabs, Today does that.
    var handlesNotifications = true

    init(handlesNotifications: Bool = true) {
        self.handlesNotifications = handlesNotifications
    }
    @State private var binders: [BinderInfo] = []
    @State private var openTodos: Int?
    @State private var todosByBinder: [String: Int] = [:]
    /// Every open card, for what waits on you.
    @State private var cards: [Card] = []
    @State private var store = CaptureStore.shared
    @State private var suggestions = SuggestionCenter.shared
    @State private var moments = MomentCenter.shared
    @State private var path = NavigationPath()
    @State private var asking = UserDefaults.standard.string(forKey: "open") == "ask"
    @State private var dictating = UserDefaults.standard.string(forKey: "open") == "dictate"
    @State private var settingUpKeyboard = UserDefaults.standard.string(forKey: "open") == "keyboard"
    @State private var writing = UserDefaults.standard.string(forKey: "open") == "newnote"
    /// When this first showed: what joins Needs you after drops in.
    @State private var opened: Date? = nil

    enum Place: Hashable {
        case allTodos, allTasks, allMeetings, allNotes, capture, happening, agents
        case binder(BinderInfo)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                KeyboardMicBanner().surfaceRows()
                NeedsYouSection(cards: cards, captures: store.conversations, offers: suggestions.suggestions, moments: moments.moments,
                                since: opened) { destination in
                    switch destination {
                    case .card(let id): path.append(CardLink(id: id))
                    case .board: path.append(Place.allTasks)
                    case .capture: path.append(Place.capture)
                    case .conversation(let id):
                        path.append(Place.capture)
                        path.append(CapturedConversationLink(id: id))
                    case .moment(let id): path.append(MomentLink.moment(id))
                    case .moments: path.append(MomentLink.waiting)
                    }
                }
                Section("Everything") {
                    NavigationLink(value: Place.allTodos) {
                        HStack {
                            Label("To-dos", systemImage: "checklist")
                            Spacer()
                            if let openTodos, openTodos > 0 {
                                Text("\(openTodos)").font(Typeface.count(.body)).foregroundStyle(Palette.muted).rollingCount(openTodos)
                            }
                        }
                    }
                    NavigationLink(value: Place.allTasks) {
                        Label("Board", systemImage: "rectangle.split.3x1")
                    }
                    NavigationLink(value: Place.happening) { Label("What's happening", systemImage: "waveform.path.ecg") }
                    NavigationLink(value: Place.agents) { Label("Agents", systemImage: "sparkles") }
                    NavigationLink(value: Place.allMeetings) { Label("Meetings", systemImage: "person.2.wave.2") }
                    NavigationLink(value: Place.allNotes) { Label("Notes", systemImage: "note.text") }
                }
                .surfaceRows()
                Section("Binders") {
                    ForEach(binders.filter { !$0.archived }) { binder in
                        NavigationLink(value: Place.binder(binder)) { BinderRow(binder: binder, openTodos: todosByBinder[binder.name] ?? 0) }
                    }
                }
                .surfaceRows()
                let archived = binders.filter(\.archived)
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { binder in
                            NavigationLink(value: Place.binder(binder)) { BinderRow(binder: binder, openTodos: todosByBinder[binder.name] ?? 0) }
                        }
                    }
                    .surfaceRows()
                }
                Section {
                    NavigationLink(value: Place.capture) { CaptureStatusLabel() }
                        .accessibilityIdentifier("captureRow")
                    Button { settingUpKeyboard = true } label: { Label("Dictate in Any App", systemImage: "keyboard") }
                }
                .surfaceRows()
            }
            .listGround()
            .onAppear { if opened == nil { opened = .now } }
            .navigationTitle("Binders")
            .navigationDestination(for: Place.self) { place in
                switch place {
                case .allTodos: TodoBoard(binder: nil, allowsAdding: true).navigationTitle("To-dos")
                case .allTasks: CardBoardView(binder: nil).navigationTitle("Board")
                case .allMeetings: MeetingsList(binder: nil).navigationTitle("Meetings")
                case .allNotes: NotesList(binder: nil).navigationTitle("Notes")
                case .capture: CaptureView()
                case .happening: WorkStreamsView { path.append(Place.allTasks) }
                case .agents: AgentsList()
                case .binder(let binder): BinderDetailView(binder: binder)
                }
            }
            .navigationDestination(for: NoteSummary.self) { NoteDetailView(summary: $0) }
            .navigationDestination(for: MeetingSummary.self) { MeetingDetailView(summary: $0) }
            .navigationDestination(for: CardLink.self) { CardDetailView(id: $0.id) }
            // A moment's notification, opened: what it made, or its own page.
            .opensMoments(path: $path, enabled: handlesNotifications)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Ask is your Mac's model reading your binders, not an agent's work: not the sparkle.
                    Button { asking = true } label: { Image(systemName: "text.magnifyingglass") }
                        .accessibilityLabel("Ask")
                }
                ToolbarItem(placement: .topBarTrailing) { MacButton() }
            }
            .sheet(isPresented: $asking) { AskView() }
            .safeAreaInset(edge: .bottom) { if !talkControlShown { DictateButton { dictating = true } } }
            .sheet(isPresented: $dictating) { DictationSheet() }
            .sheet(isPresented: $settingUpKeyboard) { KeyboardSetupView() }
            .sheet(isPresented: $writing) { NewNoteSheet() }
            .refreshable { await load() }
            // A suggestion's notification, tapped: its conversation.
            .onChange(of: PhoneNavigation.shared.pendingConversation, initial: true) { _, id in
                guard handlesNotifications, let id else { return }
                PhoneNavigation.shared.pendingConversation = nil
                path = NavigationPath()
                path.append(Place.capture)
                path.append(CapturedConversationLink(id: id))
            }
            // A moment's notification, tapped: the capture screen, where it's listed.
            .onChange(of: PhoneNavigation.shared.pendingCapture, initial: true) { _, open in
                guard handlesNotifications, open else { return }
                PhoneNavigation.shared.pendingCapture = false
                path = NavigationPath()
                path.append(Place.capture)
            }
            // An agent's question, tapped: its card.
            // Its widget, tapped: back to the top, where what needs you is.
            .onChange(of: PhoneNavigation.shared.pendingNeedsYou, initial: true) { _, open in
                guard handlesNotifications, open else { return }
                PhoneNavigation.shared.pendingNeedsYou = false
                path = NavigationPath()
            }
            .onChange(of: PhoneNavigation.shared.pendingCard, initial: true) { _, id in
                guard handlesNotifications, let id else { return }
                PhoneNavigation.shared.pendingCard = nil
                path = NavigationPath()
                path.append(CardLink(id: id))
            }
            .task(id: connection.revision("binders") + connection.revision("notes") + connection.revision("meetings") + connection.revision("todos")
                  + connection.revision("tasks")) {
                await load()
            }
        }
    }

    private func load() async {
        // What it showed last time, straight away; then the Mac's answers, asked for together.
        if binders.isEmpty, let copy = connection.cached("binders", as: [BinderInfo].self) {
            binders = copy
            if let todos = connection.cached("todos-open", as: [Todo].self) { count(todos) }
            if let cards = connection.cached("tasks-all", as: [Card].self) { count(cards) }
        }
        async let binderList = connection.fetch("list_binders", cache: "binders", as: [BinderInfo].self)
        async let todoList = connection.fetch("list_todos", ["status": "open"], cache: "todos-open", as: [Todo].self)
        async let cardList = connection.fetch("list_tasks", cache: "tasks-all", as: [Card].self)
        if let value = await binderList.value {
            binders = value
            // A card, note or meeting opened from anywhere knows its binder's colour.
            BinderColors.remember(value)
        }
        if let todos = await todoList.value { count(todos) }
        if let cards = await cardList.value { count(cards) }
        openForDevelopment()
    }

    private func count(_ todos: [Todo]) {
        let open = TodoBoard.deduplicated(todos)
        openTodos = open.count
        todosByBinder = Dictionary(grouping: open.compactMap(\.binder), by: { $0 }).mapValues(\.count)
    }

    private func count(_ cards: [Card]) {
        self.cards = cards
        CaptureActivity.update()
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
        case "capture": path.append(Place.capture)
        case "agents": path.append(Place.agents)
        case "manager":
            path.append(Place.agents)
            path.append(AgentsPlace.manager)
        case "agent":
            path.append(Place.agents)
            if let name = UserDefaults.standard.string(forKey: "agent") { path.append(AgentsPlace.agent(name)) }
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
                    Text(binder.name).font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
                    if binder.shared { Image(systemName: "person.2").font(.caption).foregroundStyle(Palette.muted) }
                }
                let counts = (openTodos > 0 ? (openTodos == 1 ? "1 to-do · " : "\(openTodos) to-dos · ") : "") + binder.counts
                Text(counts).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted).rollingCount(counts)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One binder: its to-dos, board, meetings and notes, a tap apart. New to-dos, cards and notes go into it.
struct BinderDetailView: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.talkControlShown) private var talkControlShown
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
            case .notes: NotesList(binder: binder.name, binderInfo: binder)
            }
        }
        // The binder's sections float at the top while its lists scroll under them.
        .modifier(TopBar(bar: Picker("Show", selection: $section) {
            ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 6)))
        .navigationTitle(binder.name)
        // Into one of its folders, on a Mac that has them.
        .navigationDestination(for: FolderLink.self) { FolderNotesView(link: $0) }
        // So the tabs' Dictate files into this binder, as its own button does.
        .onAppear {
            PhoneNavigation.shared.binderInView = binder.name
            PhoneNavigation.shared.folderInView = nil
        }
        .onDisappear { if PhoneNavigation.shared.binderInView == binder.name { PhoneNavigation.shared.binderInView = nil } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { writing = true } label: { Image(systemName: "square.and.pencil") }
                    .disabled(!connection.isConnected)
                    .accessibilityLabel("New note in \(binder.name)")
            }
        }
        .sheet(isPresented: $writing) { NewNoteSheet(binder: binder.name) }
        .safeAreaInset(edge: .bottom) { if !talkControlShown { DictateButton { dictating = true } } }
        .sheet(isPresented: $dictating) { DictationSheet(binder: binder.name) }
        // What you tap inside the binder wears its colour, in its sheets too, over a faint wash of it.
        .binderTint(BinderTint.binder(binder.color ?? 0))
    }
}

/// A bar that floats at the top of a screen as its content scrolls under: with the scroll edge effect from iOS 26, on
/// the bar material before.
private struct TopBar<Bar: View>: ViewModifier {
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .top) { bar }
        } else {
            content.safeAreaInset(edge: .top) { bar.background(.bar) }
        }
    }
}

/// The way into dictation, at the bottom of the screen where a thumb is: it floats over the list, so it's tinted glass
/// from iOS 26, filled with the brand's indigo (or the binder's colour) before.
struct DictateButton: View {
    @Environment(\.binderTint) private var binder
    let action: () -> Void

    var body: some View {
        let fill = binder?.fill ?? Palette.accent
        Group {
            if #available(iOS 26.0, *) {
                Button(action: action) {
                    Label("Dictate", systemImage: "mic.fill")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .tint(fill)
            } else {
                Button(action: action) {
                    Label("Dictate", systemImage: "mic.fill")
                        .font(.headline)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(fill))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                }
            }
        }
        .padding(.bottom, 8)
        .accessibilityHint("Say a note or a to-do")
    }
}
