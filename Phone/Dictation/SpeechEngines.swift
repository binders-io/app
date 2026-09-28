import AVFoundation
import Foundation
import Speech

enum DictationError: LocalizedError {
    case microphone, speech, language, unavailable

    var errorDescription: String? {
        switch self {
        case .microphone: "Binders needs the microphone to hear you. Allow it in Settings → Binders."
        case .speech: "Binders needs speech recognition to write down what you say. Allow it in Settings → Binders."
        case .language: "This iPhone can't transcribe your language on the device yet."
        case .unavailable: "Speech recognition isn't available right now. Try again in a moment."
        }
    }
}

/// Turns audio into words on this iPhone. `onText` hears the words so far, as they settle.
@MainActor
protocol SpeechEngine: AnyObject {
    var onText: ((String) -> Void)? { get set }
    func prepare() async throws
    /// Audio from the microphone, in its own format; called on the audio thread.
    nonisolated func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio: the whole transcript.
    func finish() async throws -> String
}

/// Apple's newer engine (iOS 26): on the device, fast, and good with long dictation.
@available(iOS 26.0, *)
@MainActor
final class AnalyzerEngine: SpeechEngine {
    var onText: ((String) -> Void)?
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var settled = ""
    private var pending = ""
    nonisolated(unsafe) private var input: AsyncStream<AnalyzerInput>.Continuation?
    nonisolated(unsafe) private var format: AVAudioFormat?
    nonisolated(unsafe) private var converter: AVAudioConverter?

    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    func prepare() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { throw DictationError.language }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await download.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input = continuation
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let words = String(result.text.characters)
                    guard let self else { return }
                    if result.isFinal {
                        self.settled += words
                        self.pending = ""
                    } else {
                        self.pending = words
                    }
                    self.onText?(self.settled + self.pending)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard let format else { return }
        if buffer.format == format {
            input?.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var used = false
        converter.convert(to: converted, error: nil) { _, status in
            if used {
                status.pointee = .noDataNow
                return nil
            }
            used = true
            status.pointee = .haveData
            return buffer
        }
        if converted.frameLength > 0 { input?.yield(AnalyzerInput(buffer: converted)) }
    }

    func finish() async throws -> String {
        input?.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        return (settled + pending).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The older recognizer, for iPhones before iOS 26, on the device.
@MainActor
final class RecognizerEngine: SpeechEngine {
    var onText: ((String) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: .current)
    nonisolated(unsafe) private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var failure: Error?
    private var lastHeard = Date()
    private var ended = false

    func prepare() async throws {
        guard let recognizer, recognizer.isAvailable else { throw DictationError.unavailable }
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // What you say stays on this iPhone. The Simulator has no on-device model, so there it may use Apple's servers.
        #if targetEnvironment(simulator)
        request.requiresOnDeviceRecognition = false
        #else
        guard recognizer.supportsOnDeviceRecognition else { throw DictationError.language }
        request.requiresOnDeviceRecognition = true
        #endif
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let words {
                    self.latest = words
                    self.lastHeard = Date()
                    self.onText?(words)
                }
                if let error, self.latest.isEmpty { self.failure = error }
                if final || error != nil { self.ended = true }
            }
        }
    }

    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    /// Waits for the final words, or until none have come for a couple of seconds: some final results never arrive.
    func finish() async throws -> String {
        request.endAudio()
        lastHeard = Date()
        let started = Date()
        while !ended, Date().timeIntervalSince(lastHeard) < 2.5, Date().timeIntervalSince(started) < 30 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        task?.cancel()
        if let failure, latest.isEmpty { throw failure }
        return latest.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
