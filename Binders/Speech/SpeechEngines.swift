import FluidAudio
import Foundation
import WhisperKit
import BindersKit

enum SpeechModelID: String, CaseIterable, Codable, Identifiable {
    case parakeetV3, parakeetV2, whisperTurbo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .parakeetV3: "Parakeet TDT v3 (multilingual)"
        case .parakeetV2: "Parakeet TDT v2 (English)"
        case .whisperTurbo: "Whisper Large v3 Turbo"
        }
    }

    var detail: String {
        switch self {
        case .parakeetV3: "NVIDIA · 25 European languages · ~500 MB · fastest, runs on the Neural Engine"
        case .parakeetV2: "NVIDIA · English only · ~500 MB · best English accuracy"
        case .whisperTurbo: "OpenAI · 99 languages · ~630 MB · slower, for languages Parakeet doesn't cover"
        }
    }

    var isParakeet: Bool { self != .whisperTurbo }
}

enum SpeechError: LocalizedError {
    case notLoaded

    var errorDescription: String? { "The speech model isn't loaded yet" }
}

protocol SpeechEngine: AnyObject, Sendable {
    var modelID: SpeechModelID { get }
    func isDownloaded() -> Bool
    func load(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ samples: [Float], language: String?, vocabulary: [VocabularyTerm], boost: Bool) async throws -> String
}

actor ParakeetEngine: SpeechEngine {
    nonisolated let modelID: SpeechModelID
    private var manager: AsrManager?
    private var ctcModels: CtcModels?
    private var boostSession: (terms: [VocabularyTerm], session: VocabularyBoostingSession)?

    init(modelID: SpeechModelID) {
        self.modelID = modelID
    }

    private nonisolated var version: AsrModelVersion { modelID == .parakeetV2 ? .v2 : .v3 }

    nonisolated func isDownloaded() -> Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: version, progressHandler: { update in
            progress(update.fractionCompleted)
        })
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
        Log.speech.info("Parakeet \(String(describing: self.version)) loaded")
        // Fetch the small CTC model used for dictionary boosting now, not during the first dictation.
        do {
            ctcModels = try await CtcModels.downloadAndLoad()
        } catch {
            Log.speech.error("Vocabulary boosting model unavailable: \(error.localizedDescription)")
        }
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [VocabularyTerm], boost: Bool) async throws -> String {
        guard let manager else { throw SpeechError.notLoaded }
        let audio = AudioMath.padded(samples, toAtLeast: 16_000)
        var state = TdtDecoderState.make(decoderLayers: version.decoderLayers)
        let hint = version == .v3 ? language.flatMap { Language(rawValue: $0) } : nil
        let result = try await manager.transcribe(audio, decoderState: &state, language: hint)
        var text = result.text

        let boostable = vocabulary.filter { $0.term.count >= 3 }
        if boost, !boostable.isEmpty, let timings = result.tokenTimings, !timings.isEmpty {
            do {
                let session = try await vocabularySession(for: boostable)
                if let output = await session.rescore(text: text, tokenTimings: timings, audioSamples: audio), output.wasModified {
                    text = output.text
                }
            } catch {
                Log.speech.error("Vocabulary boosting unavailable: \(error.localizedDescription)")
            }
        }
        return text.trimmed
    }

    private func vocabularySession(for terms: [VocabularyTerm]) async throws -> VocabularyBoostingSession {
        if let boostSession, boostSession.terms == terms { return boostSession.session }
        if ctcModels == nil {
            ctcModels = try await CtcModels.downloadAndLoad()
        }
        let context = CustomVocabularyContext(terms: terms.map {
            CustomVocabularyTerm(text: $0.term, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
        })
        let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels!)
        boostSession = (terms, session)
        return session
    }
}

actor WhisperEngine: SpeechEngine {
    nonisolated let modelID: SpeechModelID = .whisperTurbo
    static let variant = "openai_whisper-large-v3-v20240930_turbo"
    private var kit: WhisperKit?

    private nonisolated var downloadBase: URL { AppPaths.models.appendingPathComponent("whisperkit", isDirectory: true) }
    private nonisolated var expectedFolder: URL {
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(Self.variant)", isDirectory: true)
    }

    nonisolated func isDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: expectedFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard kit == nil else { return }
        let folder: URL
        if isDownloaded() {
            folder = expectedFolder
        } else {
            folder = try await WhisperKit.download(variant: Self.variant, downloadBase: downloadBase, progressCallback: { update in
                progress(update.fractionCompleted)
            })
        }
        let config = WhisperKitConfig(model: Self.variant, downloadBase: downloadBase, modelFolder: folder.path,
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        kit = try await WhisperKit(config)
        Log.speech.info("Whisper loaded from \(folder.path)")
    }

    func transcribe(_ samples: [Float], language: String?, vocabulary: [VocabularyTerm], boost: Bool) async throws -> String {
        guard let kit else { throw SpeechError.notLoaded }
        var options = DecodingOptions()
        options.language = language
        options.detectLanguage = language == nil
        options.temperature = 0
        options.skipSpecialTokens = true
        options.withoutTimestamps = true
        if boost, !vocabulary.isEmpty, let tokenizer = kit.tokenizer {
            let prompt = " " + vocabulary.prefix(60).map(\.term).joined(separator: ", ")
            options.promptTokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let results = try await kit.transcribe(audioArray: AudioMath.padded(samples, toAtLeast: 16_000), decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmed
    }
}
