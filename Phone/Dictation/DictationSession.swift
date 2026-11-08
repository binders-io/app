import AVFoundation
import BindersKit
import Foundation
import FoundationModels
import Observation
import os
import Speech

/// One dictation: the microphone, the words as you say them, then the cleanup: by your Mac when it's reachable (its model,
/// dictionary and snippets), by this iPhone's own model when there is one, and by Binders' rules otherwise.
@MainActor
@Observable
final class DictationSession {
    enum Phase: Equatable {
        case idle, starting, listening, transcribing, cleaning, done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The words as they come, then the cleaned-up text, which can be edited.
    var text = ""
    /// How loud it is, 0…1, for the meter.
    private(set) var level: Double = 0
    /// Who cleaned it up: "your Mac (gemma4:26b)", "this iPhone", "Binders' rules".
    private(set) var cleanedBy = ""
    /// What was heard, before cleanup.
    private(set) var heard = ""

    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private var engine: SpeechEngine?
    /// Done tapped while the engine was still getting ready: it finishes once it is.
    @ObservationIgnored private var finishWhenReady: MacConnection?
    /// What the microphone hears, held for the engine until it's ready.
    @ObservationIgnored private var early: EarlyAudio?
    /// Counts each start and each cancel: a start still getting ready when it was let go of (and another begun since)
    /// touches nothing of the new one's.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored nonisolated(unsafe) private var configurationObserver: NSObjectProtocol?

    /// Where each step of listening and writing it down shows in the device's log, without what was said.
    static let log = Logger(subsystem: "io.binders.app", category: "dictation")
    /// The most writing it down waits for the engine's last words, in seconds. Apple's engine has been seen not to finish
    /// at all; past this, what was heard so far stands.
    static let finishLimit: TimeInterval = 6

    init() {
        // The audio session changing under it (its category set as dictation starts, a route change) stops the engine:
        // it starts again, into the same transcript.
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.audioChanged() }
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    // MARK: Listening

