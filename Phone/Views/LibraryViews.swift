import BindersKit
import SwiftUI

// MARK: - Notes

/// Notes, all of them or one binder's. Lives inside a navigation stack that knows how to open a `NoteSummary`.
struct NotesList: View {
    @Environment(MacConnection.self) private var connection
    let binder: String?
    /// The binder itself, for its folders: on a Mac that has them, the list shows the folders in `folder` (nil: the
    /// binder's top) and the notes directly in it. On one before folders, every note in the binder, as before.
    var binderInfo: BinderInfo? = nil
    var folder: FolderInfo? = nil

    @State private var notes: [NoteSummary] = []
    @State private var folders: [FolderInfo] = []
    /// The binder's Distill notes and how their work is going (lane DS1).
    @State private var work: [DistillProgress.WorkListEntry] = []
    @State private var loaded = false
    /// Nothing from the Mac yet, and no copy from last time.
    @State private var unreached = false

    /// Folders show: a binder's list, on a Mac that has them.
    private var inFolders: Bool { binderInfo != nil && connection.hasFolders }

    var body: some View {
        List {
            if inFolders, let binderInfo, !folders.isEmpty {
                Section {
                    ForEach(folders) { folder in
                        NavigationLink(value: FolderLink(binder: binderInfo, folder: folder)) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(Palette.muted)
                                Text(folder.name).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                                Spacer(minLength: 4)
                                let count = folder.notes + folder.folders
                                if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(Palette.faint) }
                            }
                            .padding(.vertical, 2)
                        }
                        .accessibilityLabel("Folder \(folder.name)")
                    }
                }
                .surfaceRows()
            }
            // Lane DS1: the binder's Work list, from a Mac that has Distill.
            if let binder, !work.isEmpty, connection.macFeatures.contains(LinkFeatures.distill) { BinderWorkList(binder: binder, entries: work) }
            ForEach(notes) { note in
                NavigationLink(value: note) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).font(.headline).foregroundStyle(Palette.ink).lineLimit(1)
                        let rest = note.preview.drop { $0 != "\n" }.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !rest.isEmpty {
                            Text(rest).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(2)
                        }
                        // Across binders, where each one is: its binder, and its folder when it's in one.
                        Text([binder == nil ? note.binder : "", binder == nil ? (note.folder ?? "") : "", note.updated.friendlyDate]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption.monospacedDigit()).foregroundStyle(Palette.faint)
                    }
                    .padding(.vertical, 2)
                }
            }
            .surfaceRows()
        }
        .listGround()
        .overlay {
            if loaded && notes.isEmpty && folders.isEmpty {
                if folder != nil {
                    EmptyState("Nothing in this folder yet", symbol: "folder", description: "Notes you make here go in it.")
                } else {
                    EmptyState("No notes yet", symbol: "note.text", description: "Notes you write or dictate show up here.")
                }
            } else if unreached {
                WaitingForMac(what: "Your notes show here") { await load() }
            }
        }
        .refreshable { await load() }
        .task(id: "\(connection.revision("notes"))|\(connection.hasFolders)") { await load() }
        .task(id: connection.revision("tasks") + connection.revision("notes")) {
            if let binder { await BinderWorkList.load(binder, connection: connection, into: $work) }
        }
    }

    private func load() async {
        var arguments: [String: Any] = ["limit": 50]
        var key = "notes-\(binder ?? "all")"
        if inFolders, let binderInfo {
            // By the binder's id, which a rename doesn't change; "/" is its top.
            arguments["binder"] = binderInfo.id
            arguments["folder"] = folder?.id ?? "/"
            key = "notes-\(binderInfo.id)-\(folder?.id ?? "top")"
        } else if let binder {
            arguments["binder"] = binder
        }
        let foldersKey = "folders-\(binderInfo?.id ?? "")-\(folder?.id ?? "top")"
        // Last time's list straight away, while the Mac answers.
        if !loaded, notes.isEmpty, let copy = connection.cached(key, as: [NoteSummary].self) {
            notes = copy
            if inFolders { folders = connection.cached(foldersKey, as: [FolderInfo].self) ?? [] }
            loaded = true
        }
        if inFolders, let binderInfo {
            let noteArguments = arguments, noteKey = key
            async let noteList = connection.fetch("list_notes", noteArguments, cache: noteKey, as: [NoteSummary].self)
            async let folderList = connection.fetch("list_folders", ["binder": binderInfo.id, "parent": folder?.id ?? "/"], cache: foldersKey,
                                                    as: [FolderInfo].self)
            if let value = await noteList.value {
                notes = value
                loaded = true
            }
            if let value = await folderList.value { folders = value }
        } else {
            let result = await connection.fetch("list_notes", arguments, cache: key, as: [NoteSummary].self)
            if let value = result.value {
                notes = value
                loaded = true
            }
            folders = []
        }
        // Only the Mac, or last time's copy, says there are none.
        unreached = !loaded
    }
}

