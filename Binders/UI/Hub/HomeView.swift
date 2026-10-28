import AppKit
import SwiftData
import SwiftUI
import BindersKit

struct HomeView: View {
    @Environment(CommitmentService.self) private var commitmentService
    @Environment(AppSettings.self) private var settings
    @Environment(HubNavigation.self) private var navigation
    @Environment(MeetingService.self) private var meetingService
    /// The latest 500, for the history; a search looks through all of them.
    @Query(HomeView.recentRecords) private var records: [TranscriptRecord]
    @Query private var allBinders: [BinderRecord]
    /// The to-dos, each binder's counts and the stats: read with bounded fetches and kept up to date by saves, rather than
    /// worked out from every meeting and note each time the page draws.
    @State private var data = HomeData()
    @State private var search = ""
    @State private var found: [TranscriptRecord]?
    /// The agents' day, read when the page shows and every minute while it does.
    @State private var agentDay = AgentActivity.Day()
    @Query(filter: #Predicate<TaskCard> { $0.columnRaw != "done" }) private var openCards: [TaskCard]

    static var recentRecords: FetchDescriptor<TranscriptRecord> {
        var descriptor = FetchDescriptor<TranscriptRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 500
        return descriptor
    }

    private var filtered: [TranscriptRecord] {
        search.trimmed.isEmpty ? records : (found ?? [])
    }

    /// Through every dictation's text, and the app names of the latest ones.
    private func find(_ query: String) -> [TranscriptRecord] {
        var descriptor = FetchDescriptor<TranscriptRecord>(
            predicate: #Predicate { $0.finalText.localizedStandardContains(query) || $0.rawText.localizedStandardContains(query) },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 500
        var matches = (try? Store.shared.context.fetch(descriptor)) ?? []
        let ids = Set(matches.map(\.id))
        matches += records.filter { !ids.contains($0.id) && ($0.appName?.localizedCaseInsensitiveContains(query) ?? false) }
        return matches.sorted { $0.createdAt > $1.createdAt }
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

    private var taskActions: TaskActions {
        let commitmentService = commitmentService, navigation = navigation
        return TaskActions(openMeeting: { navigation.open(meeting: $0) }, openNote: { navigation.open(note: $0) }, commitments: CommitmentActions(
            toggle: { commitmentService.toggle($0) }, dismiss: { commitmentService.setStatus($0, "dismissed") }, open: { record in
                navigation.pendingWritingSearch = record.quote ?? record.task
                navigation.selection = .writing
            }))
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = AppPaths.isDemo ? "Good morning" : (hour < 5 ? "Still up" : (hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")))
        let first = AppPaths.demoUserName ?? NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "\(part)." : "\(part), \(first)."
    }

    var body: some View {
        content
            .onAppear {
                data.start(taskActions)
                consumePendingSearch()
            }
            .onChange(of: navigation.pendingHistorySearch) { consumePendingSearch() }
            .task {
                while !Task.isCancelled {
                    agentDay = AgentActivityData.read()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .followingWorkStreams()
            // What the page first reads just shows; what arrives after files in, and counts roll.
            .settlesAfterAppearing()
            .task(id: search) {
                let query = search.trimmed
                guard !query.isEmpty else { return found = nil }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                found = find(query)
            }
    }

    private func consumePendingSearch() {
        guard let pending = navigation.pendingHistorySearch else { return }
        search = pending
        navigation.pendingHistorySearch = nil
    }

    private var greetingLines: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(BindersTheme.title(34)).fitProbe("home.title")
            Text(summary).foregroundStyle(BindersTheme.muted)
        }
        .help(greeting)
    }

    /// "Three agents working · two questions for you · ten things to check", or how to dictate when nothing's going on.
    private var summary: String {
        let working = Set(openCards.filter { $0.assigneeIsAgent && $0.column == .inProgress }.compactMap(\.assignee)).count
        let questions = openCards.filter { $0.column == .blocked }.count
        let check = openCards.filter { $0.column == .review }.count
        func count(_ n: Int, _ one: String, _ many: String) -> String? {
            n == 0 ? nil : "\(n.formatted(.number.notation(.automatic))) \(n == 1 ? one : many)"
        }
        let parts = [count(working, "agent working", "agents working"), count(questions, "question for you", "questions for you"),
                     count(check, "thing to check", "things to check")].compactMap { $0 }
        return parts.isEmpty ? "Hold \(settings.hotkeys.dictation.displayString()) and speak, double-tap for hands-free." : parts.joined(separator: " · ")
    }

    /// Record, New note and Scratchpad.
    private var starts: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await meetingService.toggle()
                    if meetingService.recordingMeetingID != nil { openMeetings() }
                }
            } label: {
                if meetingService.isRecording {
                    // Red only while the microphone is live.
                    Label("Stop", systemImage: "stop.fill").foregroundStyle(BindersTheme.live)
                } else {
                    Text("Record")
                }
            }
            .buttonStyle(.soft)
            Button { ScratchpadController.shared.show() } label: { Image(systemName: "note.text.badge.plus") }
                .buttonStyle(.soft)
                .help("Scratchpad")
                .accessibilityLabel("Scratchpad")
            Button("New note") { newNote() }
                .buttonStyle(.primary)
                .fitProbe("home.header.last")
        }
        .fixedSize()
    }

    private var content: some View {
        let openCount = data.openCount
        let stats = data.stats
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                // The greeting beside what to start while there's room; on a narrow page the buttons go under it.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        greetingLines.modifier(IdealWidthCap(cap: 280))
                        Spacer()
                        starts
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        greetingLines
                        starts
                    }
                }

