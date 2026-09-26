import SwiftUI

/// The binders, as on the Mac: one per project or area, each holding its meetings, notes and to-dos.
struct BindersView: View {
    @Environment(MacConnection.self) private var connection
    @State private var binders: [BinderInfo] = []
    @State private var path = NavigationPath()

    enum Place: Hashable {
        case allMeetings, allNotes
        case binder(BinderInfo)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                OfflineBanner()
                Section {
                    NavigationLink(value: Place.allMeetings) { Label("All meetings", systemImage: "person.2.wave.2") }
                    NavigationLink(value: Place.allNotes) { Label("All notes", systemImage: "note.text") }
                }
                Section("Binders") {
                    ForEach(binders.filter { !$0.archived }) { binder in
                        NavigationLink(value: Place.binder(binder)) { BinderRow(binder: binder) }
                    }
                }
                let archived = binders.filter(\.archived)
                if !archived.isEmpty {
                    Section("Archived") {
                        ForEach(archived) { binder in
                            NavigationLink(value: Place.binder(binder)) { BinderRow(binder: binder) }
                        }
                    }
                }
            }
            .navigationTitle("Binders")
            .navigationDestination(for: Place.self) { place in
                switch place {
                case .allMeetings: MeetingsList(binder: nil).navigationTitle("All meetings")
                case .allNotes: NotesList(binder: nil).navigationTitle("All notes")
                case .binder(let binder): BinderDetailView(binder: binder)
                }
            }
            .navigationDestination(for: NoteSummary.self) { NoteDetailView(summary: $0) }
            .navigationDestination(for: MeetingSummary.self) { MeetingDetailView(summary: $0) }
            .macToolbar()
            .refreshable { await load() }
            .task(id: connection.revision("binders") + connection.revision("notes") + connection.revision("meetings")) { await load() }
        }
    }

    private func load() async {
        let result = await connection.fetch("list_binders", cache: "binders", as: [BinderInfo].self)
        if let value = result.value { binders = value }
        // For development: `-openFirst YES` opens the first binder, as the Simulator can't be tapped from a script.
        if UserDefaults.standard.bool(forKey: "openFirst"), path.isEmpty, let fullest = binders.filter({ !$0.archived }).max(by: { $0.meetings + $0.notes < $1.meetings + $1.notes }) {
            path.append(Place.binder(fullest))
        }
    }
}

struct BinderRow: View {
    let binder: BinderInfo

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
                Text(binder.counts).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One binder: its meetings, notes and to-dos, a tap apart.
struct BinderDetailView: View {
    @Environment(MacConnection.self) private var connection
    let binder: BinderInfo
    @State private var section: Section
    @State private var writing = false

    enum Section: String, CaseIterable {
        case meetings = "Meetings", notes = "Notes", todos = "To-dos"
    }

    init(binder: BinderInfo) {
        self.binder = binder
        let asked = UserDefaults.standard.string(forKey: "section").flatMap { Section(rawValue: $0) }
        _section = State(initialValue: asked ?? (binder.meetings > 0 ? .meetings : .notes))
    }

    var body: some View {
        Group {
            switch section {
            case .meetings: MeetingsList(binder: binder.name)
            case .notes: NotesList(binder: binder.name)
            case .todos: TodoBoard(binder: binder.name)
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