/// A folder in a binder: the folders in it and its notes, and new notes made here go in it.
struct FolderNotesView: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.talkControlShown) private var talkControlShown
    let link: FolderLink
    @State private var writing = false
    @State private var dictating = false

    var body: some View {
        NotesList(binder: link.binder.name, binderInfo: link.binder, folder: link.folder)
            .navigationTitle(link.folder.name)
            .navigationBarTitleDisplayMode(.inline)
            // So the tabs' Dictate files a note in here too.
            .onAppear {
                PhoneNavigation.shared.binderInView = link.binder.name
                PhoneNavigation.shared.folderInView = link.folder
            }
            .onDisappear {
                if PhoneNavigation.shared.folderInView == link.folder { PhoneNavigation.shared.folderInView = nil }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { writing = true } label: { Image(systemName: "square.and.pencil") }
                        .disabled(!connection.isConnected)
                        .accessibilityLabel("New note in \(link.folder.name)")
                }
            }
            .sheet(isPresented: $writing) { NewNoteSheet(binder: link.binder.name, folder: link.folder) }
            .safeAreaInset(edge: .bottom) { if !talkControlShown { DictateButton { dictating = true } } }
            .sheet(isPresented: $dictating) { DictationSheet(binder: link.binder.name, folder: link.folder) }
            .binderTint(BinderTint.binder(link.binder.color ?? 0))
    }
}

