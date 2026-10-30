import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import BindersKit

// MARK: - Live meeting window

@MainActor
final class MeetingWindowController {
    static let shared = MeetingWindowController()
    private var panel: NSPanel?

    func show(service: MeetingService, meeting: MeetingRecord, activate: Bool) {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                                styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.title = "Meeting notes"
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if !panel.setFrameUsingName("BindersMeetingNotes"), let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 440, y: screen.maxY - 580))
            }
            panel.setFrameAutosaveName(AppDefaults.frameName("BindersMeetingNotes"))
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: LiveMeetingView(meeting: meeting)
            .environment(service)
            .modelContainer(Store.shared.container))
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.orderFrontRegardless()
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }
}

struct LiveMeetingView: View {
    @Environment(MeetingService.self) private var service
    @Bindable var meeting: MeetingRecord
    @State private var showTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RecordingDot(hearing: { service.hearsSpeech })
                TextField("Title", text: $meeting.title)
                    .textFieldStyle(.plain)
                    .font(BindersTheme.cardTitle)
                    .renamesLinks(of: meeting.title)
                if let start = service.liveStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(TranscriptFormatter.timestamp(context.date.timeIntervalSince(start)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await service.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                // Red: the microphone is live.
                .tint(BindersTheme.live)
                .controlSize(.small)
            }
            if let issue = service.systemAudioIssue {
                HStack(alignment: .top) {
                    StatusLabel("Only your microphone is being recorded. \(issue)", .problem).font(.caption)
                    Button("Settings") { Permissions.openSystemAudioSettings() }.controlSize(.small)
                }
            }
            Picker("", selection: $showTranscript) {
                Text("My notes").tag(false)
                Text("Live transcript").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if showTranscript {
                LiveTranscriptView(segments: service.liveSegments, names: meeting.speakerNames)
            } else {
                MarkdownNoteEditor(text: $meeting.userNotes, fontSize: 14,
                                   placeholder: "Jot down what matters (type, or hold fn to dictate). The summary focuses on it.",
                                   inset: NSSize(width: 4, height: 8), compactToolbar: true, links: LinkTargets.forEditor(in: meeting.binderID))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 32)
        .padding(.bottom, 12)
        .pageGround()
    }
}

struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]
    let names: [String: String]
    @ReducedMotion private var reduceMotion

    var body: some View {
        let blocks = TranscriptFormatter.blocks(segments, names: names)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if blocks.isEmpty {
                        Text("Listening… lines appear after each pause.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        TranscriptBlockRow(block: block).id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: blocks.count) {
                guard !blocks.isEmpty else { return }
                // Follows the newest line; it jumps there under Reduce Motion.
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(blocks.count - 1, anchor: .bottom) }
            }
        }
    }
}

struct TranscriptBlockRow: View {
    let block: TranscriptBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(block.speaker).font(.caption.weight(.semibold)).foregroundStyle(SpeakerColor.style(for: block.speaker))
                Text(TranscriptFormatter.timestamp(block.start)).font(BindersTheme.time()).foregroundStyle(.tertiary)
            }
            // What was said, quoted.
            Text(block.text).font(BindersTheme.quote()).textSelection(.enabled)
        }
    }
}

/// The live microphone's red dot. It breathes while speech is heard and holds still otherwise. Under Reduce Motion it
/// never moves: a ring fades in around it while speech is heard instead.
struct PulsingDot: View {
    /// Speech is heard now.
    var hearing: Bool
    @ReducedMotion private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !hearing || reduceMotion)) { context in
            Circle()
                .fill(BindersTheme.live)
                .frame(width: 8, height: 8)
                .opacity(Self.opacity(at: context.date.timeIntervalSinceReferenceDate, hearing: hearing, reduceMotion: reduceMotion))
        }
        .frame(width: 8, height: 8)
        .background {
            Circle()
                .strokeBorder(BindersTheme.live.opacity(0.5), lineWidth: 1.5)
                .frame(width: 14, height: 14)
                .opacity(reduceMotion && hearing ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: hearing)
        }
    }

    /// The dot's opacity at a moment: breathing while speech is heard, still otherwise and under Reduce Motion.
    static func opacity(at time: TimeInterval, hearing: Bool, reduceMotion: Bool) -> Double {
        guard hearing, !reduceMotion else { return 1 }
        return 0.55 + 0.45 * abs(sin(time * 2))
    }
}

/// The red dot for a recording in progress: asks `hearing` a few times a second whether speech is heard, and moves only
/// then.
struct RecordingDot: View {
    let hearing: @MainActor () -> Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            PulsingDot(hearing: hearing())
        }
    }
}

/// All-day capture's waveform while it listens: red, as the microphone is live, and moving only while speech is heard,
/// still through the quiet of a conversation that's still open, as on the iPhone. It asks `hearing` four times a second,
/// only while it shows. Under Reduce Motion it never moves: it dims in the quiet instead.
struct ListeningWaveform: View {
    let hearing: @MainActor () async -> Bool
    @ReducedMotion private var reduceMotion
    @State private var speaking = false

    var body: some View {
        Image(systemName: "waveform")
            .foregroundStyle(BindersTheme.live)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: speaking && !reduceMotion)
            .opacity(reduceMotion && !speaking ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.25), value: speaking)
            .task {
                while !Task.isCancelled {
                    let heard = await hearing()
                    if heard != speaking { speaking = heard }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            .accessibilityHidden(true)
    }
}

/// Each speaker's colour in a transcript: you in the accent's words, the others from colours that mean nothing else (no
/// red, amber, green or lavender).
enum SpeakerColor {
    static func color(for speaker: String) -> Color {
        if speaker == TranscriptSegment.you { return BindersTheme.accentText }
        let hash = speaker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return palette[hash % palette.count]
    }

    /// The same, as it's drawn: you in the accent's words, or muted on a binder's pages, where the accent doesn't go.
    static func style(for speaker: String) -> AnyShapeStyle {
        speaker == TranscriptSegment.you ? AnyShapeStyle(.infoText) : AnyShapeStyle(color(for: speaker))
    }

    private static let palette: [Color] = [
        (0x4299E6, 0x2668B0), (0xE65C94, 0xB8336A), (0x2FA9A7, 0x1D7F7D), (0xC77DD9, 0x8E44A8),
        (0xC08A62, 0x8A5A36), (0x45B4D0, 0x22809A), (0x7F8FB8, 0x4E5F8C), (0xD98AB4, 0xA4527E),
    ].enumerated().map { index, pair in Color(nsColor: BindersTheme.dynamic("speaker\(index)", dark: pair.0, light: pair.1)) }
}

// MARK: - Hub: Meetings

