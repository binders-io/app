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
            panel.setFrameAutosaveName("BindersMeetingNotes")
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
                PulsingDot()
                TextField("Title", text: $meeting.title)
                    .textFieldStyle(.plain)
                    .font(.headline)
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
                .tint(.red)
                .controlSize(.small)
            }
            if let issue = service.systemAudioIssue {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Only your microphone is being recorded. \(issue)").font(.caption)
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
    }
}

struct LiveTranscriptView: View {
    let segments: [TranscriptSegment]
    let names: [String: String]

    var body: some View {
        let blocks = TranscriptFormatter.blocks(segments, names: names)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if blocks.isEmpty {
                        Text("Listening… lines appear after each pause.").foregroundStyle(.secondary)
                    } else {
                        TranscriptText.render(blocks)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .id("transcript")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: blocks.count) {
                guard !blocks.isEmpty else { return }
                withAnimation { proxy.scrollTo("transcript", anchor: .bottom) }
            }
        }
    }
}

/// Renders a transcript as one concatenated Text spanning every speaker turn, instead of one View per block: the
/// same reasoning as `MeetingDetailView.threadText` for the Ask tab applies here, and the same way — a real
/// drag or Cmd-A/Cmd-C across several speakers' lines needs this to be a single Text, not several selectable rows.
enum TranscriptText {
    static func render(_ blocks: [TranscriptBlock]) -> Text {
        blocks.enumerated().reduce(Text("")) { combined, item in
            let (index, block) = item
            let separator = index == 0 ? Text("") : Text("\n\n")
            let speaker = Text(block.speaker).font(.caption.weight(.semibold)).foregroundStyle(SpeakerColor.color(for: block.speaker))
            let timestamp = Text("  " + TranscriptFormatter.timestamp(block.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            let line = speaker + timestamp + Text("\n") + Text(block.text)
            return combined + separator + line
        }
    }
}

struct PulsingDot: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(0.55 + 0.45 * abs(sin(phase * 2)))
        }
        .frame(width: 8, height: 8)
    }
}

enum SpeakerColor {
    static func color(for speaker: String) -> Color {
        if speaker == TranscriptSegment.you { return .accentColor }
        let palette: [Color] = [.orange, .green, .pink, .teal, .purple, .brown, .indigo, .mint]
        let hash = speaker.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return palette[hash % palette.count]
    }
}

// MARK: - Hub: Meetings

struct MeetingsView: View {
    @Environment(MeetingService.self) private var service
    @Environment(HubNavigation.self) private var navigation
    @Environment(AppSettings.self) private var settings
    @Query private var meetings: [MeetingRecord]
    @State private var selection: UUID?
    @State private var search = ""
    @State private var importing = false
    /// Conversations kept out of sight as small talk, shown on request for a week before they go.
    @State private var showsTrivial = false
    let binderID: UUID?
    /// The iPhone's conversations instead of meetings.
    let showsConversations: Bool

