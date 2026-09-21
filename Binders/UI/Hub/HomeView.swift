import AppKit
import SwiftData
import SwiftUI
import BindersKit

struct HomeView: View {
    @Environment(CommitmentService.self) private var commitmentService
    @Query(sort: \CommitmentRecord.createdAt, order: .reverse) private var commitments: [CommitmentRecord]
    @Environment(AppSettings.self) private var settings
    @Environment(HubNavigation.self) private var navigation
    @Environment(MeetingService.self) private var meetingService
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse) private var records: [TranscriptRecord]
    @Query private var allBinders: [BinderRecord]
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]
    @Query(sort: \NoteItem.updatedAt, order: .reverse) private var notes: [NoteItem]
    @State private var search = ""

    private var dictations: [UsageRecord] {
        records.filter { $0.mode == "dictation" && $0.status == "inserted" }
            .map { UsageRecord(date: $0.createdAt, words: $0.wordCount, duration: $0.duration) }
    }

    private var stats: UsageStats { StatsCalculator.compute(dictations) }

    private var filtered: [TranscriptRecord] {
        let query = search.trimmed
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.finalText.localizedCaseInsensitiveContains(query) || $0.rawText.localizedCaseInsensitiveContains(query)
                || ($0.appName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var days: [(title: String, records: [TranscriptRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered.prefix(500)) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) { title = "Today" }
            else if calendar.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(.dateTime.weekday(.wide).month().day()) }
            return (title, grouped[day]!.sorted { $0.createdAt > $1.createdAt })
        }
    }

    private var binders: [BinderRecord] {
        allBinders.filter { !$0.archived }.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            if a.isTeamCopy != b.isTeamCopy { return !a.isTeamCopy }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var tasks: [TaskEntry] {
        TaskCollector.collect(meetings: Array(meetings.prefix(30)), notes: Array(notes.prefix(80)), commitments: Array(commitments.prefix(60)),
                              openMeeting: open(meeting:), openNote: open(note:), commitmentActions: commitmentActions)
    }

    private var commitmentActions: CommitmentActions {
        CommitmentActions(toggle: { commitmentService.toggle($0) }, dismiss: { commitmentService.setStatus($0, "dismissed") }, open: { record in
            navigation.pendingWritingSearch = record.quote ?? record.task
            navigation.selection = .writing
        })
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = AppPaths.isDemo ? "Good morning" : (hour < 5 ? "Still up" : (hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")))
        let first = AppPaths.demoUserName ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "\(part)." : "\(part), \(first)."
    }

    var body: some View {
        content
            .onAppear(perform: consumePendingSearch)
            .onChange(of: navigation.pendingHistorySearch) { consumePendingSearch() }
    }

    private func consumePendingSearch() {
        guard let pending = navigation.pendingHistorySearch else { return }
        search = pending
        navigation.pendingHistorySearch = nil
    }

    private var content: some View {
        let tasks = tasks
        let openCount = tasks.filter { !$0.done }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(greeting).font(BindersTheme.title(32))
                        Text("\(Date().formatted(date: .complete, time: .omitted)) · Hold \(settings.hotkeys.dictation.displayString()) and speak, double-tap for hands-free.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            Task {
                                await meetingService.toggle()
                                if meetingService.recordingMeetingID != nil { openMeetings() }
                            }
                        } label: {
                            Label(meetingService.isRecording ? "Stop" : "Record",
                                  systemImage: meetingService.isRecording ? "stop.fill" : "record.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(meetingService.isRecording ? .red : .accentColor)
                        Button { newNote() } label: { Label("New note", systemImage: "square.and.pencil") }
                        Button { ScratchpadController.shared.show() } label: { Label("Scratchpad", systemImage: "note.text.badge.plus") }
                    }
                    .controlSize(.large)
                    .fixedSize()
                }

                if !AppPaths.isDemo { SetupChecklist() }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Binders").font(BindersTheme.columnTitle)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        ForEach(binders) { binder in
                            let mine = meetings.filter { $0.binderID == binder.id }
                            let theirs = notes.filter { $0.binderID == binder.id }
                            BinderCard(binder: binder, openCount: tasks.filter { !$0.done && $0.binderID == binder.id }.count,
                                       meetingCount: mine.count, noteCount: theirs.count,
                                       lastActivity: (mine.map(\.createdAt) + theirs.map(\.updatedAt)).max()) { open(binder) }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Open to-dos").font(BindersTheme.columnTitle)
                            Spacer()
                            Text(openCount == 0 ? "nothing open" : "\(openCount) across your binders").font(.callout).foregroundStyle(.secondary)
                        }
                        TaskBoard(tasks: tasks, limit: 8, binderName: { id in binders.first { $0.id == id }?.name })
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .paperCard(padding: 16)
                    VStack(spacing: 12) {
                        ActivityChart(days: StatsCalculator.dailyWords(dictations)).paperCard(padding: 14)
                        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                StatCard(title: "Words this week", value: stats.wordsThisWeek.formatted(), symbol: "text.word.spacing")
                                StatCard(title: "Average speed", value: "\(stats.averageWPM) wpm", symbol: "speedometer")
                            }
                            GridRow {
                                StatCard(title: "Streak", value: "\(stats.streakDays) \(stats.streakDays == 1 ? "day" : "days")", symbol: "flame")
                                StatCard(title: "Time saved", value: formatMinutes(stats.minutesSaved), symbol: "clock.arrow.circlepath")
                            }
                        }
                    }
                    .frame(width: 330)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Dictation history").font(BindersTheme.columnTitle)
                        Spacer()
                        TextField("Search", text: $search)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                    if records.isEmpty {
                        ContentUnavailableView("No dictations yet", systemImage: "waveform",
                                               description: Text("Everything you dictate shows up here, stored only on this Mac."))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(days, id: \.title) { day in
                                Text(day.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 14)
                                    .padding(.bottom, 4)
                                ForEach(day.records) { record in
                                    HistoryRow(record: record)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
    }

    private func open(_ binder: BinderRecord) {
        navigation.binderID = binder.id
        settings.currentBinderID = binder.id
        navigation.selection = .binder
    }

    private func openMeetings() {
        navigation.binderID = settings.currentBinderID ?? Store.shared.defaultBinder().id
        navigation.pendingBinderTab = .meetings
        navigation.selection = .binder
    }

    private func open(meeting: MeetingRecord) {
        navigation.binderID = meeting.binderID ?? Store.shared.defaultBinder().id
        navigation.pendingMeetingID = meeting.id
        navigation.pendingBinderTab = .meetings
        navigation.selection = .binder
    }

    private func open(note: NoteItem) {
        navigation.binderID = note.binderID ?? Store.shared.defaultBinder().id
        navigation.pendingNoteID = note.id
        navigation.pendingBinderTab = .notes
        navigation.selection = .binder
    }

    private func newNote() {
        let binder = Store.shared.binder(settings.currentBinderID) ?? Store.shared.defaultBinder()
        let note = NoteItem()
        note.binderID = binder.id
        note.sharedWithTeam = binder.sharedWithTeam
        Store.shared.insert(note)
        open(note: note)
    }

    private func formatMinutes(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: "%.1f h", Double(minutes) / 60) : "\(minutes) min"
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperCard()
    }
}

