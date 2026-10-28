import SwiftData
import SwiftUI
import BindersKit

enum BinderTab: String, CaseIterable {
    case overview = "Overview", board = "Board", meetings = "Meetings", conversations = "Captures", notes = "Notes", knowledge = "Knowledge", assistant = "Assistant"
}

extension BinderTab {
    /// The tab a meeting or a conversation is listed on.
    static func listing(_ record: MeetingRecord) -> BinderTab { record.isConversation ? .conversations : .meetings }
}

extension MeetingRecord {
    /// Its symbol wherever meetings and conversations are listed together.
    var symbol: String { isConversation ? "bubble.left.and.bubble.right" : "person.2.wave.2" }
}

/// One binder: what's in it, what's still open in it, and whether the team sees it. Its colour marks its name, and on
/// its pages it takes the accent's place on what you act on, over a ground with a trace of it.
struct BinderPage: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(TeamSyncService.self) private var team
    @Environment(AppSettings.self) private var settings
    @Query private var binders: [BinderRecord]
    let binderID: UUID?
    @State private var tab: BinderTab = .overview
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    /// The name is text until you click it or choose Rename…: a field there would take the focus whenever the page
    /// opens, and what you meant for a new note would rename the binder.
    @State private var renaming = false
    /// The name as it was before renaming, for the links to it.
    @State private var nameBefore = ""
    /// What goes here is text until you click it, choose its button with the keyboard, or choose What Goes Here… in the
    /// menu, as the name is.
    @State private var describing = false
    /// Tidy into Folders, open.
    @State private var tidying = false
    /// What Tidy just did, said for a few seconds with Undo.
    @State private var tidied: String?
    @Environment(\.undoManager) private var undoManager

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

    /// The folder the page is in, when it's one of this binder's; nil at the top.
    private func folder(in binder: BinderRecord) -> UUID? {
        Store.shared.shownFolder(navigation.folderID, in: binder.id)
    }

    private func content(_ binder: BinderRecord) -> some View {
        @Bindable var binder = binder
        let counts = Store.shared.counts(in: binder.id)
        let folderID = folder(in: binder)
        let conversations = Store.shared.conversationCount(in: binder.id, includingTrivial: true)
        // Only binders the iPhone's conversations have gone into get their tab.
        let tabs = BinderTab.allCases.filter { $0 != .conversations || conversations > 0 || tab == .conversations }
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
                    // A borderless menu draws no shape label (only symbols): the button style draws the square itself.
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(binder.isTeamCopy)
                    .help("Colour")
                    if binder.isTeamCopy {
                        Text(binder.name).font(BindersTheme.title())
                    } else if renaming {
                        TextField("Binder name", text: $binder.name)
                            .textFieldStyle(.plain)
                            .font(BindersTheme.title())
                            .focused($nameFocused)
                            .onSubmit { nameFocused = false }
                            .onAppear {
                                nameBefore = binder.name
                                DispatchQueue.main.async { nameFocused = true }
                            }
                            .onChange(of: nameFocused) { _, focused in
                                guard !focused else { return }
                                binder.updatedAt = Date()
                                renaming = false
                                LinkTargets.renameLinks(from: nameBefore, to: binder.name)
                            }
                    } else {
                        Text(binder.name)
                            .font(BindersTheme.title())
                            .contentShape(Rectangle())
                            .onTapGesture { renaming = true }
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
                            .help("Its notes and meetings sync to the team, including ones you add later, with the files attached to those notes. Captures, notes from what you said to yourself, to-dos, cards and the audio Binders records stay on this Mac.")
                    }
                    Menu {
                        Button(folderID == nil ? "New Folder…" : "New Folder Here…") { FolderPrompts.shared.create(in: binder.id, parent: folderID) }
                        if !binder.isTeamCopy {
                            Button("Tidy into Folders…") {
                                guard Store.shared.allowsSave() else { return }
                                tidying = true
                            }
                            .help("Make a folder for each prefix your titles share, such as “DevOps | …”, and take it off the titles")
                        }
                        Divider()
                        if !binder.isTeamCopy {
                            Button("Rename…") { renaming = true }
                            if !binder.isDefault {
                                Button("What Goes Here…") { describing = true }
                            }
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
                // What goes in it, for sorting new cards: not for General, which is never offered, nor a teammate's copy.
                if !binder.isDefault, !binder.isTeamCopy {
                    WhatGoesHereField(binder: binder, editing: $describing)
                }
                // Inside a folder: where you are, a path to click back up.
                if folderID != nil {
                    FolderPathBar(binder: binder, folderID: folderID) { navigation.folderID = $0 }
                        .padding(.top, 2)
                }
                if let tidied {
                    HStack(spacing: 8) {
                        Label(tidied, systemImage: "folder").font(.callout).foregroundStyle(.secondary)
                        Button("Undo") {
                            undoManager?.undo()
                            self.tidied = nil
                        }
                        .controlSize(.small)
                        .help("Put the titles, links and notes back as they were (⌘Z)")
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 12)
            Picker("", selection: $tab) {
                ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: tabs.count > 6 ? 740 : tabs.count > 5 ? 640 : 520)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            Divider()
            Group {
                switch tab {
                case .overview:
                    BinderOverview(binder: binder, openMeeting: { id in
                        navigation.pendingMeetingID = id
                        tab = Store.shared.isConversation(id) ? .conversations : .meetings
                    }, openNote: { id in
                        navigation.pendingNoteID = id
                        tab = .notes
                    })
                case .board: BoardView(binder: binder)
                case .meetings: MeetingsView(binderID: binder.id, folderID: folderID)
                case .conversations: MeetingsView(binderID: binder.id, conversations: true, folderID: folderID).id("conversations-\(binder.id)")
                case .notes: NotesView(binderID: binder.id, folderID: folderID)
                case .knowledge: KnowledgeView(binderID: binder.id, folderID: folderID)
                case .assistant: AssistantView(binder: binder).id("assistant-\(binder.id)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .pageGround()
        .binderTint(binder.colorIndex)
        .onAppear {
            settings.currentBinderID = binder.id
            consumePendingTab()
            consumePendingTidy()
        }
        .onChange(of: navigation.pendingBinderTab) { consumePendingTab() }
        .onChange(of: navigation.pendingTidy) { consumePendingTidy() }
        // Into a folder from the sidebar or the path: its notes, unless a page that shows folders is open.
        .onChange(of: navigation.folderID) { _, now in
            if now != nil, tab == .overview || tab == .board { tab = .notes }
        }
        .sheet(isPresented: $tidying) {
            TidyFoldersSheet(binder: binder, undoManager: undoManager) { line in
                withAnimation { tidied = line }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    if tidied == line { withAnimation { tidied = nil } }
                }
            }
        }
        .confirmationDialog("Delete “\(binder.name)”?", isPresented: $confirmDelete) {
            Button("Delete Binder", role: .destructive) {
                let general = Store.shared.defaultBinder()
                Store.shared.deleteBinder(binder, movingItemsTo: general)
                navigation.binderID = general.id
                team.scheduleSync(after: 0.5)
            }
        } message: {
            Text(deleteMessage(binder, counts: counts))
        }
    }

    /// What deleting a binder does with what's in it: it all moves to General and takes on General's sharing, said before
    /// it happens. Captures and notes made from what you said stay on this Mac either way.
    private func deleteMessage(_ binder: BinderRecord, counts: (meetings: Int, notes: Int)) -> String {
        let folders = Store.shared.folders(in: binder.id).count
        let moved = "Its \(counts.meetings) \(counts.meetings == 1 ? "meeting" : "meetings") and \(counts.notes) \(counts.notes == 1 ? "note" : "notes") move to General."
            + (folders == 0 ? "" : " \(folders == 1 ? "Its folder goes" : "Its \(folders) folders go") with it, and what was in \(folders == 1 ? "it" : "them") goes to the top of General.")
        guard team.isConfigured else { return moved }
        let generalShared = binders.first(where: \.isDefault)?.sharedWithTeam ?? false
        switch (binder.sharedWithTeam, generalShared) {
        case (true, false): return moved + " They leave the team space."
        case (false, true): return moved + " General is shared with your team, so they go to the team space too. Captures and notes made from what you said stay on this Mac."
        case (true, true): return moved + " They stay in the team space."
        case (false, false): return moved
        }
    }

    private func subtitle(_ binder: BinderRecord, counts: (meetings: Int, notes: Int)) -> String {
        var parts = ["\(counts.meetings) \(counts.meetings == 1 ? "meeting" : "meetings")", "\(counts.notes) \(counts.notes == 1 ? "note" : "notes")"]
        let conversations = Store.shared.conversationCount(in: binder.id)
        if conversations > 0 { parts.append("\(conversations) \(conversations == 1 ? "capture" : "captures")") }
        if binder.isDefault { parts.append("where new things go unless another binder is open") }
        if binder.archived { parts.append("archived") }
        return parts.joined(separator: " · ")
    }

    private func consumePendingTab() {
        guard let pending = navigation.pendingBinderTab else { return }
        tab = pending
        navigation.pendingBinderTab = nil
    }

    private func consumePendingTidy() {
        guard navigation.pendingTidy else { return }
        navigation.pendingTidy = false
        tidying = true
    }
}

/// The binder at a glance: counts, every open to-do from its meetings and notes, recent items, and who comes up in it.
struct BinderOverview: View {
    @Environment(KnowledgeService.self) private var knowledge
    @Environment(CommitmentService.self) private var commitmentService
    @Environment(HubNavigation.self) private var navigation
    let binder: BinderRecord
    let openMeeting: (UUID) -> Void
    let openNote: (UUID) -> Void
    /// Its counts, latest items and to-dos, read when it opens and after a save that could change them (lane DB10).
    @State private var data = BinderOverviewData()
    @State private var people: [KnowledgeEntity] = []
    /// For the self-tests: told when a binder's Overview shows.
    @MainActor static var appeared: ((UUID) -> Void)?

    init(binder: BinderRecord, openMeeting: @escaping (UUID) -> Void, openNote: @escaping (UUID) -> Void) {
        self.binder = binder
        self.openMeeting = openMeeting
        self.openNote = openNote
    }

    private var actions: TaskActions {
        TaskActions(openMeeting: { openMeeting($0.id) }, openNote: { openNote($0.id) },
                    commitments: CommitmentActions(toggle: { commitmentService.toggle($0) },
                                                   dismiss: { commitmentService.setStatus($0, "dismissed") },
                                                   open: { record in
                                                       navigation.pendingWritingSearch = record.quote ?? record.task
                                                       navigation.selection = .writing
                                                   }))
    }

    var body: some View {
        let tasks = data.tasks
        let open = data.openCount
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    StatCard(title: "Meetings", value: "\(data.meetingCount)", symbol: "person.2.wave.2")
                    StatCard(title: "Notes", value: "\(data.noteCount)", symbol: "note.text")
                    StatCard(title: "Open to-dos", value: "\(open)", symbol: "checklist")
                    StatCard(title: "People & topics", value: "\(people.count)", symbol: "point.3.connected.trianglepath.dotted")
                }

                // Lane DS1: every note here with Distill on, with how its work is going.
                WorkListSection(binder: binder, openNote: openNote)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("To-dos").font(BindersTheme.columnTitle).foregroundStyle(.sectionInk)
                        Spacer()
                        Text(open == 0 ? "nothing open" : "\(open) open").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    TaskBoard(tasks: tasks)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperCard(padding: 16)

                HStack(alignment: .top, spacing: 16) {
                    recentList(title: "Recent meetings", empty: "No meetings yet.", items: data.recentMeetings.map { meeting in
                        (meeting.id, meeting.title, meeting.createdAt.formatted(date: .abbreviated, time: .shortened) + " · \(max(1, Int((meeting.duration / 60).rounded()))) min", { openMeeting(meeting.id) })
                    })
                    recentList(title: "Recent notes", empty: "No notes yet.", items: data.recentNotes.map { note in
                        (note.id, note.title, note.updatedAt.formatted(.relative(presentation: .named)), { openNote(note.id) })
                    })
                }

                if !people.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Comes up in this binder").font(BindersTheme.columnTitle).foregroundStyle(.sectionInk)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(people) { entity in
                                HStack(spacing: 5) {
                                    Circle().fill(EntityStyle.color(entity.type)).frame(width: 6, height: 6)
                                    Text(entity.name).lineLimit(1)
                                    Text("\(entity.documents)").monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(BindersTheme.surface))
                                .overlay(Capsule().strokeBorder(BindersTheme.line))
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .onAppear {
            data.start(binder: binder.id, actions)
            Self.appeared?(binder.id)
        }
        .onDisappear { data.stop() }
        .onChange(of: binder.id) {
            data.start(binder: binder.id, actions)
            Self.appeared?(binder.id)
        }
        .task(id: "\(binder.id)|\(knowledge.revision)") {
            people = await knowledge.store.entities(limit: 18, binder: binder.id.uuidString)
        }
    }

    private func recentList(title: String, empty: String, items: [(UUID, String, String, () -> Void)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(BindersTheme.columnTitle).foregroundStyle(.sectionInk)
            if items.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(items, id: \.0) { item in
                Button(action: item.3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.1).lineLimit(1)
                        Text(item.2).font(BindersTheme.time()).foregroundStyle(.secondary)
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

/// A binder's "What goes here", in your words: a plain button until you click it or choose it with the keyboard (or What
/// Goes Here… in the binder's menu), as the name is text, so it never takes the focus when the page opens; then one line,
/// saved when the field lets go. At most 140 characters, line breaks joined. The card router reads it with the binder's
/// latest titles. Not synced to your team.
struct WhatGoesHereField: View {
    @Bindable var binder: BinderRecord
    @Binding var editing: Bool
    @State private var text = ""
    @FocusState private var focused: Bool
    static let limit = 140

    var body: some View {
        Group {
            if editing {
                TextField("What goes here", text: $text, prompt: Text("What goes here, in a few words"))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { focused = false }
                    .onAppear {
                        text = binder.whatGoesHere
                        DispatchQueue.main.async { focused = true }
                    }
                    .onChange(of: text) { _, new in
                        if new.count > Self.limit { text = String(new.prefix(Self.limit)) }
                    }
                    .onChange(of: focused) { _, now in
                        guard !now else { return }
                        let line = String(PythonText.oneLine(text).prefix(Self.limit))
                        if line != binder.whatGoesHere {
                            binder.whatGoesHere = line
                            binder.updatedAt = Date()
                            Store.shared.save()
                        }
                        editing = false
                    }
            } else {
                // A button, so Tab reaches it and VoiceOver reads it as something to change.
                Button { editing = true } label: {
                    Text(binder.whatGoesHere.isEmpty ? "What goes here, in a few words" : binder.whatGoesHere)
                        .foregroundStyle(binder.whatGoesHere.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("What goes here")
                .accessibilityValue(binder.whatGoesHere.isEmpty ? "Not said yet" : binder.whatGoesHere)
                .accessibilityHint("Edits what goes in this binder")
            }
        }
        .font(.callout)
        .help("Binders goes by this, and the latest titles in the binder, to file what you say or type.")
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