    /// The meetings in one binder, or every meeting when `binderID` is nil; or the conversations the iPhone heard.
    init(binderID: UUID? = nil, conversations: Bool = false) {
        self.binderID = binderID
        showsConversations = conversations
        let kind = conversations ? MeetingRecord.conversationKind : "meeting"
        if let binderID {
            _meetings = Query(filter: #Predicate<MeetingRecord> { $0.binderID == binderID && $0.kind == kind },
                              sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
        } else {
            _meetings = Query(filter: #Predicate<MeetingRecord> { $0.kind == kind }, sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
        }
    }

    private var shown: [MeetingRecord] { showsTrivial ? meetings : meetings.filter { $0.status != "trivial" } }
    private var trivialCount: Int { meetings.filter { $0.status == "trivial" }.count }

    private var filtered: [MeetingRecord] {
        let query = search.trimmed
        guard !query.isEmpty else { return shown }
        return shown.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.userNotes.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if showsConversations {
                    Text("Captures").font(BindersTheme.columnTitle)
                    Text("Heard by Binders on your iPhone during the day. Only the text came to this Mac, and it stays here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { importing = true } label: {
                        Label("Open a Binders File…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Captures your iPhone shared by AirDrop or saved to Files. A capture already here isn't kept twice.")
                    if trivialCount > 0 || showsTrivial {
                        Toggle("Show small talk (\(trivialCount))", isOn: $showsTrivial)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("Captures with nothing worth keeping are hidden, and deleted a week after they were heard.")
                    }
                } else {
                    Text("Meetings").font(BindersTheme.columnTitle)
                    Button {
                        Task {
                            await service.toggle()
                            if let id = service.recordingMeetingID { selection = id }
                        }
                    } label: {
                        Label(service.isRecording ? "Stop recording" : "Record meeting",
                              systemImage: service.isRecording ? "stop.fill" : "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(service.isRecording ? .red : .accentColor)
                    .controlSize(.large)
                    Button { importing = true } label: {
                        Label("Import Recording…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .help("Transcribe an audio or video file into a new meeting. You can also drop a file anywhere on this page.")
                }
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                List(filtered, selection: $selection) { meeting in
                    MeetingRow(meeting: meeting, busy: service.busyMeetingIDs.contains(meeting.id),
                               recording: service.recordingMeetingID == meeting.id, showsSharing: settings.teamFolderPath != nil)
                        .tag(meeting.id)
                }
                .listStyle(.inset)
            }
            .padding(.top, 24)
            .padding(.horizontal, 12)
            .frame(width: 290)

            Divider()

            if let meeting = meetings.first(where: { $0.id == selection }) {
                MeetingDetailView(meeting: meeting) {
                    selection = nil
                    DispatchQueue.main.async { Store.shared.deleteMeeting(meeting) }
                }
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
        .fileImporter(isPresented: $importing, allowedContentTypes: showsConversations ? [UTType(exportedAs: BindersTransfer.typeIdentifier)] : [.audio, .movie],
                      allowsMultipleSelection: showsConversations) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            if showsConversations {
                if let controller = HubWindowController.shared.controller { urls.forEach { BindersFiles.open($0, controller: controller) } }
                return
            }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let record = await service.importRecording(url) { selection = record.id }
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
                    if let record = await service.importRecording(url) { selection = record.id }
                }
            }
            return true
        }
        .onAppear {
            if !takePending(), selection == nil {
                selection = showsConversations ? shown.first?.id : (service.recordingMeetingID ?? meetings.first?.id)
            }
        }
        .onChange(of: navigation.pendingMeetingID) { _ = takePending() }
        .onReceive(NotificationCenter.default.publisher(for: TeamSyncService.itemsWillBeRemoved)) { notification in
            // A teammate stopped sharing the open meeting: close it before sync deletes it.
            if let ids = notification.userInfo?["ids"] as? Set<UUID>, let selection, ids.contains(selection) { self.selection = nil }
        }
        .onChange(of: meetings.map(\.id)) {
            // A meeting discarded after processing (nothing was said) disappears from under the selection.
            if let selection, !meetings.contains(where: { $0.id == selection }) { self.selection = nil }
        }
    }

    /// Opens the meeting or conversation something asked for, when it's one of this list's; the other list takes the rest.
    private func takePending() -> Bool {
        guard let pending = navigation.pendingMeetingID else { return false }
        guard let record = meetings.first(where: { $0.id == pending }) else {
            // Asked for before the record arrived (just recorded): meetings take it, as they always have.
            if !showsConversations, Store.shared.binderID(ofMeeting: pending) == nil {
                selection = pending
                navigation.pendingMeetingID = nil
                return true
            }
            return false
        }
        if record.status == "trivial" { showsTrivial = true }
        selection = pending
        navigation.pendingMeetingID = nil
        return true
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord
    let busy: Bool
    let recording: Bool
    let showsSharing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).lineLimit(2)
            HStack(spacing: 6) {
                Text(meeting.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                if meeting.duration > 0 { Text("· \(max(1, Int((meeting.duration / 60).rounded()))) min") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if meeting.isTeamCopy {
                Label(meeting.teamAuthorName ?? "Teammate", systemImage: "person.2.fill").font(.caption).foregroundStyle(.blue)
            } else if showsSharing, meeting.sharedWithTeam {
                Label("Shared", systemImage: "person.2").font(.caption).foregroundStyle(.teal)
            }
            if recording {
                Badge(text: "Recording", color: .red)
            } else if busy {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Writing notes…").font(.caption2).foregroundStyle(.secondary)
                }
            } else if meeting.status == "failed" {
                Badge(text: "Failed", color: .red)
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
                    Text(meeting.title).font(.title.weight(.bold)).textSelection(.enabled)
                } else {
                    TextField("Title", text: $meeting.title)
                        .textFieldStyle(.plain)
                        .font(.title.weight(.bold))
                        .renamesLinks(of: meeting.title)
                }
                HStack(spacing: 10) {
                    Text(metaLine).foregroundStyle(.secondary)
                    Spacer()
                    if meeting.isTeamCopy {
                        Label("Shared by \(meeting.teamAuthorName ?? "a teammate") · read-only", systemImage: "person.2")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let binder = Store.shared.binder(meeting.binderID), meeting.isConversation {
                        Label(binder.sharedWithTeam ? "In \(binder.name) · not shared" : "In \(binder.name)", systemImage: "books.vertical")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help((meeting.routingReason.map { "Filed here: \($0). " } ?? "") + "Captures stay on this Mac, even in a shared binder.")
                    } else if let binder = Store.shared.binder(meeting.binderID) {
                        Label(binder.sharedWithTeam ? "In \(binder.name) · shared with the team" : "In \(binder.name)",
                              systemImage: binder.sharedWithTeam ? "person.2" : "books.vertical")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .help("Sharing follows the binder. Move the meeting to change it.")
                    }
                }
                if !meeting.attendees.isEmpty {
                    Text("With " + meeting.attendees.joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
                }
                if let error = meeting.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
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

            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases, id: \.self) { Text($0 == .notes && meeting.isTeamCopy ? "Notes" : $0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Its natural width, not a range: the segmented control underneath never draws narrower than its
                // labels, so a `.frame(maxWidth:)` let SwiftUI count it as shrinkable and report a window minimum
                // ~40pt too small. At that minimum the page overflowed and was centred, clipping both edges.
                .fixedSize()
                Spacer()
                if meeting.isConversation {
                    Button {
                        Task { await service.summarize(meeting, templateID: MeetingTemplate.conversation.id) }
                    } label: {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
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
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(isBusy || isRecording || editingSummary || shownSegments.isEmpty || meeting.isTeamCopy)
                }
                Button {
                    TextInserter.copyToClipboard(service.markdown(for: meeting))
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .fixedSize()
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
                        Menu("Move to Binder") {
                            MoveToBinderItems(current: meeting.binderID) { binder in
                                Store.shared.move(meeting, to: binder)
                                team.scheduleSync(after: 0.5)
                            }
                        }
                        .disabled(isRecording)
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
            }

            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .task(id: "\(meeting.id)|\(meeting.status)|\(isBusy)") {
            segments = Store.shared.segments(for: meeting.id)
        }
        .confirmationDialog(meeting.isConversation ? "Delete this capture and its transcript?"
                            : team.isConfigured && meeting.sharedWithTeam
                            ? "Delete this meeting, its transcript and audio? It's also removed for your team."
                            : "Delete this meeting, its transcript and audio?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
        .sheet(isPresented: $rescuing) { MicRescueSheet(meeting: meeting) }
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
                                Circle().fill(SpeakerColor.color(for: meeting.speakerNames[label] ?? label)).frame(width: 7, height: 7)
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
                VStack(alignment: .leading, spacing: 12) {
                    let blocks = TranscriptFormatter.blocks(shownSegments, names: meeting.speakerNames)
                    if blocks.isEmpty {
                        Text(isBusy ? "Transcribing…" : "No transcript.").foregroundStyle(.secondary)
                    } else {
                        TranscriptText.render(blocks)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
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
                    VStack(alignment: .leading, spacing: 14) {
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
                        } else {
                            // The whole thread as one literal Text value, built by concatenation, instead of one
                            // row per markdown line or one View per message: SwiftUI's cross-view text selection
                            // (drag or Cmd-A/Cmd-C) never spans separate Text instances, however many share a
                            // `.textSelection(.enabled)` ancestor or come from the same ForEach — confirmed by
                            // testing both arrangements. Only a single Text is one selectable, draggable region.
                            Self.threadText(meeting.chat)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .id("thread")
                        }
                        if service.chattingMeetingIDs.contains(meeting.id) {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").foregroundStyle(.secondary)
                            }
                            .id("thinking")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: meeting.chat.count) {
                    withAnimation { proxy.scrollTo(service.chattingMeetingIDs.contains(meeting.id) ? "thinking" : "thread", anchor: .bottom) }
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

    /// The whole Ask thread as one concatenated Text, questions in the accent colour with a bold "You:" so they
    /// still stand apart the way the old right-aligned bubble did. Plain prose, not Markdown: a single Text can
    /// carry inline styling (what the colour and bold label need) but not block structure or per-run alignment, so
    /// this is the one place in the Ask tab a bulleted answer shows its "- " literally instead of a styled bullet,
    /// and a question can't sit on the right — the cost of the whole thread being one real selectable, draggable
    /// region, which per-bubble Views could never be.
    private static func threadText(_ chat: [MeetingRecord.ChatMessage]) -> Text {
        chat.enumerated().reduce(Text("")) { combined, item in
            let (index, message) = item
            let separator = index == 0 ? Text("") : Text("\n\n\n")
            let line = message.role == "user"
                ? (Text("You: ").fontWeight(.semibold) + Text(message.text)).foregroundStyle(Color.accentColor)
                : Text(message.text)
            return combined + separator + line
        }
    }

    private func send() {
        let text = question.trimmed
        guard !text.isEmpty else { return }
        question = ""
        Task { await service.ask(text, about: meeting) }
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
                    Button { onToggleTask(index) } label: {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(checked ? Color.accentColor : Color.secondary)
                    .help(checked ? "Mark as not done" : "Mark as done")
                } else {
                    Image(systemName: checked ? "checkmark.square" : "square").foregroundStyle(.secondary)
                }
                inlineText(text)
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? Color.secondary : Color.primary)
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
            Text("Replace my mic track").font(.title3.weight(.semibold))
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
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio, .movie]) { result in
            if case .success(let url) = result { fileURL = url }
        }
    }
}

/// What a conversation brought up: cards to put on a board, answers from your binders. Yes, no, or later.
private struct ConversationSuggestionsView: View {
    @Environment(MeetingService.self) private var service
    @Bindable var meeting: MeetingRecord
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(meeting.suggestions.filter { $0.status == .offered }) { suggestion in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: suggestion.kind == .card ? "rectangle.split.3x1" : "questionmark.bubble")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        if suggestion.kind == .card {
                            Text("Put “\(suggestion.text)” on the \(suggestion.binder) board?")
                        } else {
                            Text("You asked: \(suggestion.text)").font(.callout.weight(.semibold))
                            Text(suggestion.answer ?? "").textSelection(.enabled)
                            if !suggestion.sources.isEmpty {
                                Text("From " + suggestion.sources.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if suggestion.kind == .card {
                        Button("Add to Board") { message = service.conversations?.accept(suggestion.id).message }
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
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }
}
