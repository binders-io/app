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
        didSet { hotkeys.interceptsEscape = { if case .processing = phase { true } else { false } }() }
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
    @ObservationIgnored private(set) lazy var meetings = MeetingService(speech: speech, flowBar: flowBar)
    @ObservationIgnored private(set) lazy var knowledge = KnowledgeService()
    @ObservationIgnored private(set) lazy var team = TeamSyncService(flowBar: flowBar)
    @ObservationIgnored private(set) lazy var capture = WritingCaptureService(flowBar: flowBar)
    @ObservationIgnored private(set) lazy var commitments = CommitmentService(flowBar: flowBar)

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
        speech.activate(settings.speechModel, download: true)
        flowBar.idleVisible = settings.showFlowBarWhenIdle
        if !settings.managesModelMemory { warmUpLLM(force: true) }
        Store.shared.pruneOldAudio(olderThanDays: settings.audioRetentionDays)
        Timer.scheduledTimer(withTimeInterval: 6 * 3_600, repeats: true) { _ in
            MainActor.assumeIsolated {
                Store.shared.pruneOldAudio(olderThanDays: AppSettings.shared.audioRetentionDays)
                Store.shared.pruneWriting(olderThanDays: AppSettings.shared.captureRetentionDays)
            }
        }
        meetings.startMonitoring()
        capture.afterCommit = { [weak self] record in self?.commitments.enqueue(record) }
        knowledge.isAppBusy = { [weak self] in
            guard let self else { return false }
            return self.phase != .idle || !self.meetings.busyMeetingIDs.isEmpty
        }
        knowledge.start()
        team.start()

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

    /// Esc while transcribing or formatting: drop the result instead of pasting it later.
    private func cancelProcessing() {
        guard case .processing = phase, processingID != nil else { return }
        processingID = nil
        phase = .idle
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

        let duration = Double(samples.count) / AudioRecorder.sampleRate
        guard duration >= 0.3 else {
            phase = .idle
            flowBar.hide()
            return
        }
        if settings.playSounds { Sounds.stop() }
        let id = UUID()
        processingID = id
        phase = .processing(current.mode)
        flowBar.showProcessing(mode: current.mode)
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

        let snapshot = await current.snapshot.value
        let vocabulary = Store.shared.vocabulary()
        let audio = settings.whisperBoost ? AudioMath.normalize(samples) : samples
        let modelUsable = speech.state == .ready || speech.state == .loading
        let audioFileName = settings.saveAudio || !modelUsable ? saveAudio(samples) : nil

        guard modelUsable else {
            // Don't hold a dictation until a download finishes; it would paste minutes later somewhere else.
            let message: String
            if case .downloading(let fraction) = speech.state {
                message = "Speech model is still downloading (\(Int(fraction * 100))%). Recording saved to History."
            } else {
                message = "Speech model isn't ready. Recording saved to History."
                speech.activate(settings.speechModel, download: true)
            }
            Sounds.error()
            flowBar.toast(message, symbol: "arrow.down.circle", duration: 4)
            recordHistory(mode: current.mode, raw: "", final: "", snapshot: snapshot, duration: duration, asrMillis: 0, llmMillis: 0,
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
            recordHistory(mode: current.mode, raw: "", final: "", snapshot: snapshot, duration: duration, asrMillis: 0, llmMillis: 0,
                          usedLLM: false, fallback: nil, audioFileName: audioFileName, status: "failed", error: error.localizedDescription)
            return
        }
        guard processingID == id else { return }
        let asrMillis = Int(Date().timeIntervalSince(asrStart) * 1000)

        guard !raw.isEmpty else {
            flowBar.toast("Didn't catch that", symbol: "questionmark")
            return
        }

        switch current.mode {
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
        let llmStart = Date()
        let result = await format(raw: raw, context: snapshot.context, vocabulary: vocabulary)
        guard processingID == id else { return }
        let llmMillis = result.usedLLM || result.fallbackReason != nil ? Int(Date().timeIntervalSince(llmStart) * 1000) : 0

        var text = result.text
        if settings.smartSpacing { text = SmartSpacing.adjust(text, before: snapshot.context.textBeforeCursor) }

        let pasted = await insert(text, into: snapshot, pressEnter: result.pressEnter)
        if pasted {
            if let reason = result.fallbackReason, settings.aiFormatting {
                Log.llm.error("Formatting fallback: \(reason)")
                flowBar.toast("Pasted without AI formatting", symbol: "exclamationmark.bubble")
                lastError = reason
            } else {
                flowBar.hide()
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
        // "What did we decide about pricing?" / "look up the beta list": answer from meetings, notes and dictations.
        var lookup = KnowledgeQueryIntent.query(from: instruction)
        if lookup == nil, snapshot.context.selectedText == nil, KnowledgeQueryIntent.isQuestion(instruction),
           await knowledge.store.mentionsKnownEntity(instruction) {
            // "What's Daniel working on?" names someone from your meetings, so answer from them rather than generically.
            lookup = instruction
        }
        if snapshot.context.selectedText == nil, VoiceCommands.parseWebSearch(instruction) == nil, let lookup {
            AnswerPanelController.shared.show(question: instruction, answer: nil)
            flowBar.hide()
            let answer = await knowledge.ask(instruction, searchQuery: lookup == instruction ? nil : lookup)
            guard processingID == id else {
                AnswerPanelController.shared.close()
                return
            }
            AnswerPanelController.shared.show(question: instruction, answer: answer)
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
            if await insert(text, into: snapshot, pressEnter: false) { flowBar.hide() }
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

    /// Pastes into the app that was focused when the session started. If the user moved to another app
    /// while we were processing, copies instead so the text never lands somewhere unexpected.
    private func insert(_ text: String, into snapshot: FocusSnapshot, pressEnter: Bool) async -> Bool {
        if let pid = snapshot.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            if !text.isEmpty { TextInserter.copyToClipboard(text) }
            flowBar.toast("You switched apps — copied to clipboard instead", symbol: "doc.on.clipboard", duration: 3)
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

    /// Loading starts the moment a dictation begins, so the model is back before the transcript needs it even
    /// after its memory was freed. When it is already loaded the call is instant, so a minute's throttle is enough.
    private func warmUpLLM(force: Bool) {
        guard settings.aiFormatting || settings.commandModeEnabled,
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

    private func saveAudio(_ samples: [Float]) -> String? {
        let name = "\(UUID().uuidString).wav"
        let url = AppPaths.audio.appendingPathComponent(name)
        Task.detached(priority: .utility) {
            do { try AudioRecorder.writeWAV(samples, to: url) } catch { Log.audio.error("Couldn't save audio: \(error.localizedDescription)") }
        }
        return name
    }

    private func recordHistory(mode: SessionMode, raw: String, final: String, snapshot: FocusSnapshot, duration: Double, asrMillis: Int,
                               llmMillis: Int, usedLLM: Bool, fallback: String?, audioFileName: String?, status: String,
                               category: StyleCategory? = nil, error: String? = nil) {
        let record = TranscriptRecord(mode: mode.rawValue, rawText: raw, finalText: final, appName: snapshot.context.appName,
                                      bundleID: snapshot.context.bundleID, category: category?.rawValue, duration: duration,
                                      asrMillis: asrMillis, llmMillis: llmMillis, engine: settings.speechModel.rawValue,
                                      llmModel: usedLLM ? settings.llmModelName : nil, usedLLM: usedLLM, fallbackReason: fallback,
                                      audioFileName: audioFileName, status: status, errorMessage: error)
        Store.shared.insert(record)
    }
}