    /// The microphone starts at once and keeps what it hears while the speech engine gets ready, so the first words
    /// aren't lost.
    func start() async {
        guard phase == .idle || phase == .done || isFailed else { return }
        attempt += 1
        let mine = attempt
        text = ""
        heard = ""
        cleanedBy = ""
        finishWhenReady = nil
        phase = .starting
        Self.log.notice("Dictation \(mine): starting")
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphone }
            guard mine == attempt, phase == .starting, !Task.isCancelled else {
                if mine == attempt, phase == .starting { phase = .idle }
                return
            }
            // All-day capture lets go of the microphone while you dictate.
            MicrophoneUsers.claim("dictation")
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let early = EarlyAudio()
            self.early = early
            try startAudio(into: early)
            phase = .listening
            Self.log.notice("Dictation \(mine): listening")
            let engine = try await Self.makeEngine()
            engine.onText = { [weak self] words in
                guard let self, self.phase == .listening || self.phase == .transcribing else { return }
                self.text = words
            }
            try await engine.prepare()
            // Let go of while the engine got ready (Cancel, or let go of the Dictate bar), and maybe another begun: the
            // microphone was given back then.
            guard mine == attempt else {
                Self.log.notice("Dictation \(mine): let go of while the engine got ready")
                return
            }
            // Cancelled (the sheet swiped away) while the engine got ready: the microphone goes back, so All-day capture
            // isn't left paused.
            guard phase == .listening, !Task.isCancelled else {
                stopAudio()
                if phase == .listening { phase = .idle }
                return
            }
            self.engine = engine
            early.attach(engine)
            Self.log.notice("Dictation \(mine): the speech engine is ready")
            if let connection = finishWhenReady {
                finishWhenReady = nil
                await finish(connection: connection)
            }
        } catch {
            guard mine == attempt else { return }
            Self.log.error("Dictation \(mine): couldn't listen: \(error.localizedDescription, privacy: .public)")
            stopAudio()
            phase = .failed(error.localizedDescription)
        }
    }

    /// The microphone on, into `early`. Without an input to hear (another app has it), a tap would crash, so it says so.
    private func startAudio(into early: EarlyAudio) throws {
        let input = audio.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.microphoneBusy }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, early] buffer, _ in
            early.append(buffer)
            let loudness = Self.loudness(buffer)
            Task { @MainActor in self?.level = loudness }
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// The engine stopped as the audio session changed: listening carries on, in the new format.
    private func audioChanged() {
        guard phase == .listening, let early, !audio.isRunning else { return }
        do {
            try startAudio(into: early)
            Self.log.notice("Dictation: the audio changed, listening again")
        } catch {
            Self.log.error("Dictation: the audio changed and the microphone didn't start again: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Transcribes a recording instead of the microphone: for trying it in the Simulator.
    func transcribe(file url: URL, connection: MacConnection) async {
        phase = .starting
        do {
            let engine = try await Self.makeEngine()
            engine.onText = { [weak self] words in self?.text = words }
            try await engine.prepare()
            self.engine = engine
            phase = .listening
            let file = try AVAudioFile(forReading: url)
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
                try file.read(into: buffer)
                engine.append(buffer)
            }
            await finish(connection: connection)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Done talking: the transcript, then the cleanup. Before the engine is ready, once it is.
    func finish(connection: MacConnection) async {
        guard phase == .listening else { return }
        guard let engine else { return finishWhenReady = connection }
        stopAudio()
        phase = .transcribing
        let raw: String
        do {
            raw = try await lastWords(from: engine)
        } catch {
            self.engine = nil
            phase = .failed(error.localizedDescription)
            return
        }
        self.engine = nil
        guard !raw.isEmpty else {
            phase = .failed("Didn't catch anything. Try again, a little closer to the microphone.")
            return
        }
        await clean(raw, connection: connection)
    }

    /// Done talking, for a question (hold to ask): what was heard, as heard, without the cleanup and without keeping it as
    /// a dictation, since Ask has the question. Released before the engine was ready, once it is (what was said meanwhile
    /// is kept for it). Empty when nothing was heard, or when it never got as far as listening (the microphone still being
    /// asked for, or refused). The microphone goes back either way, so All-day capture listens again. Never longer than
    /// about three seconds for the engine to get ready and `finishLimit` for its last words.
    func finishHeard() async -> String {
        guard phase == .listening else {
            Self.log.notice("Hold to ask: not listening (\(String(describing: self.phase), privacy: .public)), nothing to write down")
            cancel()
            return ""
        }
        for _ in 0..<60 where phase == .listening && engine == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard phase == .listening, let engine else {
            Self.log.notice("Hold to ask: the speech engine wasn't ready in time")
            cancel()
            return ""
        }
        stopAudio()
        phase = .transcribing
        // An engine that fails at the end still heard something: that's the question.
        let raw = (try? await lastWords(from: engine)) ?? text
        self.engine = nil
        phase = .idle
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The engine's last words, waited for at most `finishLimit`: past it, the engine is let go and the words heard so
    /// far stand.
    private func lastWords(from engine: SpeechEngine) async throws -> String {
        let started = ContinuousClock.now
        do {
            let words = try await TimeLimit.run(within: Self.finishLimit) { try await engine.finish() }
            Self.log.notice("Written down in \(Self.seconds(since: started), privacy: .public) s")
            return words
        } catch is TimeLimit.Exceeded {
            Self.log.error("Writing it down took over \(Self.finishLimit, privacy: .public) s: the words heard so far stand")
            engine.abandon()
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Self.log.error("Writing it down failed after \(Self.seconds(since: started), privacy: .public) s: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> String {
        String(format: "%.1f", start.duration(to: .now) / .seconds(1))
    }

    /// What was heard, cleaned up.
    func clean(_ raw: String, connection: MacConnection) async {
        heard = raw
        phase = .cleaning
        text = raw
        (text, cleanedBy) = await Self.cleanUp(raw, connection: connection)
        phase = .done
        await connection.keepDictation(text, heard: raw, app: "Binders on iPhone")
    }

    /// The best engine this iPhone has, once it's allowed to use it.
    static func makeEngine() async throws -> SpeechEngine {
        if #available(iOS 26.0, *), AnalyzerEngine.isSupported { return AnalyzerEngine() }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw DictationError.speech }
        return RecognizerEngine()
    }

    /// Cleans up what was heard, in about 4 s at most (LinkTimeouts.cleanup): by your Mac when it's reachable and answers
    /// in time, by this iPhone's model with the time that's left, or by Binders' rules, which take no time. Also says who.
    /// The keyboard's dictations come through here too.
    static func cleanUp(_ raw: String, connection: MacConnection, app: String = "Binders") async -> (text: String, by: String) {
        let model = onDeviceModel()
        let result = await DictationCleanup.run(raw, app: app, budget: TimeBudget(seconds: LinkTimeouts.cleanup),
                                                mac: { budget in await connection.format(raw, within: budget) }, device: model)
        switch result.cleaner {
        case .mac(let name):
            let brain = connection.brain == .hub ? "your hub" : "your Mac"
            return (result.text, name.isEmpty ? brain : "\(brain) (\(name))")
        case .device: return (result.text, "this iPhone")
        case .rules: return (result.text, model == nil ? "Binders' rules (no model)" : "Binders' rules")
        case .outOfTime(let mac): return (result.text, mac ? "Binders' rules (\(connection.brain == .hub ? "your hub" : "your Mac") took too long)" : "Binders' rules (this iPhone took too long)")
        }
    }

    func cancel() {
        attempt += 1
        stopAudio()
        engine?.abandon()
        engine = nil
        early = nil
        finishWhenReady = nil
        phase = .idle
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func stopAudio() {
        early = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        MicrophoneUsers.release("dictation")
        // All-day capture, listening again, keeps the audio session.
        if !MicrophoneUsers.captureNeedsSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        level = 0
    }

    /// How loud a stretch of audio is, 0…1, from its root mean square.
    nonisolated static func loudness(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return Double(min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 50)))
    }

    /// What the microphone hears before the speech engine is ready, handed to it once it is; after that, straight through.
    /// Used from the audio thread and the main thread, so it locks. Keeps at most about half a minute.
    private final class EarlyAudio: @unchecked Sendable {
        private let lock = NSLock()
        private var engine: SpeechEngine?
        private var pending: [AVAudioPCMBuffer] = []
        private var frames: AVAudioFrameCount = 0

        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            if let engine { return engine.append(buffer) }
            // The tap reuses its buffer: keep a copy.
            guard frames < AVAudioFrameCount(buffer.format.sampleRate * 30), let source = buffer.floatChannelData,
                  let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength), let target = copy.floatChannelData else { return }
            copy.frameLength = buffer.frameLength
            for channel in 0..<Int(buffer.format.channelCount) { target[channel].update(from: source[channel], count: Int(buffer.frameLength)) }
            pending.append(copy)
            frames += buffer.frameLength
        }

        func attach(_ engine: SpeechEngine) {
            lock.lock()
            defer { lock.unlock() }
            for buffer in pending { engine.append(buffer) }
            pending = []
            self.engine = engine
        }
    }

    /// Apple's on-device model, where the iPhone has one (Apple Intelligence, iOS 26). It has no time limit of its own:
    /// the cleanup gives it only what's left of its budget.
    private static func onDeviceModel() -> LLMCompletion? {
        guard #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available else { return nil }
        return { system, user in
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(to: user).content
        }
    }
}