struct NoteDetailView: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let summary: NoteSummary
    @State private var note: Note?
    @State private var unreached = false
    /// Put on Board: under way, what came of it, and the card it made, to open.
    @State private var puttingOnBoard = false
    @State private var boardOutcome: BoardOutcome?
    @State private var openedCard: CardLink?
    /// One id for the card until it's made, so one sent again after its reply was lost is made once (LinkFeatures.dedupe).
    @State private var boardRequest = UUID()

    /// What came of Put on Board.
    enum BoardOutcome: Equatable {
        case added(card: String, line: String)
        /// The Mac was out of reach: it's tried again once the Mac is back, while the note is open.
        case waitingForMac
        case problem(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let note {
                    // Lane DS1: a Distill note's work, under its title, from a Mac that has Distill.
                    if note.distill == true, connection.macFeatures.contains(LinkFeatures.distill) {
                        NoteWorkSection(noteID: note.id)
                    }
                    // An agent's words in it: whose, until it's made yours on the Mac. Lavender, with the sparkle.
                    if let line = note.agentMark.noteLine {
                        Label("\(line) Answers and corrections leave it out until you make it yours in \(MacConnection.onHub ? "your hub" : "Binders on your Mac").", systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(Palette.agent)
                    }
                    // The note itself is a page: paper in the light, dark in the dark.
                    MarkdownText(markdown: note.text).paperPage()
                    if !note.digest.isEmpty {
                        // Written by your Mac's model, not an agent: not the sparkle.
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Digest", systemImage: "wand.and.rays").font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
                            MarkdownText(markdown: note.digest)
                        }
                        .surfaceCard()
                    }
                } else if unreached {
                    WaitingForMac(what: "This note opens") { await load() }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .screenGround()
        .navigationTitle(note?.title ?? summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { putOnBoard() } label: { Label("Put on Board", systemImage: "rectangle.split.3x1") }
                        .disabled(note == nil || puttingOnBoard)
                } label: {
                    if puttingOnBoard { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
                .accessibilityLabel("More")
                .accessibilityIdentifier("noteMore")
            }
        }
        .overlay(alignment: .bottom) { boardWord }
        .navigationDestination(item: $openedCard) { CardDetailView(id: $0.id) }
        // Back while the card waited for it: it's made now.
        .onChange(of: connection.isConnected) { _, connected in
            if connected, boardOutcome == .waitingForMac { putOnBoard() }
        }
        .task(id: connection.revision("notes")) { await load() }
        // What you tap on a note wears its binder's colour; its page follows the appearance.
        .binderTint(BinderColors.tint(note?.binder ?? summary.binder, connection: connection))
    }

    private func load() async {
        let key = "note-\(summary.id)"
        if note == nil { note = connection.cached(key, as: Note.self) }
        if let fetched = await connection.fetch("get_note", ["id": summary.id], cache: key, as: Note.self).value { note = fetched }
        unreached = note == nil
    }

    /// What came of Put on Board, floating at the foot of the note: where the card went, with Open; or why it isn't there.
    @ViewBuilder
    private var boardWord: some View {
        if let boardOutcome {
            HStack(spacing: 10) {
                switch boardOutcome {
                case .added(let card, let line):
                    Label(line, systemImage: "checkmark.circle").foregroundStyle(Palette.ink).lineLimit(2)
                    Spacer(minLength: 4)
                    if !card.isEmpty {
                        Button("Open") {
                            self.boardOutcome = nil
                            openedCard = CardLink(id: card)
                        }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("noteBoardOpen")
                    }
                case .waitingForMac:
                    Label("Not on the board yet: \(MacConnection.brainWords) is out of reach. It's added when \(MacConnection.brainWords) is back, while this note is open.",
                          systemImage: "laptopcomputer").foregroundStyle(Palette.ink).lineLimit(3)
                    Spacer(minLength: 4)
                    Button("Try Again") { connection.retryNow() }
                case .problem(let message):
                    ProblemLabel(message).lineLimit(3)
                    Spacer(minLength: 4)
                    Button("Try Again") { putOnBoard() }
                }
                Button { self.boardOutcome = nil } label: { Image(systemName: "xmark") }
                    .foregroundStyle(Palette.muted)
                    .accessibilityLabel("Close")
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            // A toast floats over the note: glass from iOS 26, the bar material before.
            .floatingGlass(in: Capsule())
            .padding(.horizontal)
            .padding(.bottom, 12)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("noteBoardOutcome")
        }
    }

    /// Put on Board: a card on the note's binder's board, in Backlog, with the note's title and, in its details, its first
    /// lines and a link back (NoteCards, as the Mac's own Put on Board makes them), through the Mac's create_task.
    private func putOnBoard() {
        guard let note, !puttingOnBoard else { return }
        guard connection.isConnected else {
            show(.waitingForMac)
            connection.retryNow()
            return
        }
        puttingOnBoard = true
        var arguments: [String: Any] = ["title": NoteCards.title(note.title), "column": "backlog",
                                        "details": NoteCards.details(text: note.text, noteID: note.id, agent: note.agentMark)]
        if !note.binder.isEmpty { arguments["binder"] = note.binder }
        let request = boardRequest
        Task {
            defer { puttingOnBoard = false }
            do {
                let reply = try await connection.call("create_task",
                                                      OutboxRules.arguments(arguments, id: request, dedupe: connection.macFeatures.contains(LinkFeatures.dedupe)),
                                                      timeout: LinkTimeouts.change)
                let card = (try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])?["id"] as? String ?? ""
                boardRequest = UUID()
                // A card added: filed, by touch.
                Haptics.shared.success()
                // What was done, in the past tense, with where it went.
                show(.added(card: card, line: note.binder.isEmpty ? "Added to the board" : "Added to the \(note.binder) board"))
            } catch LinkClient.Failure.rejected(let message) {
                show(.problem(message))
            } catch {
                // Out of reach, or no answer in time: it goes once the Mac is back (the same request, so it's made once).
                show(.waitingForMac)
            }
        }
    }

    private func show(_ outcome: BoardOutcome) {
        withAnimation(Motion.filing(reduceMotion: reduceMotion)) { boardOutcome = outcome }
        guard case .added = outcome else { return }
        Task {
            try? await Task.sleep(for: .seconds(6))
            if boardOutcome == outcome { withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .default) { boardOutcome = nil } }
        }
    }
}

