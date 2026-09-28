import AVFoundation
import BindersKit
import Foundation
import FoundationModels
import Observation
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

    // MARK: Listening

    func start() async {
        guard phase == .idle || phase == .done || isFailed else { return }
        text = ""
        heard = ""
        cleanedBy = ""
        phase = .starting
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw DictationError.microphone }
            let engine = try await Self.makeEngine()
            engine.onText = { [weak self] words in
                guard let self, self.phase == .listening || self.phase == .transcribing else { return }
                self.text = words
            }
            try await engine.prepare()
            self.engine = engine
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, engine] buffer, _ in
                engine.append(buffer)
                let loudness = Self.loudness(buffer)
                Task { @MainActor in self?.level = loudness }
            }
            audio.prepare()
            try audio.start()
            phase = .listening
        } catch {
            stopAudio()
            phase = .failed(error.localizedDescription)
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

    /// Done talking: the transcript, then the cleanup.
    func finish(connection: MacConnection) async {
        guard phase == .listening, let engine else { return }
        stopAudio()
        phase = .transcribing
        let raw: String
        do {
            raw = try await engine.finish()
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

    /// What was heard, cleaned up.
    func clean(_ raw: String, connection: MacConnection) async {
        heard = raw
        phase = .cleaning
        text = raw
        (text, cleanedBy) = await Self.cleanUp(raw, connection: connection)
        phase = .done
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

    /// Cleans up what was heard: by your Mac when it's reachable, by this iPhone's model, or by Binders' rules. Also says who.
    static func cleanUp(_ raw: String, connection: MacConnection, app: String = "Binders") async -> (text: String, by: String) {
        if let mac = await connection.format(raw), !mac.text.isEmpty {
            return (mac.text, mac.model.isEmpty ? "your Mac" : "your Mac (\(mac.model))")
        }
        let model = onDeviceModel()
        let result = await DictationPipeline.process(raw: raw, context: AppContext(appName: app),
                                                     config: PipelineConfig(aiFormatting: model != nil), llm: model)
        return (result.text, result.usedLLM ? "this iPhone" : "Binders' rules (no model)")
    }

    func cancel() {
        stopAudio()
        engine = nil
        phase = .idle
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private func stopAudio() {
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

    /// Apple's on-device model, where the iPhone has one (Apple Intelligence, iOS 26).
    private static func onDeviceModel() -> LLMCompletion? {
        guard #available(iOS 26.0, *), SystemLanguageModel.default.availability == .available else { return nil }
        return { system, user in
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(to: user).content
        }
    }
}
