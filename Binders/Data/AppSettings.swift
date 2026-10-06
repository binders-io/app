import Foundation
import Observation
import ServiceManagement
import BindersKit

enum LLMProviderKind: String, CaseIterable, Codable, Identifiable {
    case ollama, mlx, openAICompatible

    var id: String { rawValue }

    /// What this Mac can use: models built in need Apple silicon.
    static var available: [LLMProviderKind] { allCases.filter { $0 != .mlx || MLXModels.isSupported } }

    var displayName: String {
        switch self {
        case .ollama: "Ollama"
        case .mlx: "Built in (MLX, no other app needed)"
        case .openAICompatible: "OpenAI-compatible (LM Studio, llama.cpp, vLLM, Groq…)"
        }
    }
}

/// User preferences, persisted to UserDefaults on every change.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var hotkeys: HotkeyBindings { didSet { save(hotkeys, "hotkeys") } }
    var speechModel: SpeechModelID { didSet { defaults.set(speechModel.rawValue, forKey: "speechModel") } }
    /// "auto" or a language code such as "en".
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var vocabularyBoost: Bool { didSet { defaults.set(vocabularyBoost, forKey: "vocabularyBoost") } }

    var aiFormatting: Bool { didSet { defaults.set(aiFormatting, forKey: "aiFormatting") } }
    var commandModeEnabled: Bool { didSet { defaults.set(commandModeEnabled, forKey: "commandModeEnabled") } }
    var llmProvider: LLMProviderKind { didSet { defaults.set(llmProvider.rawValue, forKey: "llmProvider") } }
    /// Minutes of no requests after which Ollama frees the model's memory; 0 keeps it loaded.
    var modelIdleMinutes: Int { didSet { defaults.set(modelIdleMinutes, forKey: "modelIdleMinutes") } }
    var ollamaURL: String { didSet { defaults.set(ollamaURL, forKey: "ollamaURL") } }
    var ollamaModel: String { didSet { defaults.set(ollamaModel, forKey: "ollamaModel") } }
    var openAIBaseURL: String { didSet { defaults.set(openAIBaseURL, forKey: "openAIBaseURL") } }
    var openAIModel: String { didSet { defaults.set(openAIModel, forKey: "openAIModel") } }
    /// The MLX model: a Hugging Face name ("mlx-community/gemma-4-e4b-it-4bit") or a folder's path.
    var mlxModel: String { didSet { defaults.set(mlxModel, forKey: "mlxModel") } }
    var mlxEmbeddingModel: String { didSet { defaults.set(mlxEmbeddingModel, forKey: "mlxEmbeddingModel") } }
    /// Where MLX models are downloaded from: Hugging Face, or a company's mirror of it.
    var mlxEndpoint: String { didSet { defaults.set(mlxEndpoint, forKey: "mlxEndpoint") } }
    var styles: StyleSettings { didSet { save(styles, "styles") } }

    var voiceCommands: Bool { didSet { defaults.set(voiceCommands, forKey: "voiceCommands") } }
    var autoLearnDictionary: Bool { didSet { defaults.set(autoLearnDictionary, forKey: "autoLearnDictionary") } }
    var smartSpacing: Bool { didSet { defaults.set(smartSpacing, forKey: "smartSpacing") } }
    var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }

    var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: "microphoneUID") } }
    var whisperBoost: Bool { didSet { defaults.set(whisperBoost, forKey: "whisperBoost") } }
    var maxRecordingMinutes: Int { didSet { defaults.set(maxRecordingMinutes, forKey: "maxRecordingMinutes") } }
    var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    var muteAudioWhileDictating: Bool { didSet { defaults.set(muteAudioWhileDictating, forKey: "muteAudioWhileDictating") } }
    var showFlowBarWhenIdle: Bool { didSet { defaults.set(showFlowBarWhenIdle, forKey: "showFlowBarWhenIdle") } }
    var livePreview: Bool { didSet { defaults.set(livePreview, forKey: "livePreview") } }

    var saveAudio: Bool { didSet { defaults.set(saveAudio, forKey: "saveAudio") } }
    /// The one-time notice about telling people they are being recorded has been accepted.
    var recordingNoticeAcknowledged: Bool { didSet { defaults.set(recordingNoticeAcknowledged, forKey: "recordingNoticeAcknowledged") } }
    var audioRetentionDays: Int { didSet { defaults.set(audioRetentionDays, forKey: "audioRetentionDays") } }
    var hasCompletedSetup: Bool { didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") } }

    var meetingDetection: Bool { didSet { defaults.set(meetingDetection, forKey: "meetingDetection") } }
    var meetingAutoStopMinutes: Int { didSet { defaults.set(meetingAutoStopMinutes, forKey: "meetingAutoStopMinutes") } }
    var meetingMaxHours: Int { didSet { defaults.set(meetingMaxHours, forKey: "meetingMaxHours") } }
    var meetingUseCalendar: Bool { didSet { defaults.set(meetingUseCalendar, forKey: "meetingUseCalendar") } }
    var meetingTemplateID: String { didSet { defaults.set(meetingTemplateID, forKey: "meetingTemplateID") } }
    var meetingKeepAudio: Bool { didSet { defaults.set(meetingKeepAudio, forKey: "meetingKeepAudio") } }

    var knowledgeGraph: Bool { didSet { defaults.set(knowledgeGraph, forKey: "knowledgeGraph") } }
    var noteDigests: Bool { didSet { defaults.set(noteDigests, forKey: "noteDigests") } }
    /// Paired phones may connect to Binders on this Mac. Off until the user turns it on: it opens a network port.
    var phoneLink: Bool { didSet { defaults.set(phoneLink, forKey: "phoneLink") } }
    /// "dark", "light" or "system"; Binders is dark unless told otherwise.
    var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    /// The binder new meetings and notes go into: the one last opened in the window.
    var currentBinderID: UUID? { didSet { defaults.set(currentBinderID?.uuidString, forKey: "currentBinderID") } }
    /// Writing capture: which apps may be captured, which sites in browsers, and how long captures are kept.
    var captureApps: [String] { didSet { defaults.set(captureApps, forKey: "captureApps") } }
    /// AI agents in the terminal whose prompts aren't kept: every harness is, unless it's turned off here, so new ones
    /// are on as soon as they're described.
    var captureAgentsOff: [String] { didSet { defaults.set(captureAgentsOff, forKey: "captureAgentsOff") } }
    var captureHosts: [String] { didSet { defaults.set(captureHosts, forKey: "captureHosts") } }
    var captureAllSites: Bool { didSet { defaults.set(captureAllSites, forKey: "captureAllSites") } }
    var captureRetentionDays: Int { didSet { defaults.set(captureRetentionDays, forKey: "captureRetentionDays") } }
    var captureCommitments: Bool { didSet { defaults.set(captureCommitments, forKey: "captureCommitments") } }
    var commitmentReminders: Bool { didSet { defaults.set(commitmentReminders, forKey: "commitmentReminders") } }
    var embeddingModel: String { didSet { defaults.set(embeddingModel, forKey: "embeddingModel") } }

    /// Team space: a folder synced by OneDrive, Dropbox, Google Drive or iCloud Drive.
    var teamFolderPath: String? { didSet { defaults.set(teamFolderPath, forKey: "teamFolderPath") } }
    /// Identifies this person's shared items across Macs and renames.
    let teamMemberID: String
    var teamMemberName: String { didSet { defaults.set(teamMemberName, forKey: "teamMemberName") } }
    var shareMeetingsByDefault: Bool { didSet { defaults.set(shareMeetingsByDefault, forKey: "shareMeetingsByDefault") } }
    var shareNotesByDefault: Bool { didSet { defaults.set(shareNotesByDefault, forKey: "shareNotesByDefault") } }

    var openAIKey: String {
        get { Keychain.read("openai-compatible-key") ?? "" }
        set { Keychain.write(newValue, for: "openai-compatible-key") }
    }

    /// For models that need accepting a licence on Hugging Face, or a company mirror that wants one.
    var mlxToken: String {
        get { Keychain.read("mlx-download-token") ?? "" }
        set { Keychain.write(newValue, for: "mlx-download-token") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("Launch at login change failed: \(error.localizedDescription)")
            }
        }
    }

    private init() {
        hotkeys = Self.load("hotkeys") ?? .default
        speechModel = SpeechModelID(rawValue: defaults.string(forKey: "speechModel") ?? "") ?? .parakeetV3
        language = defaults.string(forKey: "language") ?? "auto"
        vocabularyBoost = defaults.object(forKey: "vocabularyBoost") as? Bool ?? true
        aiFormatting = defaults.object(forKey: "aiFormatting") as? Bool ?? true
        commandModeEnabled = defaults.object(forKey: "commandModeEnabled") as? Bool ?? true
        if let saved = defaults.string(forKey: "llmProvider").flatMap(LLMProviderKind.init(rawValue:)), LLMProviderKind.available.contains(saved) {
            llmProvider = saved
        } else {
            // A new Mac on Apple silicon starts with the model built in: nothing else to install. A Mac that already has
            // Binders' database keeps Ollama, as before, and so does an Intel Mac.
            let isNew = !FileManager.default.fileExists(atPath: AppPaths.store.path)
            let start: LLMProviderKind = MLXModels.isSupported && isNew ? .mlx : .ollama
            llmProvider = start
            UserDefaults.standard.set(start.rawValue, forKey: "llmProvider")
        }
        mlxModel = defaults.string(forKey: "mlxModel") ?? MLXModels.suggested.id
        mlxEmbeddingModel = defaults.string(forKey: "mlxEmbeddingModel") ?? MLXModels.embeddingSuggestion.id
        mlxEndpoint = defaults.string(forKey: "mlxEndpoint") ?? "https://huggingface.co"
        modelIdleMinutes = defaults.object(forKey: "modelIdleMinutes") as? Int ?? 15
        ollamaURL = defaults.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
        ollamaModel = defaults.string(forKey: "ollamaModel") ?? ModelAdvisor.recommendation(memoryGB: ModelAdvisor.memoryGB(bytes: ProcessInfo.processInfo.physicalMemory)).model
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? "http://127.0.0.1:1234/v1"
        openAIModel = defaults.string(forKey: "openAIModel") ?? ""
        styles = Self.load("styles") ?? .default
        voiceCommands = defaults.object(forKey: "voiceCommands") as? Bool ?? true
        autoLearnDictionary = defaults.object(forKey: "autoLearnDictionary") as? Bool ?? true
        smartSpacing = defaults.object(forKey: "smartSpacing") as? Bool ?? true
        restoreClipboard = defaults.object(forKey: "restoreClipboard") as? Bool ?? true
        microphoneUID = defaults.string(forKey: "microphoneUID")
        whisperBoost = defaults.object(forKey: "whisperBoost") as? Bool ?? true
        maxRecordingMinutes = defaults.object(forKey: "maxRecordingMinutes") as? Int ?? 10
        playSounds = defaults.object(forKey: "playSounds") as? Bool ?? true
        muteAudioWhileDictating = defaults.object(forKey: "muteAudioWhileDictating") as? Bool ?? false
        showFlowBarWhenIdle = defaults.object(forKey: "showFlowBarWhenIdle") as? Bool ?? false
        livePreview = defaults.object(forKey: "livePreview") as? Bool ?? true
        saveAudio = defaults.object(forKey: "saveAudio") as? Bool ?? true
        recordingNoticeAcknowledged = defaults.bool(forKey: "recordingNoticeAcknowledged")
        audioRetentionDays = defaults.object(forKey: "audioRetentionDays") as? Int ?? 7
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        meetingDetection = defaults.object(forKey: "meetingDetection") as? Bool ?? true
        meetingAutoStopMinutes = defaults.object(forKey: "meetingAutoStopMinutes") as? Int ?? 10
        meetingMaxHours = defaults.object(forKey: "meetingMaxHours") as? Int ?? 3
        meetingUseCalendar = defaults.object(forKey: "meetingUseCalendar") as? Bool ?? false
        meetingTemplateID = defaults.string(forKey: "meetingTemplateID") ?? "general"
        meetingKeepAudio = defaults.object(forKey: "meetingKeepAudio") as? Bool ?? true
        knowledgeGraph = defaults.object(forKey: "knowledgeGraph") as? Bool ?? true
        noteDigests = defaults.object(forKey: "noteDigests") as? Bool ?? true
        phoneLink = defaults.bool(forKey: "phoneLink")
        appearance = defaults.string(forKey: "appearance") ?? "dark"
        currentBinderID = defaults.string(forKey: "currentBinderID").flatMap(UUID.init(uuidString:))
        captureApps = defaults.stringArray(forKey: "captureApps") ?? WritingCaptureService.defaultApps
        captureAgentsOff = defaults.stringArray(forKey: "captureAgentsOff") ?? []
        captureHosts = defaults.stringArray(forKey: "captureHosts") ?? WritingCaptureService.defaultHosts
        captureAllSites = defaults.object(forKey: "captureAllSites") as? Bool ?? true
        captureRetentionDays = defaults.object(forKey: "captureRetentionDays") as? Int ?? 90
        captureCommitments = defaults.object(forKey: "captureCommitments") as? Bool ?? true
        commitmentReminders = defaults.object(forKey: "commitmentReminders") as? Bool ?? true
        embeddingModel = defaults.string(forKey: "embeddingModel") ?? "embeddinggemma"
        teamFolderPath = defaults.string(forKey: "teamFolderPath")
        if let memberID = UserDefaults.standard.string(forKey: "teamMemberID") {
            teamMemberID = memberID
        } else {
            let memberID = UUID().uuidString
            UserDefaults.standard.set(memberID, forKey: "teamMemberID")
            teamMemberID = memberID
        }
        teamMemberName = defaults.string(forKey: "teamMemberName") ?? ""
        shareMeetingsByDefault = defaults.bool(forKey: "shareMeetingsByDefault")
        shareNotesByDefault = defaults.bool(forKey: "shareNotesByDefault")
    }

    var languageHint: String? { language == "auto" ? nil : language }

    var llmModelName: String {
        switch llmProvider {
        case .ollama: ollamaModel
        case .mlx: mlxModel.hasPrefix("/") ? (mlxModel as NSString).lastPathComponent : (mlxModel.split(separator: "/").last.map(String.init) ?? mlxModel)
        case .openAICompatible: openAIModel
        }
    }

    /// Whether Binders manages the model's memory (as opposed to keeping it loaded).
    var managesModelMemory: Bool { llmProvider == .ollama && modelIdleMinutes > 0 }

    func makeLLMClient() -> LLMClient? {
        switch llmProvider {
        case .ollama:
            guard let url = URL(string: ollamaURL), !ollamaModel.isEmpty else { return nil }
            return OllamaClient(baseURL: url, model: ollamaModel, keepAliveSeconds: modelIdleMinutes <= 0 ? -1 : modelIdleMinutes * 60)
        case .openAICompatible:
            guard let url = URL(string: openAIBaseURL), !openAIModel.isEmpty else { return nil }
            return OpenAICompatibleClient(baseURL: url, model: openAIModel, apiKey: openAIKey.isEmpty ? nil : openAIKey)
        case .mlx:
            guard MLXModels.isSupported, !mlxModel.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return MLXClient(model: mlxModel, idleMinutes: modelIdleMinutes)
        }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