struct NewNoteSheet: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    /// The binder it goes into; the Mac's current binder when nil.
    var binder: String? = nil
    /// The folder in it, when it's made inside one.
    var folder: FolderInfo? = nil
    @State private var text = ""
    @State private var saving = false
    @State private var problem: String?
    @State private var dictating = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            // A note is written on its page: paper in the light, dark in the dark.
            TextEditor(text: $text)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("The first line is the title.").foregroundStyle(Palette.paperInk.opacity(0.45)).padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false)
                    }
                }
                .paperPage(padding: 12)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .screenGround()
                .navigationTitle(folder.map { "New note in \($0.name)" } ?? binder.map { "New note in \($0)" } ?? "New note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving { ProgressView() } else {
                            Button("Save", action: save).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button { dictating = true } label: { Label("Dictate", systemImage: "mic.fill") }
                    }
                }
                .sheet(isPresented: $dictating) {
                    DictationSheet(binder: binder, folder: folder) { words in
                        text += (text.isEmpty || text.hasSuffix("\n") || text.hasSuffix(" ") ? "" : " ") + words
                    }
                }
                .alert("Couldn't save the note", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(problem ?? "") }
                .task {
                    // Once the sheet is up, so the keyboard comes with it.
                    try? await Task.sleep(for: .milliseconds(350))
                    focused = true
                }
        }
    }

    /// Straight to the Mac, or kept here until it's back.
    private func save() {
        saving = true
        Task {
            defer { saving = false }
            // In its binder: filed, by touch.
            if await connection.save("add_note", text: text, binder: binder, folder: folder?.id) { Haptics.shared.success() }
            dismiss()
        }
    }
}

// MARK: - Meetings

/// Meetings, all of them or one binder's. Lives inside a navigation stack that knows how to open a `MeetingSummary`.
struct MeetingsList: View {
    @Environment(MacConnection.self) private var connection
    let binder: String?

    @State private var meetings: [MeetingSummary] = []
    @State private var loaded = false
    /// Nothing from the Mac yet, and no copy from last time.
    @State private var unreached = false

