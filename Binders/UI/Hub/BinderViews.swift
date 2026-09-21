import SwiftData
import SwiftUI
import BindersKit

/// Colours a binder can wear on its spine.
enum BinderPalette {
    static let colors: [Color] = [
        BindersTheme.accent,
        Color(red: 0.16, green: 0.62, blue: 0.62),
        Color(red: 0.93, green: 0.52, blue: 0.20),
        Color(red: 0.90, green: 0.36, blue: 0.58),
        Color(red: 0.30, green: 0.66, blue: 0.36),
        Color(red: 0.26, green: 0.60, blue: 0.90),
        Color(red: 0.85, green: 0.68, blue: 0.20),
        Color(red: 0.50, green: 0.54, blue: 0.62),
    ]
    static let names = ["Indigo", "Teal", "Orange", "Pink", "Green", "Sky", "Amber", "Slate"]

    static func color(_ index: Int) -> Color { colors[abs(index) % colors.count] }
}

enum BinderTab: String, CaseIterable {
    case overview = "Overview", meetings = "Meetings", notes = "Notes", knowledge = "Knowledge"
}

/// One binder: what's in it, what's still open in it, and whether the team sees it.
struct BinderPage: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(TeamSyncService.self) private var team
    @Environment(AppSettings.self) private var settings
    @Query private var binders: [BinderRecord]
    let binderID: UUID?
    @State private var tab: BinderTab = .overview
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool

    private var binder: BinderRecord? {
        binders.first { $0.id == binderID } ?? binders.first(where: \.isDefault)
    }

    var body: some View {
        if let binder {
            content(binder)
        } else {
            ContentUnavailableView("No binder yet", systemImage: "books.vertical")
        }
    }

    private func content(_ binder: BinderRecord) -> some View {
        @Bindable var binder = binder
        let counts = Store.shared.counts(in: binder.id)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    Menu {
                        ForEach(0..<BinderPalette.colors.count, id: \.self) { index in
                            Button {
                                binder.colorIndex = index
                                binder.updatedAt = Date()
                            } label: {
                                Label(BinderPalette.names[index], systemImage: index == binder.colorIndex ? "checkmark.circle.fill" : "circle.fill")
                            }
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(BinderPalette.color(binder.colorIndex))
                            .frame(width: 26, height: 26)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(binder.isTeamCopy)
                    .help("Colour")
                    if binder.isTeamCopy {
                        Text(binder.name).font(BindersTheme.title())
                    } else {
                        TextField("Binder name", text: $binder.name)
                            .textFieldStyle(.plain)
                            .font(BindersTheme.title())
                            .focused($nameFocused)
                            .onSubmit {
                                binder.updatedAt = Date()
                                nameFocused = false
                            }
                            .help("Click to rename")
                    }
                    Spacer()
                    if binder.isTeamCopy {
                        Label("Shared by \(binder.teamAuthorName ?? "a teammate") · read-only", systemImage: "person.2")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if team.isConfigured {
                        Toggle("Share with team", isOn: Binding(get: { binder.sharedWithTeam }, set: { team.setShared(binder, $0) }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help("Everything in this binder syncs to the team, including what you add later. Audio never leaves this Mac.")
                    }
                    Menu {
                        if !binder.isTeamCopy {
                            Button("Rename…") { nameFocused = true }
                            Button(binder.archived ? "Unarchive" : "Archive") {
                                binder.archived.toggle()
                                binder.updatedAt = Date()
                            }
                            .disabled(binder.isDefault)
                            Divider()
                            Button("Delete Binder…", role: .destructive) { confirmDelete = true }
                                .disabled(binder.isDefault)
                        } else {
                            Button("Shared binders can only be removed by their owner") {}.disabled(true)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                Text(subtitle(binder, counts: counts)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
            Picker("", selection: $tab) {
                ForEach(BinderTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            Divider()
            Group {
                switch tab {
                case .overview:
                    BinderOverview(binder: binder, openMeeting: { id in
                        navigation.pendingMeetingID = id
                        tab = .meetings
                    }, openNote: { id in
                        navigation.pendingNoteID = id
                        tab = .notes
                    })
                case .meetings: MeetingsView(binderID: binder.id)
                case .notes: NotesView(binderID: binder.id)
                case .knowledge: KnowledgeView(binderID: binder.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            settings.currentBinderID = binder.id
            consumePendingTab()
        }
        .onChange(of: navigation.pendingBinderTab) { consumePendingTab() }
        .confirmationDialog("Delete “\(binder.name)”?", isPresented: $confirmDelete) {
            Button("Delete Binder", role: .destructive) {
                let general = Store.shared.defaultBinder()
                Store.shared.deleteBinder(binder, movingItemsTo: general)
                navigation.binderID = general.id
                team.scheduleSync(after: 0.5)
            }
        } message: {
            Text("Its \(counts.meetings) meetings and \(counts.notes) notes move to General. If it was shared, they leave the team space.")
        }
    }

    private func subtitle(_ binder: BinderRecord, counts: (meetings: Int, notes: Int)) -> String {
        var parts = ["\(counts.meetings) \(counts.meetings == 1 ? "meeting" : "meetings")", "\(counts.notes) \(counts.notes == 1 ? "note" : "notes")"]
        if binder.isDefault { parts.append("where new things go unless another binder is open") }
        if binder.archived { parts.append("archived") }
        return parts.joined(separator: " · ")
    }

    private func consumePendingTab() {
        guard let pending = navigation.pendingBinderTab else { return }
        tab = pending
        navigation.pendingBinderTab = nil
    }
}

/// The binder at a glance: counts, every open to-do from its meetings and notes, recent items, and who comes up in it.
struct BinderOverview: View {
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(CommitmentService.self) private var commitmentService
    @Environment(HubNavigation.self) private var navigation
    @Query private var commitments: [CommitmentRecord]
    let binder: BinderRecord
    let openMeeting: (UUID) -> Void
    let openNote: (UUID) -> Void
    @Query private var meetings: [MeetingRecord]
    @Query private var notes: [NoteItem]
    @State private var people: [KnowledgeEntity] = []

    init(binder: BinderRecord, openMeeting: @escaping (UUID) -> Void, openNote: @escaping (UUID) -> Void) {
        self.binder = binder
        self.openMeeting = openMeeting
        self.openNote = openNote
        let id = binder.id
        _meetings = Query(filter: #Predicate<MeetingRecord> { $0.binderID == id }, sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
        _notes = Query(filter: #Predicate<NoteItem> { $0.binderID == id }, sort: [SortDescriptor(\NoteItem.updatedAt, order: .reverse)])
        _commitments = Query(filter: #Predicate<CommitmentRecord> { $0.binderID == id }, sort: [SortDescriptor(\CommitmentRecord.createdAt, order: .reverse)])
    }

    private var tasks: [TaskEntry] {
        TaskCollector.collect(meetings: Array(meetings.prefix(60)), notes: Array(notes.prefix(120)), commitments: Array(commitments.prefix(100)),
                              openMeeting: { openMeeting($0.id) }, openNote: { openNote($0.id) },
                              commitmentActions: CommitmentActions(toggle: { commitmentService.toggle($0) },
                                                                   dismiss: { commitmentService.setStatus($0, "dismissed") },
                                                                   open: { record in
                                                                       navigation.pendingWritingSearch = record.quote ?? record.task
                                                                       navigation.selection = .writing
                                                                   }))
    }

    var body: some View {
        let tasks = tasks
        let open = tasks.filter { !$0.done }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    StatCard(title: "Meetings", value: "\(meetings.count)", symbol: "person.2.wave.2")
                    StatCard(title: "Notes", value: "\(notes.count)", symbol: "note.text")
                    StatCard(title: "Open to-dos", value: "\(open)", symbol: "checklist")
                    StatCard(title: "People & topics", value: "\(people.count)", symbol: "point.3.connected.trianglepath.dotted")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("To-dos").font(BindersTheme.columnTitle)
                        Spacer()
                        Text(open == 0 ? "nothing open" : "\(open) open").font(.callout).foregroundStyle(.secondary)
                    }
                    TaskBoard(tasks: tasks)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperCard(padding: 16)

                HStack(alignment: .top, spacing: 16) {
                    recentList(title: "Recent meetings", empty: "No meetings yet.", items: meetings.prefix(6).map { meeting in
                        (meeting.id, meeting.title, meeting.createdAt.formatted(date: .abbreviated, time: .shortened) + " · \(max(1, Int((meeting.duration / 60).rounded()))) min", { openMeeting(meeting.id) })
                    })
                    recentList(title: "Recent notes", empty: "No notes yet.", items: notes.prefix(6).map { note in
                        (note.id, note.title, note.updatedAt.formatted(.relative(presentation: .named)), { openNote(note.id) })
                    })
                }

                if !people.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Comes up in this binder").font(BindersTheme.columnTitle)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(people) { entity in
                                HStack(spacing: 5) {
                                    Circle().fill(EntityStyle.color(entity.type)).frame(width: 6, height: 6)
                                    Text(entity.name).lineLimit(1)
                                    Text("\(entity.documents)").foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .task(id: "\(binder.id)|\(knowledge.revision)") {
            people = await knowledge.store.entities(limit: 18, binder: binder.id.uuidString)
        }
    }

    private func recentList(title: String, empty: String, items: [(UUID, String, String, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BindersTheme.columnTitle)
            if items.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(items, id: \.0) { item in
                Button(action: item.3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1).lineLimit(1)
                        Text(item.2).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard(padding: 16)
    }
}

/// "Move to ▸" entries for every binder of yours; use inside a Menu.
struct MoveToBinderItems: View {
    let current: UUID?
    let move: (BinderRecord) -> Void
    @Query private var binders: [BinderRecord]

    var body: some View {
        let options = binders.filter { !$0.isTeamCopy && !$0.archived }.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        ForEach(options) { binder in
            Button {
                move(binder)
            } label: {
                if binder.id == current {
                    Label(binder.name, systemImage: "checkmark")
                } else {
                    Text(binder.name + (binder.sharedWithTeam ? "  (shared)" : ""))
                }
            }
            .disabled(binder.id == current)
        }
    }
}