struct MeetingsView: View {
    @Environment(MeetingService.self) private var service
    @Environment(HubNavigation.self) private var navigation
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var controller
    @Environment(TeamSyncService.self) private var team
    @Environment(\.binderTint) private var binderTint
    @Environment(\.undoManager) private var undoManager
    @ReducedMotion private var reduceMotion
    @Query private var meetings: [MeetingRecord]
    /// The binder's folders, drawn as a tree with the meetings in them.
    @Query private var folders: [FolderRecord]
    /// Which folders are open, here and in the sidebar.
    @State private var expansion = FolderExpansion.shared
    /// A row to scroll to: one just opened, or a folder shown from the sidebar.
    @State private var scrollTarget: String?
    /// A drag over the list's title, which takes it to the top of the binder.
    @State private var topTargeted = false
    /// The ones chosen in the list: one, which opens beside it, or several (⌘-click, ⇧-click, ⌘A), to move or delete
    /// together.
    @State private var selection: Set<UUID> = []
    @State private var search = ""
    @State private var importing = false
    /// Conversations kept out of sight as small talk, shown on request for a week before they go.
    @State private var showsTrivial = false
    /// What ⌫ or Delete… chose, waiting for the one yes they all need.
    @State private var toDelete: [MeetingRecord] = []
    let binderID: UUID?
    /// The iPhone's conversations instead of meetings.
    let showsConversations: Bool
    /// Where new ones go in that binder (HubNavigation.folderID); nil at its top.
    let folderID: UUID?
    /// For self-tests: the ones to select as the list opens, as ⌘-click would.
    @MainActor static var selectOnOpen: Set<UUID>?
    /// For self-tests: told what the list shows each time it draws, row by row.
    @MainActor static var drawn: (([OutlineEntry<MeetingRecord>]) -> Void)?

