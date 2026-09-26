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
                                   inset: NSSize(width: 4, height: 8), compactToolbar: true)
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
                withAnimation { proxy.scrollTo(blocks.count - 1, anchor: .bottom) }
            }
        }
    }
}

struct TranscriptBlockRow: View {
    let block: TranscriptBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(block.speaker).font(.caption.weight(.semibold)).foregroundStyle(SpeakerColor.color(for: block.speaker))
                Text(TranscriptFormatter.timestamp(block.start)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(block.text).textSelection(.enabled)
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
    let binderID: UUID?

    /// The meetings in one binder, or every meeting when `binderID` is nil.
    init(binderID: UUID? = nil) {
        self.binderID = binderID
        if let binderID {
            _meetings = Query(filter: #Predicate<MeetingRecord> { $0.binderID == binderID }, sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
        } else {
            _meetings = Query(sort: [SortDescriptor(\MeetingRecord.createdAt, order: .reverse)])
        }
    }

    private var filtered: [MeetingRecord] {
        let query = search.trimmed
        guard !query.isEmpty else { return meetings }
        return meetings.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query)
                || $0.userNotes.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
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
            } else {
                ContentUnavailableView {
                    Label("Meeting notes", systemImage: "person.2.wave.2")
                } description: {
                    Text("Press \(settings.hotkeys.meeting?.displayString() ?? "Record meeting") during a call. Nothing joins the call: Binders records on this Mac, transcribes, labels speakers and writes notes locally.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie]) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let record = await service.importRecording(url) { selection = record.id }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
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
            if let pending = navigation.pendingMeetingID {
                selection = pending
                navigation.pendingMeetingID = nil
            } else if selection == nil {
                selection = service.recordingMeetingID ?? meetings.first?.id
            }
        }
        .onChange(of: navigation.pendingMeetingID) {
            guard let pending = navigation.pendingMeetingID else { return }
            selection = pending
            navigation.pendingMeetingID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: TeamSyncService.itemsWillBeRemoved)) { notification in
            // A teammate stopped sharing the open meeting: close it before sync deletes it.
            if let ids = notification.userInfo?["ids"] as? Set<UUID>, let selection, ids.contains(selection) { self.selection = nil }
        }
        .onChange(of: meetings.map(\.id)) {
            // A meeting discarded after processing (nothing was said) disappears from under the selection.
            if let selection, !meetings.contains(where: { $0.id == selection }) { self.selection = nil }
        }
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
                }
                HStack(spacing: 10) {
                    Text(metaLine).foregroundStyle(.secondary)
                    Spacer()
                    if meeting.isTeamCopy {
                        Label("Shared by \(meeting.teamAuthorName ?? "a teammate") · read-only", systemImage: "person.2")
                            .font(.callout)
                            .foregroundStyle(.secondary)
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
                .frame(maxWidth: 400)
                Spacer()
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
                Button {
                    TextInserter.copyToClipboard(service.markdown(for: meeting))
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Menu {
                    Button("Export Markdown…") { service.export(meeting) }
                    let audio = meeting.audioURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
                    if !audio.isEmpty {
                        Button("Show Audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting(audio) }
                    }
                    if !meeting.isTeamCopy {
                        Button("Replace My Mic Track…") { rescuing = true }
                            .disabled(isRecording || isBusy)
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
                        Button("Delete Meeting", role: .destructive) { confirmDelete = true }
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
        .confirmationDialog(team.isConfigured && meeting.sharedWithTeam
                            ? "Delete this meeting, its transcript and audio? It's also removed for your team."
                            : "Delete this meeting, its transcript and audio?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive, action: onDelete)
        }
        .sheet(isPresented: $rescuing) { MicRescueSheet(meeting: meeting) }
    }

    private var metaLine: String {
        var parts = [meeting.createdAt.formatted(date: .abbreviated, time: .shortened)]
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
                MarkdownNoteEditor(text: $meeting.userNotes, fontSize: 14, inset: NSSize(width: 4, height: 8), compactToolbar: true)
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
                MarkdownNoteEditor(text: $meeting.summary, fontSize: 14, inset: NSSize(width: 4, height: 8), compactToolbar: true)
            }
        } else {
            ScrollView {
                MarkdownBlocks(markdown: meeting.summary, onToggleTask: canEditSummary ? { line in
                    meeting.summary = NotesEditing.toggleCheckbox(in: meeting.summary, line: line)
                } : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .padding(.top, canEditSummary ? 26 : 0)
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
                    withAnimation { proxy.scrollTo(meeting.chat.count - 1, anchor: .bottom) }
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
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.15)))
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
    /// When set, task checkboxes become clickable and report the line index they belong to.
    var onToggleTask: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { index, line in
                row(line, index: index)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ raw: String, index: Int) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            Spacer().frame(height: 2)
        } else if line.hasPrefix("### ") {
            inline(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
        } else if line.hasPrefix("## ") {
            inline(String(line.dropFirst(3))).font(.title3.weight(.semibold)).padding(.top, 8)
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
