import AppKit
import Observation
import BindersKit

/// Orchestrates a dictation or command session: hotkey -> record -> transcribe -> format -> insert.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case recording(SessionMode, handsFree: Bool)
        case processing(SessionMode)
    }

    private struct Session {
        let id = UUID()
        var mode: SessionMode
        var handsFree: Bool
        let startedAt = Date()
        let snapshot: Task<FocusSnapshot, Never>
        var maxDurationTimer: Timer?
        var previewTask: Task<Void, Never>?
    }

    private(set) var phase: Phase = .idle {
        // Esc cancels formatting; the tap thread decides on its own, so it is told rather than asked.
        didSet {
            hotkeys.interceptsEscape = { if case .processing = phase { true } else { false } }()
            // Lane DS8: dictating stops the Distill model's warm-up.
            if case .recording = phase { distill.cancelWarm() }
        }
    }
    private(set) var lastError: String?

    let settings = AppSettings.shared
    let speech = SpeechService()
    @ObservationIgnored let flowBar = FlowBarController()
    @ObservationIgnored let hotkeys: HotkeyMonitor
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var session: Session?
    /// The session currently being transcribed or formatted; cleared when Esc cancels it.
    @ObservationIgnored private var processingID: UUID?
    @ObservationIgnored private var editObserver: EditObserver?
    @ObservationIgnored private var lastWarmUp = Date.distantPast
    /// For the self-tests: what would be pasted is handed here instead, so a test never types into the app in front or
    /// touches the clipboard.
    @ObservationIgnored var pasteStandIn: ((String) -> Void)?
    @ObservationIgnored private(set) lazy var meetings = MeetingService(speech: speech, flowBar: flowBar)
    /// Conversations the iPhone heard during the day, written up as they arrive.
    @ObservationIgnored private(set) lazy var conversations: ConversationService = {
        let conversations = ConversationService(meetings: meetings)
        conversations.controller = self
        meetings.conversations = conversations
        return conversations
    }()
    /// What you said to yourself near your iPhone, acted on or offered.
    @ObservationIgnored private(set) lazy var moments = MomentService(controller: self)
    /// Where new cards and to-dos go, and the agent whose work each is.
    @ObservationIgnored private(set) lazy var router = CardRouter(controller: self)
    /// All-day capture on this Mac: conversations heard through the day.
    @ObservationIgnored private(set) lazy var allDay = AllDayCaptureService(controller: self)
    @ObservationIgnored private(set) lazy var knowledge = KnowledgeService()
    @ObservationIgnored private(set) lazy var team = TeamSyncService(flowBar: flowBar)
    @ObservationIgnored private(set) lazy var capture = WritingCaptureService(flowBar: flowBar)
    @ObservationIgnored private(set) lazy var commitments = CommitmentService(flowBar: flowBar)
    /// The binders' boards, where people and agents pick up work.
    @ObservationIgnored private(set) lazy var board: BoardService = {
        let board = BoardService()
        board.commitments = commitments
        board.dispatcher = agents
        board.hub = HubBoard.shared
        HubBoard.shared.board = board
        agents.board = board
        return board
    }()
    /// Wakes the agents cards are meant for (Settings → Agents).
    @ObservationIgnored private(set) lazy var agents = AgentDispatcher(registry: .shared)
    /// Distill: notes read into work items, placed on the board by you, and their progress (lane DS1).
    @ObservationIgnored private(set) lazy var distill = DistillService(controller: self)
    /// The Manager (lane MG1): what you ask the agent with the role, and its tidies, one at a time.
    @ObservationIgnored private(set) lazy var manager = ManagerService(controller: self)
    /// Your chats with your agents (lane AC1).
    @ObservationIgnored private(set) lazy var chats = AgentChatService(controller: self)
    /// Binders as a server for paired phones; started by the app when the setting is on.
    /// The phone link. `--selftest-link-serve` puts its own in, on spare ports, so what changes reaches the iPhone it serves.
    @ObservationIgnored lazy var link = LinkServer(controller: self)

    init() {
        hotkeys = HotkeyMonitor(bindings: AppSettings.shared.hotkeys)
        hotkeys.onAction = { [weak self] action in self?.handle(action) }
        hotkeys.onEscape = { [weak self] in self?.cancelProcessing() }
        recorder.onLevel = { [weak self] level in self?.flowBar.model.push(level) }
        flowBar.onStop = { [weak self] in self?.stopFromUI() }
        flowBar.onCancel = { [weak self] in self?.cancel(silent: false, fromHotkey: false) }
    }

    func start() {
        hotkeys.start()
        // The decision model's identity and bands, worked out in the background a little after launch.
        DecisionModels.shared.checkSoon()
        speech.activate(settings.speechModel, download: true)
        flowBar.idleVisible = settings.showFlowBarWhenIdle
        if !settings.managesModelMemory { warmUpLLM(force: true) }
        // Old audio goes with the rest of launch's tidying, a little after (LaunchHousekeeping), then every 6 hours.
        Timer.scheduledTimer(withTimeInterval: 6 * 3_600, repeats: true) { _ in
            MainActor.assumeIsolated {
                Store.shared.pruneOldAudio(olderThanDays: AppSettings.shared.audioRetentionDays)
                Store.shared.pruneWriting(olderThanDays: AppSettings.shared.captureRetentionDays)
                Store.shared.purgeTrivialConversations()
                AgentDispatcher.pruneLogs()
            }
        }
        meetings.startMonitoring()
        conversations.recover()
        allDay.start()
        capture.afterCommit = { [weak self] record in self?.commitments.enqueue(record) }
        AutomationService.shared.notify = { [weak self] text, symbol in self?.flowBar.toast(text, symbol: symbol, duration: 5) }
        agents.notify = { [weak self] text, symbol in self?.flowBar.toast(text, symbol: symbol, duration: 5) }
        knowledge.isAppBusy = { [weak self] in
            guard let self else { return false }
            return self.phase != .idle || !self.meetings.busyMeetingIDs.isEmpty
        }
        knowledge.start()
        team.start()
        // Binders linked to a hub: their boards follow it.
        _ = board
        HubBoard.shared.follow()
        // The Manager's tidy on a schedule, when you set one (lane MG1).
        manager.startSchedule()

        observeChanges({ AppSettings.shared.hotkeys }) { [weak self] in self?.hotkeys.updateBindings($0) }
        observeChanges({ AppSettings.shared.speechModel }) { [weak self] in self?.speech.activate($0, download: true) }
        observeChanges({ AppSettings.shared.showFlowBarWhenIdle }) { [weak self] in self?.flowBar.idleVisible = $0 }
        observeChanges({ AppSettings.shared.llmModelName }) { [weak self] _ in if !AppSettings.shared.managesModelMemory { self?.warmUpLLM(force: true) } }
    }

    func handle(_ action: HotkeyAction) {
        switch action {
        case .start(let mode, let handsFree):
            begin(mode: mode, handsFree: handsFree)
        case .switchMode(let mode):
            guard var current = session, mode == .dictation || settings.commandModeEnabled else { return }
            current.mode = mode
            session = current
            phase = .recording(mode, handsFree: current.handsFree)
            flowBar.showRecording(mode: mode, handsFree: current.handsFree)
        case .stop:
            Task { await finish() }
        case .cancel(let silent):
            cancel(silent: silent, fromHotkey: true)
        case .pasteLast:
            Task { await pasteLast() }
        case .toggleScratchpad:
            ScratchpadController.shared.toggle()
        case .toggleMeeting:
            Task { await meetings.toggle() }
        case .toggleCapture:
            capture.toggle()
        }
    }

    // MARK: - Session lifecycle

    private func begin(mode requestedMode: SessionMode, handsFree: Bool) {
        guard phase == .idle, session == nil else {
            // Keep the hotkey state machine in sync, or it stays "recording" and swallows Esc.
            hotkeys.sessionEnded()
            return
        }
        let mode: SessionMode = requestedMode == .command && !settings.commandModeEnabled ? .dictation : requestedMode
        // You're about to speak: an answer still being read aloud stops, so the microphone doesn't hear it.
        AnswerSpeaker.shared.stop()

        switch Permissions.microphone {
        case .authorized:
            break
        case .notDetermined:
            hotkeys.sessionEnded()
            Task { _ = await Permissions.requestMicrophone() }
            return
        default:
            hotkeys.sessionEnded()
            flowBar.toast("Microphone access is off — enable it in Settings", symbol: "mic.slash")
            HubWindowController.shared.show(section: .home)
            return
        }
        if case .failed = speech.state {
            speech.activate(settings.speechModel, download: true)
        }

        editObserver?.finish()
        editObserver = nil

        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier, bundleID = front?.bundleIdentifier, appName = front?.localizedName
        let snapshot = Task.detached(priority: .userInitiated) {
            ContextReader.capture(pid: pid, bundleID: bundleID, appName: appName)
        }

        do {
            try recorder.start(deviceUID: settings.microphoneUID)
        } catch {
            hotkeys.sessionEnded()
            Sounds.error()
            flowBar.toast(error.localizedDescription, symbol: "mic.slash")
            return
        }

        var newSession = Session(mode: mode, handsFree: handsFree, snapshot: snapshot)
        let id = newSession.id
        newSession.maxDurationTimer = Timer.scheduledTimer(withTimeInterval: Double(settings.maxRecordingMinutes) * 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopFromUI() }
        }
        session = newSession
        meetings.setDictationActive(true)
        phase = .recording(mode, handsFree: handsFree)
        flowBar.showRecording(mode: mode, handsFree: handsFree)

        // Skip the chime for accidental taps; hands-free always gets it.
        let chimeDelay = handsFree ? 0 : 0.26
        DispatchQueue.main.asyncAfter(deadline: .now() + chimeDelay) { [weak self] in
            guard let self, self.session?.id == id else { return }
            if self.settings.playSounds { Sounds.start() }
            if self.settings.muteAudioWhileDictating {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if self.session?.id == id { SystemAudio.muteOutput() }
                }
            }
        }

        warmUpLLM(force: false)
        if settings.livePreview, settings.speechModel.isParakeet {
            session?.previewTask = startPreview(sessionID: id)
        }
    }

    private func stopFromUI() {
        guard session != nil else { return }
        hotkeys.sessionEnded()
        Task { await finish() }
    }

    func cancel(silent: Bool, fromHotkey: Bool) {
        guard let current = session else { return }
        current.maxDurationTimer?.invalidate()
        current.previewTask?.cancel()
        _ = recorder.stop()
        meetings.setDictationActive(false)
        SystemAudio.restoreOutput()
        session = nil
        phase = .idle
        if !fromHotkey { hotkeys.sessionEnded() }
        if silent {
            flowBar.hide()
        } else {
            if settings.playSounds { Sounds.cancel() }
            flowBar.toast("Cancelled", symbol: "xmark")
        }
    }

    /// Esc while transcribing or formatting: drop the result instead of pasting it later. An answer being written stops,
    /// and its panel closes.
    private func cancelProcessing() {
        guard case .processing = phase, processingID != nil else { return }
        processingID = nil
        phase = .idle
        if AnswerPanelController.shared.isAnswering { AnswerPanelController.shared.close() }
        if settings.playSounds { Sounds.cancel() }
        flowBar.toast("Cancelled", symbol: "xmark")
    }

    private func finish() async {
        guard let current = session else { return }
        session = nil
        current.maxDurationTimer?.invalidate()
        current.previewTask?.cancel()
        let samples = recorder.stop()
        meetings.setDictationActive(false)
        SystemAudio.restoreOutput()
        await process(samples, mode: current.mode, snapshot: current.snapshot)
    }

    /// For the self-tests: a recording that has just ended, as when the dictation key is let go, with nothing focused to
    /// paste into (`pasteStandIn` takes what would be pasted).
    func heard(_ samples: [Float], mode: SessionMode) async {
        await process(samples, mode: mode, snapshot: Task { FocusSnapshot(context: AppContext()) })
    }

    /// A recording that has just ended: transcribed, then pasted or acted on, and kept in History with its audio. While
    /// the library didn't open, what you said still goes where you asked, and nothing is kept: no History, no recording.
    private func process(_ samples: [Float], mode: SessionMode, snapshot pending: Task<FocusSnapshot, Never>) async {
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        guard duration >= 0.3 else {
            phase = .idle
            flowBar.hide()
            return
        }
        if settings.playSounds { Sounds.stop() }
        let id = UUID()
        processingID = id
        phase = .processing(mode)
        flowBar.showProcessing(mode: mode)
        defer {
            if processingID == id {
                processingID = nil
                phase = .idle
            }
        }

        guard !AudioMath.isSilent(samples) else {
            flowBar.toast("No speech detected — check your microphone", symbol: "mic.slash")
            return
        }

        let snapshot = await pending.value
        let vocabulary = Store.shared.vocabulary()
        let audio = settings.whisperBoost ? AudioMath.normalize(samples) : samples
        let modelUsable = speech.state == .ready || speech.state == .loading
        let audioFileName = settings.saveAudio || !modelUsable ? saveAudio(samples) : nil

        guard modelUsable else {
            // Don't hold a dictation until a download finishes; it would paste minutes later somewhere else. Its recording
            // waits in History to be transcribed then, unless the library didn't open, when nothing can keep it.
            let kept = Store.shared.canSave ? "Recording saved to History."
                : "The recording wasn't kept: Binders couldn't open its library. Quit and reopen Binders."
            let message: String
            if case .downloading(let fraction) = speech.state {
                message = "Speech model is still downloading (\(Int(fraction * 100))%). \(kept)"
            } else {
                message = "Speech model isn't ready. \(kept)"
                speech.activate(settings.speechModel, download: true)
            }
            Sounds.error()
            flowBar.toast(message, symbol: "arrow.down.circle", duration: Store.shared.canSave ? 4 : 7)
            recordHistory(mode: mode, raw: "", final: "", snapshot: snapshot, duration: duration, asrMillis: 0, llmMillis: 0,
                          usedLLM: false, fallback: nil, audioFileName: audioFileName, status: "failed", error: message)
            return
        }

        let asrStart = Date()
        let raw: String
        do {
            let engine = try await speech.waitUntilReady()
            raw = try await engine.transcribe(audio, language: settings.languageHint, vocabulary: vocabulary, boost: settings.vocabularyBoost)
        } catch {
            guard processingID == id else { return }
            Sounds.error()
            flowBar.toast("Transcription failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            recordHistory(mode: mode, raw: "", final: "", snapshot: snapshot, duration: duration, asrMillis: 0, llmMillis: 0,
                          usedLLM: false, fallback: nil, audioFileName: audioFileName, status: "failed", error: error.localizedDescription)
            return
        }
        guard processingID == id else { return }
        let asrMillis = Int(Date().timeIntervalSince(asrStart) * 1000)

        guard !raw.isEmpty else {
            flowBar.toast("Didn't catch that", symbol: "questionmark")
            return
        }

        switch mode {
        case .dictation:
            await deliverDictation(raw: raw, snapshot: snapshot, vocabulary: vocabulary, duration: duration,
                                   asrMillis: asrMillis, audioFileName: audioFileName, processing: id)
        case .command:
            await deliverCommand(instruction: raw, snapshot: snapshot, vocabulary: vocabulary, duration: duration,
                                 asrMillis: asrMillis, audioFileName: audioFileName, processing: id)
        }
    }

    private func deliverDictation(raw: String, snapshot: FocusSnapshot, vocabulary: [VocabularyTerm], duration: Double,
                                  asrMillis: Int, audioFileName: String?, processing id: UUID) async {
        // "Add to-do…" and "add it to my calendar" said as plain dictation are meant for Binders, not the document.
        if let phrase = VoiceCommands.parseTodo(raw, explicitOnly: true) {
            await addTodo(phrase, instruction: raw, snapshot: snapshot, duration: duration, asrMillis: asrMillis, audioFileName: audioFileName,
                          processing: id)
            return
        }
        if let request = VoiceCommands.parseCalendarAdd(raw, explicitOnly: true) {
            await addToCalendar(request, instruction: raw, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                                audioFileName: audioFileName, processing: id)
            return
        }
        let llmStart = Date()
        let result = await format(raw: raw, context: snapshot.context, vocabulary: vocabulary)
        guard processingID == id else { return }
        let llmMillis = result.usedLLM || result.fallbackReason != nil ? Int(Date().timeIntervalSince(llmStart) * 1000) : 0

        var text = result.text
        if settings.smartSpacing { text = SmartSpacing.adjust(text, before: snapshot.context.textBeforeCursor) }

        let pasted = await insert(text, into: snapshot, pressEnter: result.pressEnter)
        if pasted {
            AutomationService.shared.fire(.dictationInserted, payload: AutomationPayload(
                text: text.trimmed, title: text.trimmed, app: snapshot.context.appName ?? "",
                binder: Store.shared.binder(settings.currentBinderID)?.name ?? ""))
            if let reason = result.fallbackReason, settings.aiFormatting {
                Log.llm.error("Formatting fallback: \(reason)")
                if Store.shared.canSave {
                    flowBar.toast("Pasted without AI formatting", symbol: "exclamationmark.bubble")
                } else {
                    flowBar.toast(Store.notKeptUnformattedMessage, symbol: BindersTheme.problemSymbol, duration: 5)
                }
                lastError = reason
            } else {
                donePasting()
                lastError = nil
            }
        }

        let category = StyleResolver.category(for: snapshot.context, overrides: settings.styles.appOverrides)
        recordHistory(mode: .dictation, raw: raw, final: text.trimmed, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                      llmMillis: llmMillis, usedLLM: result.usedLLM, fallback: result.fallbackReason, audioFileName: audioFileName,
                      status: "inserted", category: category)

        if pasted, settings.autoLearnDictionary, !text.isEmpty, !result.pressEnter, snapshot.value != nil, let element = snapshot.element {
            let observer = EditObserver(element: element, inserted: text.trimmed) { [weak self] corrections in
                self?.learn(corrections)
            }
            editObserver = observer
            observer.start()
        }
    }

    func format(raw: String, context: AppContext, vocabulary: [VocabularyTerm]? = nil) async -> PipelineResult {
        await TextFormatter.format(raw: raw, context: context, vocabulary: vocabulary)
    }

    private func deliverCommand(instruction: String, snapshot: FocusSnapshot, vocabulary: [VocabularyTerm], duration: Double,
                                asrMillis: Int, audioFileName: String?, processing id: UUID) async {
        // The user's own rules come first: "send to Things buy milk".
        if let match = AutomationService.shared.match(instruction) {
            let outcome = await AutomationService.shared.run(match.rule, payload: match.payload)
            guard processingID == id else { return }
            recordHistory(mode: .command, raw: instruction, final: "\(match.rule.name): \(outcome.message)", snapshot: snapshot, duration: duration,
                          asrMillis: asrMillis, llmMillis: 0, usedLLM: false, fallback: nil, audioFileName: audioFileName,
                          status: outcome.ok ? "answered" : "failed", error: outcome.ok ? nil : outcome.message)
            return
        }

        // "Add to-do call Sam tomorrow" and "add it to my calendar" act on their own; the model rewrites nothing.
        if let phrase = VoiceCommands.parseTodo(instruction) {
            await addTodo(phrase, instruction: instruction, snapshot: snapshot, duration: duration, asrMillis: asrMillis, audioFileName: audioFileName,
                          processing: id)
            return
        }
        if let request = VoiceCommands.parseCalendarAdd(instruction) {
            await addToCalendar(request, instruction: instruction, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                                audioFileName: audioFileName, processing: id)
            return
        }

        // "How's the checkout spec going?": a Distill note's report, from the board alone, with no model (lane DS1).
        if snapshot.context.selectedText == nil, Store.shared.canSave, let report = DistillService.answer(instruction) {
            AnswerPanelController.shared.show(question: instruction, answer: KnowledgeService.Answer(question: instruction, text: report, sources: []))
            AnswerSpeaker.shared.speak(report)
            flowBar.hide()
            recordHistory(mode: .command, raw: instruction, final: report, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                          llmMillis: 0, usedLLM: false, fallback: nil, audioFileName: audioFileName, status: "answered")
            return
        }

        // "What's happening with my work streams?": the boards' digest, from the boards alone, with no model.
        if snapshot.context.selectedText == nil,
           MomentRules.read(instruction, binders: Store.shared.binders().map(\.name), agents: AgentRegistry.shared.agents.map(\.name), heard: Date()).kind == .status {
            let reading = MomentRules.read(instruction, binders: Store.shared.binders().map(\.name), agents: AgentRegistry.shared.agents.map(\.name), heard: Date())
            let binder = reading.binder.flatMap { name in Store.shared.binders().first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
            var cards = WorkStreams.cards(in: binder?.id)
            if let agent = reading.agent { cards = WorkStreams.involving(agent, in: cards) }
            let digest = WorkStreams.digest(cards)
            // While the library didn't open, the boards are in it: say so, rather than that nothing's happening.
            let summary = Store.shared.canSave ? digest.summary : Store.unanswerableMessage
            AnswerPanelController.shared.show(question: instruction, answer: KnowledgeService.Answer(question: instruction, text: summary, sources: []))
            // Asked out loud, it's said back (Read answers aloud).
            AnswerSpeaker.shared.speak(summary)
            flowBar.hide()
            recordHistory(mode: .command, raw: instruction, final: digest.headline, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                          llmMillis: 0, usedLLM: false, fallback: nil, audioFileName: audioFileName, status: "answered")
            return
        }

        // "What did we decide about pricing?" / "look up the beta list": answer from meetings, notes and dictations.
        var lookup = KnowledgeQueryIntent.query(from: instruction)
        if lookup == nil, snapshot.context.selectedText == nil, KnowledgeQueryIntent.isQuestion(instruction),
           await knowledge.store.mentionsKnownEntity(instruction) {
            // "What's Daniel working on?" names someone from your meetings, so answer from them rather than generically.
            lookup = instruction
        }
        if snapshot.context.selectedText == nil, VoiceCommands.parseWebSearch(instruction) == nil, let lookup {
            flowBar.hide()
            // The panel shows the passages found at once, then the answer as it's written. Closing it, or Esc, stops it.
            let answer = await AnswerPanelController.shared.ask(instruction, searchQuery: lookup == instruction ? nil : lookup, knowledge: knowledge)
            guard processingID == id, let answer else { return }
            // Stored as "answered" so answers aren't re-indexed as knowledge or pasted by "paste last".
            recordHistory(mode: .command, raw: instruction, final: answer.text, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                          llmMillis: 0, usedLLM: true, fallback: nil, audioFileName: audioFileName, status: "answered")
            return
        }

        var context = snapshot.context
        // Only fall back to ⌘C when the app can't report its selection. An empty selection is not a
        // reason to copy: editors like VS Code copy the whole current line.
        if context.selectedText == nil, !snapshot.selectionReadable, !snapshot.isSecure, VoiceCommands.parseWebSearch(instruction) == nil {
            context.selectedText = await TextInserter.copySelection()
        }
        let client = settings.makeLLMClient()
        let llmStart = Date()
        let outcome = await TextFormatter.command(instruction: instruction, context: context, vocabulary: vocabulary)
        guard processingID == id else { return }
        let llmMillis = Int(Date().timeIntervalSince(llmStart) * 1000)

        var final = ""
        switch outcome {
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            final = url.absoluteString
            flowBar.toast("Searching…", symbol: "magnifyingglass")
        case .replaceSelection(let text), .insert(let text):
            final = text
            if await insert(text, into: snapshot, pressEnter: false) { donePasting() }
        case .failed(let message):
            Sounds.error()
            flowBar.toast(message, symbol: "exclamationmark.triangle")
        }
        var failure: String?
        if case .failed(let message) = outcome { failure = message }
        recordHistory(mode: .command, raw: instruction, final: final, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                      llmMillis: llmMillis, usedLLM: client != nil, fallback: nil, audioFileName: audioFileName,
                      status: failure == nil ? "inserted" : "failed", error: failure)
    }

    /// "Add to-do call Sam tomorrow": into the binder you named, else the one the router picks, else the open one, with
    /// the agent whose work it is offered in the flow bar (CardRouter). Recorded like an answered question so it is never
    /// pasted or indexed. The flow bar keeps its processing look while the router decides (4 seconds at most), and Esc
    /// meanwhile adds nothing.
    private func addTodo(_ phrase: String, instruction: String, snapshot: FocusSnapshot, duration: Double, asrMillis: Int, audioFileName: String?,
                         processing id: UUID) async {
        // Not while the library didn't open: the flow bar says so instead.
        guard Store.shared.allowsSave() else { return }
        let plan = await router.decideCommandTodo(phrase)
        guard processingID == id, Store.shared.allowsSave() else { return }
        if flowBar.model.display == .processing { flowBar.hide() }
        let line = router.addCommandTodo(plan)
        recordHistory(mode: .command, raw: instruction, final: line, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                      llmMillis: 0, usedLLM: false, fallback: nil, audioFileName: audioFileName, status: "answered")
    }

    /// The event named in the command, or found in what was just dictated or is selected. A time phrase at the end
    /// settles it on its own; only messier text goes to the model, which quotes the day and time for the code to work out.
    private func addToCalendar(_ request: VoiceCommands.CalendarRequest, instruction: String, snapshot: FocusSnapshot, duration: Double,
                               asrMillis: Int, audioFileName: String?, processing id: UUID) async {
        let started = Date()
        let result = await resolveCalendarEvent(request, selectedText: snapshot.context.selectedText)
        guard processingID == id else { return }
        if !result.added { Sounds.error() }
        flowBar.toast(result.line, symbol: result.added ? "calendar.badge.plus" : "calendar.badge.exclamationmark", duration: 5)
        recordHistory(mode: .command, raw: instruction, final: result.line, snapshot: snapshot, duration: duration, asrMillis: asrMillis,
                      llmMillis: result.usedLLM ? Int(Date().timeIntervalSince(started) * 1000) : 0, usedLLM: result.usedLLM, fallback: nil,
                      audioFileName: audioFileName, status: result.added ? "answered" : "failed", error: result.added ? nil : result.line)
    }

    /// binders://calendar?text=… and the MCP server's add_to_calendar.
    @discardableResult
    func addToCalendar(described text: String) async -> (line: String, added: Bool) {
        let result = await resolveCalendarEvent(.described(text), selectedText: nil)
        if !result.added { Sounds.error() }
        flowBar.toast(result.line, symbol: result.added ? "calendar.badge.plus" : "calendar.badge.exclamationmark", duration: 5)
        return (result.line, result.added)
    }

    /// binders://dictate and binders://command: start hands-free, or finish what is running.
    func toggleSession(_ mode: SessionMode) {
        if case .idle = phase { handle(.start(mode, handsFree: true)) } else { handle(.stop) }
    }

    /// For the self-tests: what Command Mode does with words it has just heard, with nothing selected, as after a
    /// recording (Esc cancels it the same way).
    func command(heard instruction: String) async {
        let id = UUID()
        processingID = id
        phase = .processing(.command)
        defer {
            if processingID == id {
                processingID = nil
                phase = .idle
            }
        }
        await deliverCommand(instruction: instruction, snapshot: FocusSnapshot(context: AppContext()), vocabulary: [], duration: 1,
                             asrMillis: 0, audioFileName: nil, processing: id)
    }

    private func resolveCalendarEvent(_ request: VoiceCommands.CalendarRequest, selectedText: String?) async -> (line: String, added: Bool, usedLLM: Bool) {
        let source: String?
        switch request {
        case .described(let text):
            source = text
        case .fromContext:
            let selected = selectedText?.trimmed ?? ""
            source = selected.isEmpty
                ? Store.shared.recentTranscripts(limit: 5).first { $0.mode == "dictation" && $0.status == "inserted" && !$0.finalText.trimmed.isEmpty }?.finalText
                : selected
        }
        guard let source, !source.trimmed.isEmpty else {
            return ("Nothing to add yet: dictate or select the text, then say “add it to my calendar”.", false, false)
        }
        let now = Date()
        var draft = CalendarEventExtraction.deterministic(source, now: now)
        var usedLLM = false
        if draft == nil, let client = settings.makeLLMClient() {
            usedLLM = true
            do {
                let output = try await client.complete(system: CalendarEventExtraction.systemPrompt(),
                                                       user: CalendarEventExtraction.userPrompt(text: String(source.prefix(2_000))),
                                                       maxTokens: 200, temperature: 0, timeout: 60)
                draft = CalendarEventExtraction.parse(output, now: now)
            } catch {
                Log.llm.error("Calendar event extraction failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let draft else {
            return ("Couldn't find a day and time in that. Say when, for example “Monday at 11 am”.", false, usedLLM)
        }
        do {
            let calendar = try await CalendarContext.add(draft)
            let when = draft.allDay ? draft.start.formatted(date: .abbreviated, time: .omitted) : draft.start.formatted(date: .abbreviated, time: .shortened)
            return ("Added to \(calendar): \(draft.title) · \(when)", true, usedLLM)
        } catch {
            return (error.localizedDescription, false, usedLLM)
        }
    }

    /// Pastes into the app that was focused when the session started. If the user moved to another app
    /// while we were processing, copies instead so the text never lands somewhere unexpected.
    private func insert(_ text: String, into snapshot: FocusSnapshot, pressEnter: Bool) async -> Bool {
        if let pasteStandIn {
            pasteStandIn(text)
            return true
        }
        if let pid = snapshot.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            if !text.isEmpty { TextInserter.copyToClipboard(text) }
            if Store.shared.canSave {
                flowBar.toast("You switched apps — copied to clipboard instead", symbol: "doc.on.clipboard", duration: 3)
            } else {
                // Nothing is kept while the library didn't open: the bar says so here too (`donePasting`).
                flowBar.toast(Store.notKeptCopiedMessage, symbol: BindersTheme.problemSymbol, duration: 5)
            }
            return false
        }
        if !text.isEmpty {
            await TextInserter.paste(text, restoreClipboard: settings.restoreClipboard)
        }
        if pressEnter {
            try? await Task.sleep(for: .milliseconds(120))
            TextInserter.pressReturn()
        }
        return true
    }

    // MARK: - Features

    func pasteLast() async {
        // While the library didn't open, no dictation is kept: say why there's nothing.
        guard Store.shared.canSave else {
            flowBar.toast(Store.nothingToPasteMessage, symbol: BindersTheme.problemSymbol, duration: 7)
            return
        }
        guard let last = Store.shared.lastTranscript(), !last.finalText.isEmpty else {
            flowBar.toast("Nothing to paste yet", symbol: "doc.on.clipboard")
            return
        }
        await TextInserter.paste(last.finalText, restoreClipboard: settings.restoreClipboard)
    }

    /// Re-transcribes saved audio with the current model and formatter, and copies the result.
    func retry(_ record: TranscriptRecord) async -> String? {
        guard let url = record.audioURL, let samples = try? AudioRecorder.readSamples(from: url) else { return nil }
        do {
            let engine = try await speech.waitUntilReady()
            let audio = settings.whisperBoost ? AudioMath.normalize(samples) : samples
            let raw = try await engine.transcribe(audio, language: settings.languageHint, vocabulary: Store.shared.vocabulary(),
                                                  boost: settings.vocabularyBoost)
            let context = AppContext(bundleID: record.bundleID, appName: record.appName)
            let result = await format(raw: raw, context: context)
            record.rawText = raw
            record.finalText = result.text
            record.wordCount = result.text.wordCount
            record.usedLLM = result.usedLLM
            record.fallbackReason = result.fallbackReason
            record.status = "inserted"
            record.errorMessage = nil
            Store.shared.save()
            TextInserter.copyToClipboard(result.text)
            flowBar.toast("Transcribed again and copied", symbol: "doc.on.clipboard")
            return result.text
        } catch {
            flowBar.toast("Retry failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
            return nil
        }
    }

    private func learn(_ corrections: [LearnedCorrection]) {
        var added: [String] = []
        for correction in corrections where Store.shared.addDictionaryWord(correction.corrected, aliases: [correction.heard], source: "auto") {
            added.append(correction.corrected)
        }
        guard !added.isEmpty else { return }
        flowBar.toast("Added “\(added.joined(separator: "”, “"))” to your dictionary", symbol: "book.closed")
    }

    private func startPreview(sessionID: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, self.session?.id == sessionID else { return }
                let audio = Array(self.recorder.snapshot().suffix(Int(AudioRecorder.sampleRate) * 20))
                guard audio.count > 8_000, !AudioMath.isSilent(audio), let engine = self.speech.readyEngine else { continue }
                let text = try? await engine.transcribe(audio, language: self.settings.languageHint, vocabulary: [], boost: false)
                guard self.session?.id == sessionID, let text, !text.isEmpty else { continue }
                self.flowBar.model.preview = text
            }
        }
    }

    /// The iPhone heard someone start talking (binders/warm): the model loads now, so writing the capture up doesn't wait
    /// for it.
    func warmForPhone() { warmUpLLM(force: false, forWriteUp: true) }

    /// Loading starts the moment a dictation begins, so the model is back before the transcript needs it even
    /// after its memory was freed. When it is already loaded the call is instant, so a minute's throttle is enough.
    private func warmUpLLM(force: Bool, forWriteUp: Bool = false) {
        guard forWriteUp || settings.aiFormatting || settings.commandModeEnabled,
              force || Date().timeIntervalSince(lastWarmUp) > 60,
              let client = settings.makeLLMClient() else { return }
        lastWarmUp = Date()
        Task.detached { await client.warmUp() }
    }

    /// Frees the model's memory now (Settings, and quitting when Binders manages the model).
    func unloadLLM() async {
        guard let client = settings.makeLLMClient() else { return }
        lastWarmUp = .distantPast
        await client.unload()
    }

    /// Never while the library didn't open: with no History to hold it, the recording would be left with nothing to find
    /// it by or delete it with.
    private func saveAudio(_ samples: [Float]) -> String? {
        guard Store.shared.canSave else { return nil }
        let name = "\(UUID().uuidString).wav"
        let url = AppPaths.audio.appendingPathComponent(name)
        Task.detached(priority: .utility) {
            do { try AudioRecorder.writeWAV(samples, to: url) } catch { Log.audio.error("Couldn't save audio: \(error.localizedDescription)") }
        }
        return name
    }

    /// After a paste that needs no word: the bar goes. While the library didn't open, it says History won't have it.
    private func donePasting() {
        if Store.shared.canSave {
            flowBar.hide()
        } else {
            flowBar.toast(Store.notKeptMessage, symbol: BindersTheme.problemSymbol, duration: 5)
        }
    }

    /// Never while the library didn't open: a dictation or a result kept then would show in History until quit, and be gone
    /// after. What you said was still pasted or acted on, and the bar says it isn't kept (`donePasting`).
    private func recordHistory(mode: SessionMode, raw: String, final: String, snapshot: FocusSnapshot, duration: Double, asrMillis: Int,
                               llmMillis: Int, usedLLM: Bool, fallback: String?, audioFileName: String?, status: String,
                               category: StyleCategory? = nil, error: String? = nil) {
        guard Store.shared.canSave else { return }
        let record = TranscriptRecord(mode: mode.rawValue, rawText: raw, finalText: final, appName: snapshot.context.appName,
                                      bundleID: snapshot.context.bundleID, category: category?.rawValue, duration: duration,
                                      asrMillis: asrMillis, llmMillis: llmMillis, engine: settings.speechModel.rawValue,
                                      llmModel: usedLLM ? settings.llmModelName : nil, usedLLM: usedLLM, fallbackReason: fallback,
                                      audioFileName: audioFileName, status: status, errorMessage: error)
        Store.shared.insert(record)
    }
}