    var body: some View {
        List {
            ForEach(meetings) { meeting in
                NavigationLink(value: meeting) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(.headline).foregroundStyle(Palette.ink).lineLimit(2)
                        Text(details(meeting)).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                    }
                    .padding(.vertical, 2)
                }
            }
            .surfaceRows()
        }
        .listGround()
        .overlay {
            if loaded && meetings.isEmpty {
                EmptyState("No meetings yet", symbol: "person.2.wave.2", description: MacConnection.onHub ? "Meetings sent to your hub show up here." : "Meetings your Mac takes notes on show up here.")
            } else if unreached {
                WaitingForMac(what: "Your meetings show here") { await load() }
            }
        }
        .refreshable { await load() }
        .task(id: connection.revision("meetings")) { await load() }
    }

    private func details(_ meeting: MeetingSummary) -> String {
        var parts = [meeting.date.friendlyDate]
        if meeting.durationMinutes > 0 { parts.append("\(meeting.durationMinutes) min") }
        if !meeting.attendees.isEmpty { parts.append(meeting.attendees.prefix(3).joined(separator: ", ")) }
        if binder == nil, !meeting.binder.isEmpty { parts.append(meeting.binder) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func load() async {
        var arguments: [String: Any] = ["limit": 50]
        if let binder { arguments["binder"] = binder }
        let key = "meetings-\(binder ?? "all")"
        // Last time's list straight away, while the Mac answers.
        if !loaded, meetings.isEmpty, let copy = connection.cached(key, as: [MeetingSummary].self) {
            meetings = copy
            loaded = true
        }
        let result = await connection.fetch("list_meetings", arguments, cache: key, as: [MeetingSummary].self)
        if let value = result.value {
            meetings = value
            loaded = true
        }
        // Only the Mac, or last time's copy, says there are none.
        unreached = !loaded
    }
}

struct MeetingDetailView: View {
    @Environment(MacConnection.self) private var connection
    let summary: MeetingSummary
    @State private var meeting: Meeting?
    @State private var unreached = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let meeting {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).font(Typeface.title(.title2)).foregroundStyle(Palette.ink)
                        Text([meeting.date.friendlyDate, meeting.app, meeting.binder].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted)
                        if !meeting.attendees.isEmpty {
                            Text(meeting.attendees.joined(separator: ", ")).font(.subheadline).foregroundStyle(Palette.muted)
                        }
                    }
                    MarkdownText(markdown: meeting.notes).surfaceCard()
                    if !meeting.ownNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Your notes", systemImage: "pencil").font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
                            MarkdownText(markdown: meeting.ownNotes)
                        }
                        .surfaceCard()
                    }
                } else if unreached {
                    WaitingForMac(what: "This meeting opens") { await load() }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .screenGround()
        .navigationBarTitleDisplayMode(.inline)
        .task(id: connection.revision("meetings")) { await load() }
        .binderTint(BinderColors.tint(meeting?.binder ?? summary.binder, connection: connection))
    }

    private func load() async {
        let key = "meeting-\(summary.id)"
        if meeting == nil { meeting = connection.cached(key, as: Meeting.self) }
        if let fetched = await connection.fetch("get_meeting", ["id": summary.id], cache: key, as: Meeting.self).value { meeting = fetched }
        unreached = meeting == nil
    }
}

// MARK: - Ask

struct AskView: View {
    @Environment(MacConnection.self) private var connection
    @Environment(\.dismiss) private var dismiss
    @State private var question: String