    /// The meetings in one binder, as a tree of its folders, or every meeting when `binderID` is nil; or the
    /// conversations the iPhone heard.
    init(binderID: UUID? = nil, conversations: Bool = false, folderID: UUID? = nil) {
        self.binderID = binderID
        self.folderID = folderID
        showsConversations = conversations
        let kind = conversations ? MeetingRecord.conversationKind : "meeting"
        if let binderID {
            _meetings = Query(filter: #Predicate<MeetingRecord> { $0.binderID == binderID && $0.kind == kind },
                              sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
            _folders = Query(filter: #Predicate<FolderRecord> { $0.binderID == binderID })
        } else {
            _meetings = Query(filter: #Predicate<MeetingRecord> { $0.kind == kind }, sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
            _folders = Query(filter: #Predicate<FolderRecord> { _ in false })
        }
    }

    /// The one selected, open beside the list; nil for none or several.
    private var single: UUID? { selection.count == 1 ? selection.first : nil }

    /// The ones selected that the list shows, in its order.
    private var chosen: [MeetingRecord] { filtered.filter { selection.contains($0.id) } }

    /// What the list holds, in words.
    private var noun: (one: String, many: String) { showsConversations ? ("capture", "captures") : ("meeting", "meetings") }

    /// The meetings in the binder, in all its folders.
    private var here: [MeetingRecord] {
        guard let binderID else { return meetings }
        // Its binder checked too: one just moved to another binder leaves at once, before the list is read again.
        return meetings.filter { $0.binderID == binderID }
    }

    /// While searching, the list shows what matches without its folders, each saying where it is.
    private var flat: Bool { binderID == nil || !search.trimmed.isEmpty }

    /// The folder one shows in: its own, when it's one of the binder's; else the top.
    private func folder(of meeting: MeetingRecord) -> UUID? {
        meeting.folderID.flatMap { id in folders.contains { $0.id == id } ? id : nil }
    }

    /// The list's rows: the binder's folders as a tree, what's in each under it while it's open, and what's at the top
    /// after the folders; or, searched, what matches alone.
    private func entries(_ shown: [MeetingRecord]) -> [OutlineEntry<MeetingRecord>] {
        guard !flat else { return shown.map { .item($0, depth: 0) } }
        return OutlineEntry.tree(folders: folders, items: shown, folderOf: { $0.folderID }, open: expansion.folders)
    }

    /// Opens the folders they're in, so they show, and scrolls to the first.
    private func reveal(_ ids: Set<UUID>) {
        guard let binderID, !ids.isEmpty else { return }
        for id in ids {
            guard let record = meetings.first(where: { $0.id == id }) ?? Store.shared.meeting(id), record.binderID == binderID else { continue }
            expansion.reveal(record.folderID, in: binderID, itself: true, sidebar: false)
        }
        let first = filtered.first { ids.contains($0.id) }?.id ?? ids.first
        scrollTarget = first.map(OutlineEntry<MeetingRecord>.rowID(item:))
    }

    /// A folder clicked: open or closed in place, and where new ones go.
    private func choose(_ folder: FolderRecord) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expansion.toggle(folder.id) }
        navigation.folderID = folder.id
    }

    /// A folder shown from the sidebar, or just made: scrolled to.
    private func showFolder() {
        guard let id = navigation.folderToShow, folders.contains(where: { $0.id == id }) else { return }
        scrollTarget = OutlineEntry<MeetingRecord>.rowID(folder: id)
        navigation.folderToShow = nil
    }

    /// The folder several are all in, or, from different folders, where new ones go.
    private func sharedFolder(of picked: [MeetingRecord]) -> (folder: UUID?, together: Bool) {
        let places = Set(picked.map(folder(of:)))
        return places.count == 1 ? (places.first ?? nil, true) : (folderID, false)
    }

    private var shown: [MeetingRecord] { showsTrivial ? here : here.filter { $0.status != "trivial" } }
    private var trivialCount: Int { here.filter { $0.status == "trivial" }.count }

    private var filtered: [MeetingRecord] {
        let query = search.trimmed
        guard !query.isEmpty else { return shown }
        return shown.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.userNotes.localizedCaseInsensitiveContains(query)
        }
    }

    /// The list's width: narrower on a narrow page, so the meeting beside it keeps its room.
    static func listWidth(onPage width: CGFloat) -> CGFloat { width < 800 ? 230 : 290 }

    var body: some View {
        GeometryReader { proxy in
            page(listWidth: Self.listWidth(onPage: proxy.size.width))
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: showsConversations ? [UTType(exportedAs: BindersTransfer.typeIdentifier)] : [.audio, .movie],
                      allowsMultipleSelection: showsConversations) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            if showsConversations {
                // Opened from inside a folder, what's kept goes in it.
                urls.forEach { BindersFiles.open($0, controller: controller, folder: binderID == nil ? nil : folderID) }
                return
            }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let record = await service.importRecording(url) {
                    fileHere(record.id)
                    selection = [record.id]
                    reveal([record.id])
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !showsConversations else { return false }
            let files = urls.filter { url in
                let type = UTType(filenameExtension: url.pathExtension) ?? .data
                return url.isFileURL && (type.conforms(to: .audio) || type.conforms(to: .movie))
            }
            guard !files.isEmpty else { return false }
            Task {
                for url in files {
                    if let record = await service.importRecording(url) {
                        fileHere(record.id)
                        selection = [record.id]
                        reveal([record.id])
                    }
                }
            }
            return true
        }
        .onAppear {
            if let ids = Self.selectOnOpen {
                selection = ids
                reveal(ids)
            } else if !takePending(), selection.isEmpty {
                // The newest one that shows: at the top, or in an open folder.
                let first = showsConversations ? nil : service.recordingMeetingID
                selection = (first ?? OutlineEntry.items(in: entries(shown)).first?.id).map { [$0] } ?? []
            }
            showFolder()
        }
        .onChange(of: navigation.pendingMeetingID) { _ = takePending() }
        .onChange(of: navigation.folderToShow) { showFolder() }
        // New ones go where the one you chose is.
        .onChange(of: selection) {
            if binderID != nil, let id = single, let record = meetings.first(where: { $0.id == id }), record.binderID == binderID {
                navigation.folderID = folder(of: record)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TeamSyncService.itemsWillBeRemoved)) { notification in
            // A teammate stopped sharing a selected meeting: let it go before sync deletes it.
            if let ids = notification.userInfo?["ids"] as? Set<UUID> { selection.subtract(ids) }
        }
        .onChange(of: meetings.map(\.id)) {
            // One discarded after processing (nothing was said), deleted or moved away disappears from under the selection.
            let present = Set(meetings.map(\.id))
            if !selection.isSubset(of: present) { selection.formIntersection(present) }
        }
        // Undo of a delete: what came back is selected, when it's this list's.
        .onChange(of: MeetingTrash.shared.restoredMeetings) { _, ids in
            let mine = ids.filter { id in Store.shared.meeting(id).map { $0.isConversation == showsConversations && (binderID == nil || $0.binderID == binderID) } == true }
            if !mine.isEmpty { selection = mine }
        }
    }

    private func page(listWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if showsConversations {
                    title("Captures")
                    Text("Heard by All-day capture on your iPhone or this Mac. From the iPhone, only the text came here, and it's never shared with your team.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { importing = true } label: {
                        Label("Open a Binders File…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help(binderID != nil && folderID != nil
                          ? "Captures your iPhone shared by AirDrop or saved to Files go in this folder. A capture already here isn't kept twice."
                          : "Captures your iPhone shared by AirDrop or saved to Files. A capture already here isn't kept twice.")
                    if trivialCount > 0 || showsTrivial {
                        Toggle("Show small talk (\(trivialCount))", isOn: $showsTrivial)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("Captures with nothing worth keeping are hidden, and deleted a week after they were heard.")
                    }
                } else {
                    title("Meetings")
                    Button {
                        Task {
                            await service.toggle()
                            if let id = service.recordingMeetingID {
                                fileHere(id)
                                selection = [id]
                                reveal([id])
                            }
                        }
                    } label: {
                        Label(service.isRecording ? "Stop recording" : "Record meeting",
                              systemImage: service.isRecording ? "stop.fill" : "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    // Red only while the microphone is live; otherwise the binder's colour, in the shade its white words read on.
                    .tint(service.isRecording ? BindersTheme.live : (binderTint?.control ?? BindersTheme.accent))
                    .controlSize(.large)
                    Button { importing = true } label: {
                        Label("Import Recording…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Transcribe an audio or video file into a new meeting. You can also drop a file anywhere on this page.")
                }
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                let filtered = self.filtered
                let entries = self.entries(filtered)
                let indented = !flat && !folders.isEmpty
                let index = FolderTree.index(FolderTree.untangled(folders.map(\.node)))
                let _ = Self.drawn?(entries)
                ScrollViewReader { proxy in
                List(selection: $selection) {
                    // The folders as a tree: click one to open or close it where it is; drop a meeting on one to move it in.
                    ForEach(entries) { entry in
                        switch entry {
                        case .folder(let folder, let depth, let count, let open):
                            FolderTreeRow(folder: folder, depth: depth, count: count, open: open, current: folder.id == folderID) { choose(folder) }
                        case .empty(let folder, let depth):
                            OutlineEmptyRow(folder: folder, depth: depth, text: showsConversations ? "No captures" : "No meetings")
                        case .item(let meeting, let depth):
                            MeetingRow(meeting: meeting, busy: service.busyMeetingIDs.contains(meeting.id),
                                       // A teammate's being recorded on their Mac shows as recording too (lane DB4).
                                       recording: service.recordingMeetingID == meeting.id || (meeting.isTeamCopy && meeting.status == "recording"),
                                       showsSharing: settings.teamFolderPath != nil,
                                       place: flat ? FolderTree.chain(to: folder(of: meeting), in: index).map(\.name) : [])
                                .padding(.leading, indented ? OutlineIndent.item(depth) : 0)
                                .tag(meeting.id)
                                // Onto a folder, here or in the sidebar, or onto a binder: with every one selected beside it.
                                .draggableItems(dragged(meeting))
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onChange(of: scrollTarget, initial: true) { _, target in
                    guard let target else { return }
                    // Once the folders just opened are in the list.
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
                        scrollTarget = nil
                    }
                }
                }
                .overlay {
                    if flat, filtered.isEmpty, !search.trimmed.isEmpty {
                        ContentUnavailableView.search(text: search.trimmed)
                    }
                }
                // ⌫ or ⌦ on the selected ones, or Delete… in the menu: one question for all of them.
                .onDeleteCommand { requestDelete(chosen) }
                .onKeyPress(.deleteForward) {
                    guard !chosen.isEmpty else { return .ignored }
                    requestDelete(chosen)
                    return .handled
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count > 1 {
                        severalItems(filtered.filter { ids.contains($0.id) })
                    } else if let id = ids.first, let meeting = meetings.first(where: { $0.id == id }), !meeting.isTeamCopy, let binderID = meeting.binderID {
                        Menu("Move to Folder") {
                            MoveToFolderItems(binderID: binderID, current: Store.shared.shownFolder(meeting.folderID, in: binderID)) { target in
                                move([meeting], toFolder: target, in: binderID)
                            }
                        }
                    }
                }
                .confirmationDialog(deleteTitle(toDelete), isPresented: Binding(get: { !toDelete.isEmpty }, set: { if !$0 { toDelete = [] } })) {
                    Button(deleteButton(toDelete), role: .destructive) { delete(toDelete) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(deleteMessage(toDelete))
                }
                undoBar
            }
            .padding(.top, 24)
            .padding(.horizontal, 12)
            .frame(width: listWidth)
            .animation(.easeOut(duration: 0.2), value: MeetingTrash.shared.last?.id)

            Divider()

            if selection.count > 1 {
                several(chosen)
            } else if let meeting = meetings.first(where: { $0.id == single }) {
                MeetingDetailView(meeting: meeting) { delete([meeting]) }
                    .id(meeting.id)
            } else if showsConversations {
                ContentUnavailableView {
                    Label("Captures", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Turn on All-day capture in Binders on your iPhone. It writes down the conversations around you on the phone, and sends only the text here, where each gets notes and its promises become to-dos.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Meeting notes", systemImage: "person.2.wave.2")
                } description: {
                    Text("Press \(settings.hotkeys.meeting?.displayString() ?? "Record meeting") during a call. Nothing joins the call: Binders records on this Mac, transcribes, labels speakers and writes notes locally.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// For a few seconds after a delete: what went, and Undo.
    @ViewBuilder
    private var undoBar: some View {
        let trash = MeetingTrash.shared
        if let deleted = trash.last, trash.lastDeleted.allSatisfy({ $0.isConversation == showsConversations }) {
            let count = trash.lastDeleted.count
            HStack(spacing: 8) {
                Image(systemName: "trash").foregroundStyle(.secondary)
                Text(count > 1 ? "Deleted \(count) \(noun.many)" : "Deleted “\(deleted.title)”").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Undo") { trash.restore(trash.lastDeleted, undoManager: undoManager) }
                    .help(count > 1 ? "Put the \(noun.many) back (⌘Z)" : "Put the \(noun.one) back (⌘Z)")
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BindersTheme.line))
            .padding(.bottom, 8)
            // It rises into place; under Reduce Motion it fades in.
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The list's title, with Collapse All beside it. What's dropped on it goes to the top of the binder.
    private func title(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(BindersTheme.columnTitle).foregroundStyle(.sectionInk)
            Spacer(minLength: 0)
            if let binderID, !folders.isEmpty { CollapseFoldersButton(binderID: binderID) }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(topTargeted ? AnyShapeStyle(TintFill().opacity(0.18)) : AnyShapeStyle(Color.clear)))
        .padding(.horizontal, -4)
        .dropDestination(for: String.self) { items, _ in
            guard let binderID else { return false }
            return DraggedItem.drop(items, into: nil, binder: binderID, undoManager: undoManager)
        } isTargeted: { topTargeted = $0 && binderID != nil }
    }

    /// A meeting recorded or imported with a folder chosen goes in it.
    private func fileHere(_ id: UUID) {
        guard let folderID, let record = meetings.first(where: { $0.id == id }) ?? Store.shared.meeting(id),
              record.binderID == binderID, record.folderID == nil else { return }
        try? Store.shared.move(record, toFolder: folderID)
    }

    /// Opens the meeting or conversation something asked for, when it's one of this list's, its folder open and scrolled
    /// to; the other list takes the rest.
    private func takePending() -> Bool {
        guard let pending = navigation.pendingMeetingID else { return false }
        guard let record = meetings.first(where: { $0.id == pending }) else {
            // Asked for before the record arrived (just recorded): meetings take it, as they always have.
            if !showsConversations, Store.shared.binderID(ofMeeting: pending) == nil {
                selection = [pending]
                navigation.pendingMeetingID = nil
                return true
            }
            return false
        }
        if record.status == "trivial" { showsTrivial = true }
        selection = [pending]
        reveal([pending])
        navigation.pendingMeetingID = nil
        return true
    }

    // MARK: Several at once

    /// What dragging one carries: it, or, when it's one of several selected, all of them (those that can't go stay, and
    /// say why). A teammate's alone is theirs to move.
    private func dragged(_ meeting: MeetingRecord) -> String? {
        if selection.count > 1, selection.contains(meeting.id) { return DraggedItem.payload(chosen.map { .meeting($0.id) }) }
        return meeting.isTeamCopy ? nil : DraggedItem.meeting(meeting.id).string
    }

    /// Moves them into a folder in `binderID` (nil: its top), each by its own rules, as one change one Undo puts back,
    /// and says what happened.
    private func move(_ moving: [MeetingRecord], toFolder target: UUID?, in binderID: UUID) {
        guard Store.shared.allowsSave() else { return }
        let outcome = MeetingMoves.move(moving, toFolder: target, in: binderID, undoManager: undoManager)
        said(outcome, of: moving, place: FolderPrompts.place(binderID: Store.shared.folder(target)?.binderID ?? binderID, folder: target), into: nil)
    }

    private func move(_ moving: [MeetingRecord], to binder: BinderRecord) {
        guard Store.shared.allowsSave() else { return }
        let outcome = MeetingMoves.move(moving, to: binder, undoManager: undoManager)
        said(outcome, of: moving, place: binder.name, into: binder)
    }

    /// "Moved 4 meetings to Work › DevOps." and why any stayed; for captures put in a shared binder, whether the team has
    /// them now. Those that left this binder leave the selection.
    private func said(_ outcome: MoveOutcome, of moving: [MeetingRecord], place: String, into binder: BinderRecord?) {
        selection = selection.filter { id in here.contains { $0.id == id } }
        let sharing = binder.flatMap { MeetingMoves.captureSharing(outcome.moved, in: $0) }
        let why = [sharing, MeetingMoves.whyStayed(outcome.stayed)].compactMap { $0 }
        guard let line = outcome.line(asked: moving.count, noun: noun, place: place, whyStayed: why.isEmpty ? nil : why.joined(separator: " ")) else { return }
        controller.flowBar.toast(line, symbol: outcome.stayed.isEmpty ? "folder" : BindersTheme.problemSymbol, duration: outcome.stayed.isEmpty ? 4 : 6)
    }

    /// The menu items for several at once, in the list's menu.
    private func severalItems(_ moving: [MeetingRecord]) -> some View {
        SeveralMenuItems(count: moving.count, noun: noun.many.capitalized, binderID: binderID, folderID: sharedFolder(of: moving).folder,
                         together: sharedFolder(of: moving).together,
                         toFolder: { target in if let binderID { move(moving, toFolder: target, in: binderID) } },
                         toBinder: { move(moving, to: $0) }, delete: { requestDelete(moving) })
    }

    /// Beside the list with several selected: how many, what to do with them all, and what stays as it is.
    private func several(_ picked: [MeetingRecord]) -> some View {
        SeveralSelectedPanel(heading: "\(picked.count) \(noun.many) selected", titles: picked.map(\.title), rules: rules(for: picked), probe: "meetings.several") {
            SeveralButtons(count: picked.count, noun: noun.many, binderID: binderID, folderID: sharedFolder(of: picked).folder,
                           together: sharedFolder(of: picked).together,
                           toFolder: { target in if let binderID { move(picked, toFolder: target, in: binderID) } },
                           toBinder: { move(picked, to: $0) }, delete: { requestDelete(picked) })
        }
    }

    /// What some of them keep to, said before you act: a teammate's, one still recording or being written up, and what
    /// moving captures into a shared binder does.
    private func rules(for picked: [MeetingRecord]) -> [String] {
        var rules: [String] = []
        let theirs = picked.filter(\.isTeamCopy).count
        if theirs > 0 {
            rules.append(theirs == 1 ? "1 is a teammate's \(noun.one): only they can move or delete it."
                         : "\(theirs) are teammates' \(noun.many): only they can move or delete them.")
        }
        if picked.contains(where: { MeetingMoves.isRecording($0) }) {
            rules.append("1 is still recording: it stays in this binder, in any folder you choose, and isn't deleted until it stops.")
        }
        let writing = picked.filter { !$0.isTeamCopy && !MeetingMoves.isRecording($0)
            && (service.busyMeetingIDs.contains($0.id) || service.chattingMeetingIDs.contains($0.id)) }.count
        if writing > 0 {
            rules.append(writing == 1 ? "1 is still being written up or asked about: it isn't deleted until that's done."
                         : "\(writing) are still being written up or asked about: they aren't deleted until that's done.")
        }
        if showsConversations, picked.contains(where: { !$0.isTeamCopy }) {
            if Store.shared.binders().contains(where: { $0.sharedWithTeam }) {
                rules.append("Captures stay on this Mac, even in a binder shared with your team.")
            }
        }
        return rules
    }

    // MARK: Deleting

    /// One question for all of them, saying which can come back; when none can go now, why, instead.
    private func requestDelete(_ going: [MeetingRecord]) {
        guard !going.isEmpty, Store.shared.allowsSave() else { return }
        guard going.contains(where: { MeetingDeletes.staysPut($0, service: service) == nil }) else {
            NSSound.beep()
            if let why = MeetingDeletes.whyStaying(going, service: service) { controller.flowBar.toast(why, symbol: BindersTheme.problemSymbol, duration: 5) }
            return
        }
        toDelete = going
    }

    /// Each by its own rule (MeetingDeletes): one shared with the team goes for everyone; the rest together, which one Undo
    /// puts back. What can't go now stays, and says why.
    private func delete(_ going: [MeetingRecord]) {
        let leaving = Set(going.filter { MeetingDeletes.staysPut($0, service: service) == nil }.map(\.id))
        if !selection.isDisjoint(with: leaving) {
            // Several: the one beside them opens, as in the notes list. One: none, as it always was.
            selection = going.count > 1 ? (neighbour(of: leaving).map { [$0.id] } ?? []) : []
        }
        let staying = MeetingDeletes.delete(going, service: service, team: team, undoManager: undoManager)
        if let why = MeetingDeletes.whyStaying(staying, service: service) { controller.flowBar.toast(why, symbol: BindersTheme.problemSymbol, duration: 5) }
    }

    /// The one below these in the list, or above them at the end.
    private func neighbour(of ids: Set<UUID>) -> MeetingRecord? {
        let list = OutlineEntry.items(in: entries(filtered))
        guard let last = list.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        if let below = list[(last + 1)...].first(where: { !ids.contains($0.id) }) { return below }
        return list[..<last].last { !ids.contains($0.id) }
    }

    /// One asks as its own menu does; several: "Delete 4 meetings?", counting those that can go now.
    private func deleteTitle(_ going: [MeetingRecord]) -> String {
        if going.count == 1, let one = going.first { return MeetingDeletes.question(one, team: team) }
        let leaving = going.filter { MeetingDeletes.staysPut($0, service: service) == nil }.count
        return "Delete \(leaving) \(leaving == 1 ? noun.one : noun.many)?"
    }

    /// "Delete", "Delete 4 Meetings", "Delete 4 Meetings, 2 for the Team", "Delete 4 Meetings for the Team".
    private func deleteButton(_ going: [MeetingRecord]) -> String {
        guard going.count > 1 else { return "Delete" }
        let leaving = going.filter { MeetingDeletes.staysPut($0, service: service) == nil }
        let shared = leaving.filter { MeetingDeletes.isShared($0, team: team) }.count
        let what = "Delete \(leaving.count) \((leaving.count == 1 ? noun.one : noun.many).capitalized)"
        if shared == 0 { return what }
        return shared == leaving.count ? what + " for the Team" : what + ", \(shared) for the Team"
    }

    /// Which stay and why, which go for the team too (that can't be undone), and which Undo puts back.
    private func deleteMessage(_ going: [MeetingRecord]) -> String {
        let leaving = going.filter { MeetingDeletes.staysPut($0, service: service) == nil }
        let shared = leaving.filter { MeetingDeletes.isShared($0, team: team) }.count
        let mine = leaving.count - shared
        var parts: [String] = []
        if let why = MeetingDeletes.whyStaying(going.filter { MeetingDeletes.staysPut($0, service: service) != nil }, service: service) {
            parts.append(why + " The rest go.")
        }
        if shared > 0 {
            if leaving.count == 1 {
                parts.append("This can't be undone.")
            } else {
                let them = shared == leaving.count ? "They're shared with your team" : shared == 1 ? "1 of them is shared with your team" : "\(shared) of them are shared with your team"
                parts.append(them + ": " + (shared == 1 && shared != leaving.count ? "it's" : "they're") + " removed for the team too, which can't be undone.")
            }
        }
        if mine > 0 {
            parts.append(shared == 0 ? (leaving.count == 1 ? "Undo puts it back." : "Undo puts them back.")
                         : mine == 1 ? "Undo puts the other one back." : "Undo puts the other \(mine) back.")
        }
        return parts.joined(separator: " ")
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let busy: Bool
    let recording: Bool
    let showsSharing: Bool
    /// Where it is, while the list shows no folders.
    var place: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).lineLimit(2)
            OutlinePlace(names: place)
            HStack(spacing: 6) {
                Text(meeting.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                if meeting.duration > 0 { Text("· \(max(1, Int((meeting.duration / 60).rounded()))) min") }
            }
            .font(BindersTheme.time())
            .foregroundStyle(.secondary)
            if meeting.isTeamCopy {
                Label(meeting.teamAuthorName ?? "Teammate", systemImage: "person.2.fill").font(.caption).foregroundStyle(.secondary)
            } else if showsSharing, meeting.sharedWithTeam {
                Label("Shared", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
            }
            if recording {
                Badge(text: "Recording", symbol: "record.circle", color: BindersTheme.live)
            } else if busy {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Writing notes…").font(.caption2).foregroundStyle(.secondary)
                }
            } else if meeting.status == "failed" {
                Badge(text: "Failed", symbol: BindersTheme.problemSymbol, color: BindersTheme.ink)
            }
        }
        .padding(.vertical, 3)
    }
}

struct MeetingDetailView: View {
    enum DetailTab: String, CaseIterable {
        case summary = "Summary", notes = "My notes", transcript = "Transcript", ask = "Ask"
    }

    @Environment(MeetingService.self) private var service
    @Environment(TeamSyncService.self) private var team
    @Environment(\.undoManager) private var undoManager
    @ReducedMotion private var reduceMotion
    @Bindable var meeting: MeetingRecord
    let onDelete: () -> Void
    @State private var tab: DetailTab = .summary
    @State private var segments: [TranscriptSegment] = []
    @State private var question = ""
    @State private var confirmDelete = false
    @State private var copied = false
    @State private var rescuing = false
    @State private var editingSummary = false

    init(meeting: MeetingRecord, onDelete: @escaping () -> Void, initialTab: DetailTab = .summary) {
        _meeting = Bindable(meeting)
        self.onDelete = onDelete
        _tab = State(initialValue: initialTab)
    }

    private var isRecording: Bool { service.recordingMeetingID == meeting.id }
    private var isBusy: Bool { service.busyMeetingIDs.contains(meeting.id) }
    private var shownSegments: [TranscriptSegment] { isRecording ? service.liveSegments : segments }
    private var canEditSummary: Bool { !meeting.isTeamCopy && !isRecording && !isBusy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if meeting.isTeamCopy {
                    Text(meeting.title).font(BindersTheme.title(26)).textSelection(.enabled)
                } else {
                    TextField("Title", text: $meeting.title)
                        .textFieldStyle(.plain)
                        .font(BindersTheme.title(26))
                        .renamesLinks(of: meeting.title)
                }
                // When and where on one line while they fit; short of room, where goes under when, truncated in the middle.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        Text(metaLine).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        place
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metaLine).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                        place.lineLimit(1).truncationMode(.middle)
                    }
                }
                if !meeting.attendees.isEmpty {
                    Text("With " + meeting.attendees.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
                if let error = meeting.errorMessage {
                    StatusLabel(error, .problem).font(.callout)
                }
                if meeting.isConversation, !meeting.soloJSON.isEmpty {
                    CaptureFoundView(meeting: meeting)
                }
                if meeting.isConversation, meeting.suggestions.contains(where: { $0.status == .offered }) {
                    ConversationSuggestionsView(meeting: meeting)
                }
                if meeting.status == "trivial" {
                    HStack(spacing: 10) {
                        Label("Binders took this for small talk and hid it. It's deleted a week after it was heard.", systemImage: "eye.slash")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Keep It") { Task { await service.conversations?.keep(meeting) } }
                            .controlSize(.small)
                    }
                }
                if let activity = service.activity[meeting.id] {
                    Label(activity, systemImage: isBusy ? "hourglass" : "info.circle").font(.callout).foregroundStyle(.secondary)
                }
            }

            // The tabs and what to do, on one row while they fit; short of room, the buttons show their icons, then go
            // under the tabs, then the tabs become a menu.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    tabs(segmented: true)
                    Spacer()
                    actions(words: true)
                }
                HStack(spacing: 10) {
                    tabs(segmented: true)
                    Spacer()
                    actions(words: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    tabs(segmented: true)
                    HStack(spacing: 10) {
                        Spacer()
                        actions(words: false)
                    }
                }
                HStack(spacing: 10) {
                    tabs(segmented: false)
                    Spacer(minLength: 0)
                    actions(words: false)
                }
            }

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .task(id: "\(meeting.id)|\(meeting.status)|\(isBusy)") {
            segments = Store.shared.segments(for: meeting.id)
            // A teammate's meeting being recorded on their Mac (lane DB4): its lines come in as they're written.
            while meeting.isTeamCopy, meeting.status == "recording", !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let now = Store.shared.segments(for: meeting.id)
                if now.map(\.id) != segments.map(\.id) { segments = now }
            }
        }
        .confirmationDialog(MeetingDeletes.question(meeting, team: team), isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        } message: {
            // One shared with the team goes for everyone; your own comes back with Undo (MeetingTrash).
            Text(MeetingDeletes.isShared(meeting, team: team) ? "This can't be undone." : "Undo puts it back.")
        }
        .sheet(isPresented: $rescuing) { MicRescueSheet(meeting: meeting) }
    }

    /// Which binder and folder it's in, and whether the team sees it.
    @ViewBuilder
    private var place: some View {
        if meeting.isTeamCopy {
            Label("Shared by \(meeting.teamAuthorName ?? "a teammate") · read-only", systemImage: "person.2")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let binder = Store.shared.binder(meeting.binderID), meeting.isConversation {
            let path = ([binder.name] + Store.shared.folderNames(Store.shared.shownFolder(meeting.folderID, in: binder.id))).joined(separator: " › ")
            Label(binder.sharedWithTeam ? "In \(path) · not shared" : "In \(path)", systemImage: "books.vertical")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help((meeting.routingReason.map { "Filed here: \($0). " } ?? "") + "Captures stay on this Mac, even in a shared binder.")
        } else if let binder = Store.shared.binder(meeting.binderID) {
            let path = ([binder.name] + Store.shared.folderNames(Store.shared.shownFolder(meeting.folderID, in: binder.id))).joined(separator: " › ")
            let shared = binder.sharedWithTeam
            Label(shared ? "In \(path) · shared with the team" : "In \(path)",
                  systemImage: shared ? "person.2" : "books.vertical")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Sharing follows the binder. Move the meeting to change it.")
        }
    }

    /// Summary, My notes, Transcript and Ask: side by side, or a menu when there's no room for that.
    @ViewBuilder
    private func tabs(segmented: Bool) -> some View {
        let picker = Picker("", selection: $tab) {
            ForEach(DetailTab.allCases, id: \.self) { Text($0 == .notes && meeting.isTeamCopy ? "Notes" : $0.rawValue).tag($0) }
        }
        .labelsHidden()
        if segmented {
            picker
                .pickerStyle(.segmented)
                // Its natural width, not a range: the segmented control underneath never draws narrower than its
                // labels, so a `.frame(maxWidth:)` let SwiftUI count it as shrinkable and report a window minimum
                // ~40pt too small. At that minimum the page overflowed and was centred, clipping both edges.
                .fixedSize()
                .fitProbe("meeting.tabs.first")
        } else {
            picker
                .pickerStyle(.menu)
                .fixedSize()
                .fitProbe("meeting.tabs.first")
        }
    }

    /// Regenerate, Copy and the rest, in ⋯: with their words, or as icons (their words kept for the help and VoiceOver).
    @ViewBuilder
    private func actions(words: Bool) -> some View {
        if meeting.isConversation {
            Button {
                Task { await service.summarize(meeting, templateID: MeetingTemplate.conversation.id) }
            } label: {
                if words { Label("Regenerate", systemImage: "arrow.clockwise") } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Write the notes again from the transcript")
            .accessibilityLabel("Regenerate")
            .fixedSize()
            .disabled(isBusy || editingSummary || shownSegments.isEmpty || meeting.status == "trivial")
        } else {
            Menu {
                ForEach(MeetingTemplate.all) { template in
                    Button {
                        Task { await service.summarize(meeting, templateID: template.id) }
                    } label: {
                        if template.id == meeting.templateID {
                            Label(template.name, systemImage: "checkmark")
                        } else {
                            Text(template.name)
                        }
                    }
                }
            } label: {
                if words { Label("Regenerate", systemImage: "arrow.clockwise") } else { Image(systemName: "arrow.clockwise") }
            }
            .help("Write the notes again from the transcript, with a template")
            .accessibilityLabel("Regenerate")
            .fixedSize(horizontal: true, vertical: false)
            .disabled(isBusy || isRecording || editingSummary || shownSegments.isEmpty || meeting.isTeamCopy)
        }
        Button {
            TextInserter.copyToClipboard(service.markdown(for: meeting))
            copied = true
        } label: {
            if words {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            } else {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
        }
        .help(copied ? "Copied" : "Copy the notes as Markdown")
        .accessibilityLabel(copied ? "Copied" : "Copy")
        .fixedSize()
        moreMenu
            .fitProbe("meeting.tabs.last")
    }

    /// ⋯: exporting, the audio, the mic track, sharing a capture, moving, deleting.
    private var moreMenu: some View {
        Menu {
            Button("Export Markdown…") { service.export(meeting) }
            let audio = meeting.audioURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !audio.isEmpty {
                Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting(audio) }
            }
            if !meeting.isTeamCopy, !meeting.isConversation {
                Button("Replace My Mic Track…") { rescuing = true }
                    .disabled(isRecording || isBusy)
            }
            if !meeting.isTeamCopy {
                // As several do (MeetingMoves): with Undo.
                Menu("Move to Binder") {
                    MoveToBinderItems(current: meeting.binderID) { binder in
                        MeetingMoves.move([meeting], to: binder, undoManager: undoManager)
                    }
                }
                .disabled(isRecording)
                if let binderID = meeting.binderID {
                    Menu("Move to Folder") {
                        MoveToFolderItems(binderID: binderID, current: Store.shared.shownFolder(meeting.folderID, in: binderID)) { target in
                            MeetingMoves.move([meeting], toFolder: target, in: binderID, undoManager: undoManager)
                        }
                    }
                }
            }
            Divider()
            if meeting.isTeamCopy {
                Button("Only \(meeting.teamAuthorName ?? "the author") can delete this meeting") {}
                    .disabled(true)
            } else {
                Button("Delete \(meeting.kindName)", role: .destructive) { confirmDelete = true }
                    .disabled(isRecording || isBusy || service.chattingMeetingIDs.contains(meeting.id))
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
        .help("More: export, move, delete")
        .accessibilityLabel("More")
    }

    private var metaLine: String {
        var parts = [meeting.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if meeting.isConversation, let ended = meeting.endedAt {
            parts[0] += "–" + ended.formatted(date: .omitted, time: .shortened)
        }
        if meeting.duration > 0 { parts.append("\(max(1, Int((meeting.duration / 60).rounded()))) min") }
        if let app = meeting.appName { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .summary: summaryView
        case .notes:
            if meeting.isTeamCopy {
                ScrollView {
                    Text(meeting.userNotes.trimmed.isEmpty ? "No notes." : meeting.userNotes)
                        .font(.system(size: 14))
                        .foregroundStyle(meeting.userNotes.trimmed.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                MarkdownNoteEditor(text: $meeting.userNotes, fontSize: 14, inset: NSSize(width: 4, height: 8), compactToolbar: true,
                                   links: LinkTargets.forEditor(in: meeting.binderID))
            }
        case .transcript: transcriptView
        case .ask: askView
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        if isRecording {
            ContentUnavailableView("Recording", systemImage: "record.circle",
                                   description: Text("Notes are written when the meeting ends. Add your own notes to steer them."))
        } else if isBusy, meeting.summary.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text(service.activity[meeting.id] ?? "Transcribing, labeling speakers and writing notes…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if meeting.summary.isEmpty {
            ContentUnavailableView {
                Label("No notes yet", systemImage: "text.alignleft")
            } description: {
                Text(shownSegments.isEmpty ? "Nothing was transcribed." : "Generate notes from the transcript.")
            } actions: {
                if !shownSegments.isEmpty, !meeting.isTeamCopy {
                    Button("Write Notes") { Task { await service.summarize(meeting) } }
                }
            }
        } else if editingSummary {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Editing the notes as Markdown. Tasks are lines like `- [ ] Owner — task`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { editingSummary = false }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("⌘↩")
                }
                MarkdownNoteEditor(text: $meeting.summary, fontSize: 14, inset: NSSize(width: 4, height: 8), compactToolbar: true,
                                   links: LinkTargets.forEditor(in: meeting.binderID))
            }
        } else {
            ScrollView {
                // A teammate's "You" is them, not you.
                MarkdownBlocks(markdown: meeting.isTeamCopy ? TeamSyncService.shown(meeting.summary, by: meeting.teamAuthorName) : meeting.summary,
                               foldable: true, onToggleTask: canEditSummary ? { line in
                    meeting.summary = NotesEditing.toggleCheckbox(in: meeting.summary, line: line)
                } : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .padding(.top, canEditSummary ? 26 : 0)
                // Notes that link to this meeting, or name it.
                Divider().padding(.vertical, 12)
                MentionsPanel(title: meeting.title, excluding: meeting.id)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 8)
            }
            .overlay(alignment: .topTrailing) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else if canEditSummary {
                    Button { editingSummary = true } label: { Label("Edit", systemImage: "pencil") }
                        .controlSize(.small)
                        .help("Edit the notes: fix owners, delete items, add your own")
                }
            }
        }
    }

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 10) {
            let labels = Array(Set(shownSegments.map(\.speaker)).subtracting([TranscriptSegment.you])).sorted()
            if !labels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        Text("Speakers").font(.caption).foregroundStyle(.secondary)
                        ForEach(labels, id: \.self) { label in
                            HStack(spacing: 4) {
                                Circle().fill(SpeakerColor.style(for: meeting.speakerNames[label] ?? label)).frame(width: 7, height: 7)
                                TextField(label, text: Binding(
                                    get: { meeting.speakerNames[label] ?? "" },
                                    set: { newValue in
                                        var names = meeting.speakerNames
                                        names[label] = newValue
                                        meeting.speakerNames = names
                                    }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 130)
                                    .disabled(meeting.isTeamCopy)
                            }
                        }
                    }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let blocks = TranscriptFormatter.blocks(shownSegments, names: meeting.speakerNames)
                    if blocks.isEmpty {
                        Text(isBusy ? "Transcribing…" : "No transcript.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        TranscriptBlockRow(block: block)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var askView: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if meeting.chat.isEmpty {
                            Text("Ask anything about this meeting").font(.caption).foregroundStyle(.secondary)
                            ForEach(["What are the action items and who owns them?", "Draft a follow-up email",
                                     "What did I commit to?", "What decisions were made?"], id: \.self) { suggestion in
                                Button(suggestion) {
                                    question = suggestion
                                    send()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        ForEach(Array(meeting.chat.enumerated()), id: \.offset) { index, message in
                            ChatBubble(message: message).id(index)
                        }
                        if service.chattingMeetingIDs.contains(meeting.id) {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: meeting.chat.count) {
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(meeting.chat.count - 1, anchor: .bottom) }
                }
            }
            HStack {
                TextField("Ask about this meeting…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Ask", action: send)
                    .disabled(question.trimmed.isEmpty || service.chattingMeetingIDs.contains(meeting.id))
            }
        }
    }

    private func send() {
        let text = question.trimmed
        guard !text.isEmpty else { return }
        question = ""
        Task { await service.ask(text, about: meeting) }
    }
}

private struct ChatBubble: View {
    let message: MeetingRecord.ChatMessage

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.infoFill(0.16)))
            }
        } else {
            MarkdownBlocks(markdown: message.text)
                .padding(.trailing, 40)
        }
    }
}

/// Renders the Markdown subset the notes use: headings, bullets, checkboxes and inline emphasis.
struct MarkdownBlocks: View {
    let markdown: String
    /// Sections ("## " headings) get a chevron that folds them away.
    var foldable = false
    /// When set, task checkboxes become clickable and report the line index they belong to.
    var onToggleTask: ((Int) -> Void)? = nil
    @State private var folded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.visibleLines(markdown, folded: foldable ? folded : []), id: \.index) { item in
                row(item.line, index: item.index)
            }
        }
        .textSelection(.enabled)
    }

    /// Every line with its index, less the ones under a folded section ("## " heading, by line index).
    static func visibleLines(_ markdown: String, folded: Set<Int>) -> [(index: Int, line: String)] {
        var hiding = false
        return markdown.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                hiding = trimmed.hasPrefix("## ") && folded.contains(index)
                return (index, line)
            }
            return hiding ? nil : (index, line)
        }
    }

    @ViewBuilder
    private func row(_ raw: String, index: Int) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Spacer().frame(height: 2)
        } else if line.hasPrefix("### ") {
            inline(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
        } else if line.hasPrefix("## ") {
            if foldable {
                Button {
                    if folded.contains(index) { folded.remove(index) } else { folded.insert(index) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: folded.contains(index) ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                        inline(String(line.dropFirst(3))).font(.title3.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(folded.contains(index) ? "Show this section" : "Fold this section away")
                .padding(.top, 8)
            } else {
                inline(String(line.dropFirst(3))).font(.title3.weight(.semibold)).padding(.top, 8)
            }
        } else if line.hasPrefix("# ") {
            inline(String(line.dropFirst(2))).font(.title2.weight(.bold)).padding(.top, 8)
        } else if NotesEditing.isTask(line) {
            let checked = NotesEditing.isChecked(line)
            let text = String(line.drop { $0 != "]" }.dropFirst()).trimmingCharacters(in: .whitespaces)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let onToggleTask {
                    // A ticked to-do is done: green.
                    Button { onToggleTask(index) } label: {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(checked ? AnyShapeStyle(BindersTheme.done) : AnyShapeStyle(.secondary))
                    .help(checked ? "Mark as not done" : "Mark as done")
                } else {
                    Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
                }
                inlineText(text)
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, indent(raw))
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(String(line.dropFirst(2)))
            }
            .padding(.leading, indent(raw))
        } else {
            inline(line)
        }
    }

    private func indent(_ raw: String) -> CGFloat {
        CGFloat(raw.prefix(while: { $0 == " " }).count / 2) * 16
    }

    private func inline(_ text: String) -> some View {
        // Wrap instead of truncating to one line when the parent doesn't size vertically.
        inlineText(text).fixedSize(horizontal: false, vertical: true)
    }

    private func inlineText(_ text: String) -> Text {
        let attributed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(attributed)
    }
}

/// Swaps the mic track for another recording of the user (a conference speaker, a phone) and rewrites the notes.
private struct MicRescueSheet: View {
    @Environment(MeetingService.self) private var service
    @Environment(\.dismiss) private var dismiss
    let meeting: MeetingRecord
    @State private var fileURL: URL?
    @State private var choosing = false
    @State private var offsetText = ""

    private var offset: Double? { Double(offsetText.trimmed.replacingOccurrences(of: ",", with: ".")) }
    private var offsetInvalid: Bool { !offsetText.trimmed.isEmpty && offset == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Replace my mic track").font(.system(size: 17, weight: .heavy, design: .rounded))
            Text("Use another recording of yourself from this meeting, such as a conference speaker or a phone. Binders lines it up with what it recorded, transcribes your side again and rewrites the notes. The other side's transcript is kept.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose Recording…") { choosing = true }
                Text(fileURL?.lastPathComponent ?? "No file chosen").foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Offset")
                TextField("auto", text: $offsetText).textFieldStyle(.roundedBorder).frame(width: 80)
                Text("seconds into the recording where the meeting starts; leave blank to detect it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace") {
                    guard let fileURL else { return }
                    let offset = offset
                    Task {
                        let scoped = fileURL.startAccessingSecurityScopedResource()
                        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
                        await service.replaceMicTrack(meeting, with: fileURL, offset: offset)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(fileURL == nil || offsetInvalid)
            }
        }
        .padding(24)
        .frame(width: 520)
        .pageGround()
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { fileURL = url }
        }
    }
}

/// What a conversation brought up: cards to put on a board, ideas for its Backlog, answers from your binders. Yes, no,
/// later, or Give to an agent. They wait on you, so amber.
/// Lane Y2: a capture in which your iPhone heard only you, read for what you said: each thing it found or that went with
/// it, with what became of it and Open Card, Stop, Undo and Give to; Stop All; and where Not Only Me is. For one from a
/// Auto iPhone that wasn't read, why. Plain, not amber, and no sparkle: nothing here is an agent's doing yet.
private struct CaptureFoundView: View {
    @Environment(MeetingService.self) private var service
    @Bindable var meeting: MeetingRecord
    @State private var message: String?
    @State private var registry = AgentRegistry.shared
    @State private var tick = 0

    private var vouch: SoloVouch? { SoloVouch.decode(meeting.soloJSON) }
    private var moments: MomentService? { service.conversations?.controller?.moments }

    var body: some View {
        if let vouch, [MomentMode.add, .auto].contains(vouch.heardMode) {
            VStack(alignment: .leading, spacing: 8) {
                let found = moments?.found(in: meeting.id) ?? []
                if vouch.vouched, vouch.reply == SoloPrompts.State.items.rawValue || !found.isEmpty {
                    Text(AutoText.macSection(mode: vouch.heardMode)).font(.callout.weight(.semibold))
                    ForEach(found, id: \.id) { entry in row(entry.id, said: entry.state.said) }
                    Text(AutoText.notOnlyMeOnPhone).font(.caption).foregroundStyle(.secondary)
                    if found.filter({ moments?.outcome($0.id)?.handedOver != nil }).count >= 2 {
                        HStack {
                            Spacer()
                            Button("Stop All") {
                                Task {
                                    message = await service.conversations?.act(on: meeting.id, action: "stop-all")?.message
                                    tick += 1
                                }
                            }
                        }
                    }
                } else if vouch.heardMode == .auto, let why = vouch.why {
                    StatusLabel(AutoText.macUnread(why: why), .problem).font(.callout)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .controlSize(.small)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            .id(tick)
        }
    }

    @ViewBuilder
    private func row(_ id: UUID, said: String) -> some View {
        let outcome = moments?.outcome(id)
        let handed = outcome?.handedOver != nil
        let waits = outcome?.waiting != nil
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: handed ? "arrowshape.turn.up.right" : outcome?.state == "acted" ? "checkmark" : "circle")
                .foregroundStyle(handed ? BindersTheme.accentText : Color.primary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome?.line ?? "").foregroundStyle(waits ? BindersTheme.needsYou : Color.primary)
                Text("“\(SoloReading.cardWords(said))”").font(BindersTheme.quote(.callout)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let card = outcome?.card.flatMap(UUID.init(uuidString:)).flatMap({ service.conversations?.controller?.board.card($0) }) {
                Button("Open Card") { CardWindows.shared.open(card, controller: service.conversations?.controller) }
            }
            if outcome?.actions?.contains("stop") == true {
                Button("Stop") { act(id, "stop") }
            }
            if outcome?.actions?.contains("undo") == true {
                Button("Undo") { act(id, "undo") }
            }
            if outcome?.actions?.contains("assign") == true, let agent = outcome?.agent, registry.agent(named: agent) != nil {
                Button(LockScreenText.giveTo(agent)) { act(id, "assign", agent: agent) }
            }
        }
    }

    private func act(_ id: UUID, _ action: String, agent: String? = nil) {
        message = moments?.act(on: id, action: action, agent: agent)?.message
        tick += 1
    }
}

private struct ConversationSuggestionsView: View {
    @Environment(MeetingService.self) private var service
    @Bindable var meeting: MeetingRecord
    @State private var message: String?
    @State private var registry = AgentRegistry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(meeting.suggestions.filter { $0.status == .offered }) { suggestion in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: suggestion.kind == .answer ? "questionmark.bubble" : suggestion.kind == .idea ? "lightbulb" : "rectangle.split.3x1")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        if suggestion.kind == .card {
                            Text("Put “\(suggestion.text)” on the \(suggestion.binder) board?")
                        } else if suggestion.kind == .idea {
                            Text("An idea for the \(suggestion.binder) board: “\(suggestion.text)”. Put it in Backlog?")
                        } else {
                            // Your own question, quoted.
                            (Text("You asked: ").font(.callout.weight(.semibold)) + Text(suggestion.text).font(BindersTheme.quote(.callout)))
                            Text(suggestion.answer ?? "").textSelection(.enabled)
                            if !suggestion.sources.isEmpty {
                                Text("From " + suggestion.sources.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if suggestion.kind != .answer {
                        Button("Add to Board") { message = service.conversations?.accept(suggestion.id).message }
                        giveMenu(suggestion)
                        Button("Not Now") { service.conversations?.dismiss(suggestion.id) }
                    } else {
                        Button("Got It") { service.conversations?.accept(suggestion.id) }
                    }
                }
                .controlSize(.small)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(BindersTheme.needsYou.opacity(0.08)))
    }

    /// Give to: the agents that take this binder's cards. The card lands in Ready, meant for the one you pick, and Binders
    /// hands it over at once.
    @ViewBuilder
    private func giveMenu(_ suggestion: ConversationSuggestion) -> some View {
        let agents = registry.agents.filter { $0.isEnabled && $0.takesCards(from: meeting.binderID) }
        if !agents.isEmpty {
            Menu("Give to") {
                ForEach(agents) { agent in
                    Button(agent.name) { message = service.conversations?.give(suggestion.id, to: agent.name).message }
                }
            }
            .fixedSize()
            .help(registry.paused ? "Agents are paused: it waits in Ready until you resume them" : "It goes to Ready, and Binders hands it over")
        }
    }
}