struct HistoryRow: View {
    @Environment(DictationController.self) private var controller
    let record: TranscriptRecord
    @State private var hovering = false
    @State private var expanded = false
    @State private var retrying = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(record.createdAt, format: .dateTime.hour().minute())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(displayText)
                    .foregroundStyle(record.finalText.isEmpty ? .secondary : .primary)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let app = record.appName { Text(app) }
                    if record.mode == "command" { Badge(text: "Command", color: .purple) }
                    if record.status == "failed" { Badge(text: "Failed", color: .red) }
                    if record.mode == "dictation", record.status == "inserted", !record.usedLLM { Badge(text: "No AI", color: .orange) }
                    Text("\(record.wordCount) words · \(String(format: "%.1f", record.duration))s")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if expanded {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Heard: \(record.rawText)").textSelection(.enabled)
                        if let reason = record.fallbackReason ?? record.errorMessage { Text(reason).foregroundStyle(.orange) }
                        Text("Speech \(record.asrMillis) ms · Formatting \(record.llmMillis) ms · \(record.engine)\(record.llmModel.map { " · \($0)" } ?? "")")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) {
                if retrying { ProgressView().controlSize(.small) }
                Button { TextInserter.copyToClipboard(record.finalText) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy")
                if record.audioURL != nil {
                    Button { retry() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Transcribe again with current settings and copy")
                }
                Button { Store.shared.delete(record) } label: { Image(systemName: "trash") }
                    .help("Delete")
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { expanded.toggle() }
        .contextMenu {
            Button("Copy") { TextInserter.copyToClipboard(record.finalText) }
            Button("Copy Raw Transcript") { TextInserter.copyToClipboard(record.rawText) }
            if record.audioURL != nil { Button("Transcribe Again") { retry() } }
            Divider()
            Button("Delete", role: .destructive) { Store.shared.delete(record) }
        }
    }

    private var displayText: String {
        if !record.finalText.isEmpty { return record.finalText }
        return record.errorMessage ?? "(nothing inserted)"
    }

    private func retry() {
        retrying = true
        Task {
            _ = await controller.retry(record)
            retrying = false
        }
    }
}

struct SetupChecklist: View {
    @Environment(DictationController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @State private var tick = 0
    @State private var llmStatus: LLMStatus = .checking
    @State private var importMessage: String?

    enum LLMStatus: Equatable {
        case checking, ready(String), missingModel(String), unreachable(String), disabled
    }

    private var micReady: Bool { Permissions.microphone == .authorized }
    private var speechReady: Bool { controller.speech.state == .ready }
    private var llmReady: Bool {
        if case .ready = llmStatus { return true }
        return llmStatus == .disabled
    }
    private var requiredDone: Bool { micReady && Permissions.accessibility && speechReady }
    private var showGlobeTip: Bool { settings.hotkeys.dictation.modifiers.contains(.function) && !Permissions.globeKeyDoesNothing }

    var body: some View {
        let _ = tick
        if !settings.hasCompletedSetup || !requiredDone || !llmReady || Permissions.wisprFlowRunning != nil || showGlobeTip {
            VStack(alignment: .leading, spacing: 12) {
                Text(settings.hasCompletedSetup ? "Needs attention" : "Get set up").font(.title3.weight(.semibold))

                SetupRow(done: micReady, title: "Microphone",
                         detail: "Binders only listens while you hold your shortcut.",
                         actionTitle: Permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                    if Permissions.microphone == .notDetermined {
                        Task { _ = await Permissions.requestMicrophone(); tick += 1 }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                }
                SetupRow(done: Permissions.accessibility, title: "Accessibility",
                         detail: "Needed to detect your shortcut anywhere and paste text into the app you're using.",
                         actionTitle: "Grant Access") {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                SetupRow(done: speechReady, title: "Speech model", detail: speechDetail,
                         progress: speechProgress, actionTitle: speechActionTitle) {
                    controller.speech.activate(settings.speechModel, download: true)
                }
                SetupRow(done: llmReady, title: "AI formatting", detail: llmDetail,
                         progress: OllamaInstaller.shared.progress ?? ModelDownloader.shared.progress, actionTitle: llmActionTitle) {
                    switch llmStatus {
                    case .missingModel(let model) where settings.llmProvider == .ollama:
                        Task {
                            await ModelDownloader.shared.pull(model, from: settings.ollamaURL)
                            await checkLLM()
                        }
                    case .unreachable where settings.llmProvider == .ollama:
                        Task {
                            if OllamaInstaller.installedURL != nil {
                                await OllamaInstaller.shared.open(serverURL: settings.ollamaURL)
                            } else {
                                await OllamaInstaller.shared.installWithConsent(serverURL: settings.ollamaURL)
                            }
                            await checkLLM()
                        }
                    default:
                        Task { await checkLLM() }
                    }
                }
                if showGlobeTip {
                    SetupRow(done: false, isTip: true, title: "Set the 🌐 key to “Do Nothing”",
                             detail: "System Settings → Keyboard → “Press 🌐 key to”. Otherwise tapping fn can open the emoji picker.",
                             actionTitle: "Keyboard Settings") { Permissions.openKeyboardSettings() }
                }
                if let wispr = Permissions.wisprFlowRunning {
                    SetupRow(done: false, isTip: true, title: "Wispr Flow is still running",
                             detail: "Both apps respond to fn. Quit Wispr Flow so only Binders dictates.",
                             actionTitle: "Quit Wispr Flow") {
                        wispr.terminate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick += 1 }
                    }
                }
                if WisprImporter.isAvailable, !UserDefaults.standard.bool(forKey: "importedFromWispr") {
                    SetupRow(done: false, isTip: true, title: "Import from Wispr Flow",
                             detail: importMessage ?? "Bring over your dictionary words and snippets.",
                             actionTitle: "Import") { runImport() }
                }
                if requiredDone, !settings.hasCompletedSetup {
                    Button("Finish setup") { settings.hasCompletedSetup = true }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.18)))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    tick += 1
                }
            }
            .task(id: "\(settings.llmProvider.rawValue)|\(settings.llmModelName)|\(settings.ollamaURL)|\(settings.openAIBaseURL)|\(settings.aiFormatting)") {
                await checkLLM()
            }
        }
    }

    private var speechDetail: String {
        switch controller.speech.state {
        case .idle: return "\(settings.speechModel.displayName) — download once, runs offline."
        case .downloading(let fraction): return "Downloading \(settings.speechModel.displayName)… \(Int(fraction * 100))%"
        case .loading: return "Preparing \(settings.speechModel.displayName) for the Neural Engine (first launch can take a minute)…"
        case .ready: return "\(settings.speechModel.displayName) is ready."
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var speechProgress: Double? {
        if case .downloading(let fraction) = controller.speech.state { return fraction }
        return nil
    }

    private var speechActionTitle: String? {
        switch controller.speech.state {
        case .idle: "Download"
        case .failed: "Retry"
        default: nil
        }
    }

    private var llmDetail: String {
        switch llmStatus {
        case .checking: "Checking \(settings.llmProvider == .ollama ? "Ollama" : "server")…"
        case .ready(let model): "Using \(model) on \(settings.llmProvider == .ollama ? "Ollama" : "your server")."
        case .missingModel(let model):
            if let downloading = ModelDownloader.shared.model {
                "Downloading \(downloading)… \(Int((ModelDownloader.shared.progress ?? 0) * 100))%"
            } else if let failure = ModelDownloader.shared.error {
                "Couldn't download \(model): \(failure)"
            } else if model == ModelDownloader.recommendation.model {
                "\(model) suits this Mac's \(ModelDownloader.memoryGB) GB of memory. It runs on your Mac and is a \(ModelDownloader.recommendation.downloadGB.formatted()) GB download."
            } else {
                "“\(model)” isn't installed yet. Download it, or pick another in Settings."
            }
        case .unreachable:
            if settings.llmProvider != .ollama {
                "Your model server isn't reachable."
            } else if let line = OllamaInstaller.shared.statusLine {
                line
            } else if OllamaInstaller.installedURL != nil {
                "Ollama is installed but isn't running. Open it and Binders picks up from there."
            } else {
                "Ollama is the free software that runs the language model on your Mac. Binders can install it for you. Dictation works without it."
            }
        case .disabled: "Off — dictation is cleaned up with simple rules."
        }
    }

    private var llmActionTitle: String? {
        if ModelDownloader.shared.isDownloading || OllamaInstaller.shared.isWorking { return nil }
        switch llmStatus {
        case .missingModel where settings.llmProvider == .ollama: return "Download"
        case .unreachable where settings.llmProvider == .ollama: return OllamaInstaller.installedURL != nil ? "Open Ollama" : "Install Ollama"
        default: return "Check again"
        }
    }

    private func checkLLM() async {
        guard settings.aiFormatting || settings.commandModeEnabled else {
            llmStatus = .disabled
            return
        }
        guard let client = settings.makeLLMClient() else {
            llmStatus = .missingModel(settings.llmModelName.isEmpty ? "(none selected)" : settings.llmModelName)
            return
        }
        llmStatus = .checking
        do {
            let models = try await client.listModels()
            let installed = models.contains(client.model) || models.contains(client.model + ":latest")
            llmStatus = installed || settings.llmProvider == .openAICompatible ? .ready(client.model) : .missingModel(client.model)
        } catch {
            llmStatus = .unreachable(error.localizedDescription)
        }
    }

    private func runImport() {
        do {
            let summary = try WisprImporter.importAll()
            UserDefaults.standard.set(true, forKey: "importedFromWispr")
            importMessage = "Imported \(summary.words) words and \(summary.snippets) snippets."
            controller.flowBar.toast("Imported \(summary.words) words and \(summary.snippets) snippets from Wispr Flow", symbol: "square.and.arrow.down")
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
        tick += 1
    }
}

struct SetupRow: View {
    let done: Bool
    var isTip = false
    let title: String
    let detail: String
    var progress: Double?
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : (isTip ? "lightbulb" : "circle"))
                .font(.title3)
                .foregroundStyle(done ? Color.green : (isTip ? Color.yellow : Color.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let progress { ProgressView(value: progress).frame(maxWidth: 320) }
            }
            Spacer()
            if !done, let actionTitle {
                Button(actionTitle, action: action)
            }
        }
    }
}