    /// `question`, asked at once: one to ask again, say (`-ask "…"` for development).
    init(question: String = UserDefaults.standard.string(forKey: "ask") ?? "") {
        _question = State(initialValue: question)
    }
    @State private var answer: Answer?
    @State private var asking = false
    @State private var problem: String?
    /// The answer as a Mac that streams writes it, until the whole of it arrives.
    @State private var shown = LinkAskProgress.Shown<Passage>()
    /// Saying the question instead of typing it: the words fill the field as they're heard, and Done asks.
    @State private var voice = DictationSession()
    @State private var hearing = false
    /// Talk, opened from here: a conversation out loud that carries on from this question and its answer.
    @State private var talking: TalkSession?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        TextField("What did I promise Sam this week?", text: $question, axis: .vertical)
                            .lineLimit(1...4)
                            .submitLabel(.go)
                            .onSubmit(ask)
                        Button(action: sayQuestion) {
                            // Red while the microphone is live, and only then.
                            Image(systemName: hearing ? "stop.circle.fill" : "mic").font(.title2)
                                .foregroundStyle(hearing && voice.phase == .listening ? Palette.live : Palette.muted)
                        }
                        .disabled(asking || voice.phase == .transcribing)
                        .accessibilityLabel(hearing ? "Done talking" : "Say the question")
                        .accessibilityIdentifier("askByVoice")
                        Button(action: ask) {
                            if asking { ProgressView() } else { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        }
                        .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || asking || !connection.isConnected)
                    }
                    .surfaceCard(padding: 12)

                    if !connection.isConnected {
                        Label("Asking needs \(MacConnection.brainWords), which is out of reach right now. Ask again once it's back.", systemImage: "wifi.slash")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    if let problem, shown.text.isEmpty {
                        ProblemLabel(problem)
                    }
                    if let answer {
                        MarkdownText(markdown: answer.answer).surfaceCard()
                        // Read out by the hub's own voice, when it has one.
                        if connection.brain == .hub, connection.macFeatures.contains(HubVoice.feature) { HubListenButton(text: answer.answer) }
                        sources(answer.sources)
                    } else if asking, connection.streamsAsk {
                        // What the Mac found shows at once, then its answer as it's written.
                        if shown.text.isEmpty, let status = AskStage.waitingForMac(shown.stage, found: shown.sources.count) {
                            HStack(spacing: 8) {
                                ProgressView().tint(Palette.muted)
                                // Searching, then what it found, then writing: each line crossfades into the next.
                                Text(status).font(.footnote).foregroundStyle(Palette.muted)
                                    .contentTransition(.opacity)
                                    .animation(.easeInOut(duration: 0.2), value: status)
                            }
                        } else {
                            MarkdownText(markdown: shown.text).surfaceCard()
                        }
                        sources(shown.sources)
                    } else if !shown.text.isEmpty {
                        // Stopped part-way (out of time, the link closed): what was written stays, with why it stopped.
                        MarkdownText(markdown: shown.text).surfaceCard()
                        if let problem { ProblemLabel(problem) }
                        sources(shown.sources)
                    } else if !asking {
                        Text(MacConnection.onHub ? "Ask about anything in your binders on the hub: notes, cards and what you captured. Your hub answers with its model, and shows where the answer came from." : "Ask about anything in your meetings, notes, dictations and messages. Your Mac answers with its own model, and shows where the answer came from.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    if connection.talks, !asking {
                        // Out loud instead, from here on.
                        Button { talking = TalkSession(seed: answer.map { [TalkTurn(who: .you, text: question), TalkTurn(who: .hub, text: HubVoice.spoken($0.answer))] } ?? []) } label: {
                            Label(answer == nil ? "Talk with your hub" : "Talk it through", systemImage: "waveform")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("askTalk")
                    }
                }
                .padding()
            }
            .screenGround()
            .navigationTitle("Ask")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fullScreenCover(item: $talking) { TalkView(talk: $0) }
            .task {
                if !question.isEmpty, answer == nil {
                    for _ in 0..<50 where !connection.isConnected { try? await Task.sleep(for: .milliseconds(200)) }
                    ask()
                }
            }
            .onChange(of: voice.text) { _, words in if hearing, !words.isEmpty { question = words } }
            // Closed while listening: the microphone goes back, and All-day capture with it.
            .onDisappear { if hearing { voice.cancel() } }
        }
    }

    /// The microphone beside the question: tapped, it listens (pausing All-day capture, as dictating does); tapped again,
    /// what was heard is asked. Nothing heard leaves the field as it was.
    private func sayQuestion() {
        if hearing {
            Task {
                let heard = await voice.finishHeard()
                hearing = false
                guard !heard.isEmpty else { return }
                question = heard
                ask()
            }
            return
        }
        hearing = true
        problem = nil
        Task {
            await voice.start()
            if case .failed(let message) = voice.phase {
                hearing = false
                problem = message
                voice.cancel()
            }
        }
    }

    @ViewBuilder
    private func sources(_ passages: [Passage]) -> some View {
        if !passages.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Sources").font(Typeface.title(.headline)).foregroundStyle(Palette.ink)
                ForEach(Array(passages.enumerated()), id: \.offset) { index, source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("[\(index + 1)] \(source.title)").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text([source.kind.capitalized, source.date.friendlyDate, source.binder].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                        Text(Self.plain(source.text)).font(.footnote).foregroundStyle(Palette.muted).lineLimit(4)
                    }
                }
            }
            .surfaceCard()
        }
    }

    /// A source passage without its Markdown: "## Summary" and "[[Sam]]" read as words.
    static func plain(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n")
            .map { MarkdownSyntax.plainTitle($0).replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "") }
            .filter { !$0.isEmpty && $0.lowercased() != "summary" }
            .joined(separator: " ")
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !asking else { return }
        asking = true
        problem = nil
        answer = nil
        shown = .init()
        Task {
            defer { asking = false }
            do {
                // Ask's time (LinkTimeouts.ask), past the Mac's own limit on its answer; what's found and written shows as it
                // comes, from a Mac that sends it.
                answer = try await connection.ask(text) { update in
                    shown.apply(seq: update.seq, stage: update.stage, sources: MacConnection.passages(in: update), text: update.text)
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

// MARK: - Markdown

/// Notes, digests and meeting notes as the Mac shows them: headings, lists, checklists, quotes, code and inline styles.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in block }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [AnyView] {
        var views: [AnyView] = []
        var code: [String]?
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if MarkdownSyntax.isFence(raw) {
                if let lines = code {
                    views.append(AnyView(Text(lines.joined(separator: "\n")).font(.system(.footnote, design: .monospaced))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.line))))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            let indent = CGFloat(raw.prefix { $0 == " " }.count / 2) * 16
            if line.isEmpty {
                views.append(AnyView(Spacer().frame(height: 4)))
            } else if let embed = MarkdownMedia.embed(inLine: raw, at: 0) {
                // Pictures and videos stay on the Mac for now: say what's there.
                let video = MarkdownMedia.kind(of: embed.source) == .video
                let name = embed.caption.isEmpty ? (embed.source as NSString).lastPathComponent : embed.caption
                views.append(AnyView(Label("\(name) · \(video ? "video" : "picture") on \(MacConnection.brainWords)", systemImage: video ? "film" : "photo")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.line))))
            } else if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let font: Font = level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline
                views.append(AnyView(inline(MarkdownSyntax.plainTitle(line)).font(font).padding(.top, 6)))
            } else if let task = NotesEditing.task(from: raw) {
                views.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Green is done, and nothing else.
                    Image(systemName: task.done ? "checkmark.square.fill" : "square").foregroundStyle(task.done ? Palette.done : .secondary)
                    inline((task.owner.map { "**\($0)** — " } ?? "") + task.text).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary)
                }.padding(.leading, indent)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                views.append(AnyView(HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    inline(String(line.dropFirst(2)))
                }.padding(.leading, indent)))
            } else if line.hasPrefix(">") {
                views.append(AnyView(HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                    inline(String(line.drop { $0 == ">" || $0 == " " })).foregroundStyle(.secondary)
                }))
            } else {
                views.append(AnyView(inline(line).padding(.leading, indent)))
            }
        }
        return views
    }

    private func inline(_ raw: String) -> Text {
        // [[Wiki links]] read as the name they link to.
        if let known = Self.parsed.object(forKey: raw as NSString) { return Text(known.value) }
        let text = raw.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        Self.parsed.setObject(Parsed(attributed), forKey: raw as NSString)
        return Text(attributed)
    }

    /// Lines already parsed: a screen redrawn, or opened again, doesn't parse its Markdown again.
    private nonisolated(unsafe) static let parsed: NSCache<NSString, Parsed> = {
        let cache = NSCache<NSString, Parsed>()
        cache.countLimit = 4_000
        return cache
    }()

    private final class Parsed {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
}