                // The agents' day, who's on what, and what waits for you (lane UI2).
                AgentActivityPanel(day: agentDay)
                HomeAgentsSection()

                HeardTodaySection()

                if !AppPaths.isDemo { SetupChecklist() }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Binders").font(BindersTheme.columnTitle)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                        ForEach(binders) { binder in
                            BinderCard(binder: binder, openCount: data.openByBinder[binder.id] ?? 0,
                                       activity: data.activity.map { $0[binder.id] ?? HomeData.Activity() }) { open(binder) }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Open to-dos").font(BindersTheme.columnTitle)
                            Spacer()
                            Text(openCount == 0 ? "nothing open" : "\(openCount) across your binders").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                .rollingCount(openCount)
                        }
                        TaskBoard(tasks: data.tasks, limit: 8, binderName: { id in binders.first { $0.id == id }?.name })
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .paperCard(padding: 16)
                    VStack(spacing: 12) {
                        ActivityChart(days: data.daily).paperCard(padding: 14)
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
                    .redacted(reason: data.statsRead ? [] : .placeholder)
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
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 1180, alignment: .leading)
        }
    }

    private func open(_ binder: BinderRecord) {
        navigation.binderID = binder.id
        settings.currentBinderID = binder.id
        navigation.selection = .binder
    }

    private func openMeetings() {
        navigation.binderID = Store.shared.binder(settings.currentBinderID)?.id ?? Store.shared.defaultBinder().id
        navigation.pendingBinderTab = .meetings
        navigation.selection = .binder
    }

    private func newNote() {
        guard Store.shared.allowsSave() else { return }
        let binder = Store.shared.binder(settings.currentBinderID) ?? Store.shared.defaultBinder()
        let note = NoteItem()
        note.binderID = binder.id
        note.sharedWithTeam = binder.sharedWithTeam
        Store.shared.insert(note)
        navigation.open(note: note)
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
            // The accent's; neutral on a binder's overview, whose colour is for its name and what you act on.
            Image(systemName: symbol).foregroundStyle(.infoText)
            Text(value).font(BindersTheme.count(22)).lineLimit(1).minimumScaleFactor(0.7).rollingCount(value)
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
                .font(BindersTheme.time())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                // What you said, quoted in New York italic; a failure's message is Binders' own words.
                Text(displayText)
                    .font(record.finalText.isEmpty ? nil : BindersTheme.quote())
                    .foregroundStyle(record.finalText.isEmpty ? .secondary : .primary)
                    .lineLimit(expanded ? nil : 3)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let app = record.appName { Text(app) }
                    if record.mode == "command" { Badge(text: "Command", tinted: true) }
                    if record.mode == "moment" { Badge(text: "Said to yourself") }
                    if record.status == "failed" { Badge(text: "Failed", symbol: BindersTheme.problemSymbol, color: BindersTheme.ink) }
                    if record.mode == "dictation", record.status == "inserted", !record.usedLLM { Badge(text: "No AI") }
                    Text("\(record.wordCount) words · \(String(format: "%.1f", record.duration))s").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if expanded {
                    VStack(alignment: .leading, spacing: 3) {
                        (Text("Heard: ") + Text(record.rawText).font(BindersTheme.quote(.caption))).textSelection(.enabled)
                        if let reason = record.fallbackReason ?? record.errorMessage { StatusLabel(reason, .problem) }
                        Text("Speech \(record.asrMillis) ms · Formatting \(record.llmMillis) ms · \(record.engine)\(record.llmModel.map { " · \($0)" } ?? "")")
                            .monospacedDigit()
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
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? BindersTheme.ink.opacity(0.05) : .clear))
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
                Text(settings.hasCompletedSetup ? "Needs attention" : "Get set up").font(.system(size: 17, weight: .heavy, design: .rounded))

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
                         progress: OllamaInstaller.shared.progress ?? ModelDownloader.shared.progress ?? MLXModels.shared.progress[settings.mlxModel],
                         actionTitle: llmActionTitle) {
                    switch llmStatus {
                    case .missingModel where settings.llmProvider == .mlx:
                        MLXModels.shared.download(settings.mlxModel)
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
                    SetupRow(done: false, isTip: true, title: "Set the Globe key to Do Nothing",
                             detail: "System Settings → Keyboard → “Press Globe key to” (the fn key, with the globe on it). Otherwise tapping fn can open the emoji picker.",
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
                if WisprImporter.isAvailable, !AppDefaults.store.bool(forKey: "importedFromWispr") {
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
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(boxColor.opacity(0.07)))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(BindersTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(boxColor.opacity(0.3)))
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1.5))
                    tick += 1
                }
            }
            .task(id: "\(settings.llmProvider.rawValue)|\(settings.llmModelName)|\(settings.ollamaURL)|\(settings.openAIBaseURL)|\(settings.aiFormatting)|\(MLXModels.shared.progress[settings.mlxModel] == nil)") {
                await checkLLM()
            }
        }
    }

    /// Amber once setup was finished and something stopped working, which waits on you; the accent while setting up.
    private var boxColor: Color { settings.hasCompletedSetup ? BindersTheme.needsYou : BindersTheme.accent }

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
        case .checking: "Checking \(settings.llmProvider == .ollama ? "Ollama" : settings.llmProvider == .mlx ? "the model" : "server")…"
        case .ready(let model): "Using \(model) \(settings.llmProvider == .ollama ? "on Ollama" : settings.llmProvider == .mlx ? "in Binders, with MLX" : "on your server")."
        case .missingModel(let model):
            if settings.llmProvider == .mlx {
                if let fraction = MLXModels.shared.progress[settings.mlxModel] {
                    "Downloading \(model)… \(Int(fraction * 100))%"
                } else if let failure = MLXModels.shared.failures[settings.mlxModel] {
                    "Couldn't download \(model): \(failure)"
                } else if let pick = MLXModels.suggestions.first(where: { $0.id == settings.mlxModel }) {
                    "\(pick.name) suits this Mac's \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB of memory. It runs inside Binders, nothing else to install, and is a \(pick.gigabytes.formatted()) GB download."
                } else {
                    "\(model) runs inside Binders with MLX, once it's downloaded. Pick another in Settings → AI."
                }
            } else if let downloading = ModelDownloader.shared.model {
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
                "Ollama is the free software that runs the language model on your Mac. Binders can install it for you, or run models itself: Settings → AI → Built in (MLX). Dictation works without either."
            }
        case .disabled: "Off — dictation is cleaned up with simple rules."
        }
    }

    private var llmActionTitle: String? {
        if ModelDownloader.shared.isDownloading || OllamaInstaller.shared.isWorking || MLXModels.shared.progress[settings.mlxModel] != nil { return nil }
        switch llmStatus {
        case .missingModel where settings.llmProvider == .mlx: return "Download"
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
        if settings.llmProvider == .mlx {
            llmStatus = MLXModels.directory(for: settings.mlxModel) != nil ? .ready(settings.llmModelName) : .missingModel(settings.llmModelName)
            return
        }
        do {
            let models = try await client.listModels()
            let installed = models.contains(client.model) || models.contains(client.model + ":latest")
            llmStatus = installed || settings.llmProvider == .openAICompatible ? .ready(client.model) : .missingModel(client.model)
        } catch {
            llmStatus = .unreachable(error.localizedDescription)
        }
    }

    private func runImport() {
        // Not while the library didn't open: it would be marked imported, and the words gone at quit.
        guard Store.shared.allowsSave() else { return }
        do {
            let summary = try WisprImporter.importAll()
            AppDefaults.store.set(true, forKey: "importedFromWispr")
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
            // Granted and ready wear a check in the accent's text colour: green is kept for done.
            Image(systemName: done ? "checkmark.circle.fill" : (isTip ? "lightbulb" : "circle"))
                .font(.title3)
                .foregroundStyle(done ? AnyShapeStyle(.tintText) : AnyShapeStyle(.secondary))
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
