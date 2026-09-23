import AppKit
import ServiceManagement
import SwiftUI
import BindersKit

/// The categories down the left of Settings. Each is a short page rather than a stop on one long scroll.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, dictation, ai, meetings, knowledge, writing, team, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .dictation: "Dictation"
        case .ai: "AI"
        case .meetings: "Meetings"
        case .knowledge: "Knowledge"
        case .writing: "Writing capture"
        case .team: "Team"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .dictation: "mic"
        case .ai: "sparkles"
        case .meetings: "person.wave.2"
        case .knowledge: "point.3.connected.trianglepath.dotted"
        case .writing: "pencil.line"
        case .team: "person.2"
        case .privacy: "lock.shield"
        }
    }

    /// One line under the title: what the page decides.
    var summary: String {
        switch self {
        case .general: "Appearance, sounds, the Flow bar and updates."
        case .shortcuts: "The keys that start dictation and everything else."
        case .dictation: "Microphone and speech recognition."
        case .ai: "The language model that formats, answers and links."
        case .meetings: "Taking notes on calls."
        case .knowledge: "Search, the graph and note digests."
        case .writing: "What you write in messages and mail, kept once it is sent."
        case .team: "Sharing binders through a folder you already sync."
        case .privacy: "What is kept, for how long, and permissions."
        }
    }
}

/// Settings as pages: a category list on the left, one page's form on the right. The page chosen is remembered.
struct SettingsView: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("settingsPage") private var pageID = SettingsPage.general.rawValue
    @State private var hovered: SettingsPage?

    private var page: SettingsPage { SettingsPage(rawValue: pageID) ?? .general }
    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { dark ? .white : Color(red: 0.11, green: 0.10, blue: 0.20) }

    var body: some View {
        HStack(spacing: 0) {
            pageList
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: openPending)
        .onChange(of: navigation.pendingSettingsPage) { openPending() }
    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { row($0) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .frame(width: 188)
        .background(dark ? Color.white.opacity(0.025) : Color.black.opacity(0.025))
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .general: GeneralSettings()
        case .shortcuts: ShortcutsSettings()
        case .dictation: DictationSettings()
        case .ai: AISettings()
        case .meetings: MeetingsSettings()
        case .knowledge: KnowledgeSettings()
        case .writing: WritingCaptureSettings()
        case .team: TeamSettings()
        case .privacy: PrivacySettings()
        }
    }

    private func row(_ item: SettingsPage) -> some View {
        let selected = page == item
        return Button {
            pageID = item.rawValue
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .foregroundStyle(selected ? Color.accentColor : ink.opacity(0.7))
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(ink.opacity(selected ? 1 : 0.82))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(dark ? 0.28 : 0.16) : (hovered == item ? ink.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { inside in
            if inside { hovered = item } else if hovered == item { hovered = nil }
        }
    }

    private func openPending() {
        guard let pending = navigation.pendingSettingsPage else { return }
        pageID = pending.rawValue
        navigation.pendingSettingsPage = nil
    }
}

/// A settings page: its name, one line on what it decides, then the form.
private struct SettingsPageForm<Content: View>: View {
    let page: SettingsPage
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(page.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 2)
            Form { content }
                .formStyle(.grouped)
        }
    }
}

// MARK: - Pages

private struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings
    // Read once when the page appears: asking launchd and Sparkle on every render blocks the main thread.
    @State private var launchAtLogin = false
    @State private var automaticChecks = false
    @State private var automaticDownloads = false

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .general) {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("Dark").tag("dark")
                    Text("Light").tag("light")
                    Text("Match system").tag("system")
                }
                .onChange(of: settings.appearance) { AppAppearance.apply(settings.appearance) }
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin },
                                                        set: { settings.launchAtLogin = $0; launchAtLogin = settings.launchAtLogin }))
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Mute other audio while dictating", isOn: $settings.muteAudioWhileDictating)
                Toggle("Show live transcript while speaking", isOn: $settings.livePreview)
                Toggle("Always show the Flow bar", isOn: $settings.showFlowBarWhenIdle)
            }

            Section {
                Toggle("Check for updates automatically", isOn: Binding(get: { automaticChecks },
                                                                        set: { UpdateService.shared.automaticChecks = $0; automaticChecks = $0 }))
                Toggle("Download and install updates automatically", isOn: Binding(get: { automaticDownloads },
                                                                                   set: { UpdateService.shared.automaticDownloads = $0; automaticDownloads = $0 }))
                    .disabled(!automaticChecks)
                HStack {
                    Text(UpdateService.versionLine).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { UpdateService.shared.checkNow() }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Binders looks at binders.io for a newer version, at most once a day. Updates are signed and verified before they are installed. Nothing about you is sent.")
            }
        }
        .task {
            automaticChecks = UpdateService.shared.automaticChecks
            automaticDownloads = UpdateService.shared.automaticDownloads
            launchAtLogin = await Task.detached { SMAppService.mainApp.status == .enabled }.value
        }
    }
}

private struct ShortcutsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .shortcuts) {
            Section {
                LabeledContent("Dictation") {
                    HotkeyRecorder(hotkey: Binding(get: { settings.hotkeys.dictation },
                                                   set: { if let value = $0 { settings.hotkeys.dictation = value } }),
                                   allowsNone: false)
                }
                LabeledContent("Command Mode") {
                    HotkeyRecorder(hotkey: $settings.hotkeys.command)
                }
                LabeledContent("Hands-free toggle") {
                    HotkeyRecorder(hotkey: $settings.hotkeys.handsFreeToggle)
                }
                LabeledContent("Paste last transcript") {
                    HotkeyRecorder(hotkey: $settings.hotkeys.pasteLast)
                }
                LabeledContent("Scratchpad") {
                    HotkeyRecorder(hotkey: $settings.hotkeys.scratchpad)
                }
                LabeledContent("Meeting notes") {
                    HotkeyRecorder(hotkey: $settings.hotkeys.meeting)
                }
                LabeledContent("Writing capture on/off") {
                    HotkeyRecorder(hotkey: $settings.hotkeys.capture)
                }
                Button("Reset to defaults") { settings.hotkeys = .default }
            } footer: {
                Text("Hold to talk, release to insert. Double-tap the dictation shortcut to go hands-free, press it again to finish, Esc to cancel.")
            }
        }
    }
}

private struct DictationSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var controller
    @State private var devices: [AudioDevices.Device] = []

    private static let languages: [(String, String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("pt", "Portuguese"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("nl", "Dutch"), ("pl", "Polish"), ("sv", "Swedish"), ("da", "Danish"), ("fi", "Finnish"),
        ("cs", "Czech"), ("sk", "Slovak"), ("ro", "Romanian"), ("hu", "Hungarian"), ("el", "Greek"), ("bg", "Bulgarian"),
        ("hr", "Croatian"), ("sl", "Slovenian"), ("et", "Estonian"), ("lv", "Latvian"), ("lt", "Lithuanian"), ("mt", "Maltese"),
        ("ru", "Russian"), ("uk", "Ukrainian"), ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"), ("hi", "Hindi"),
        ("ar", "Arabic"), ("tr", "Turkish"), ("he", "Hebrew"), ("vi", "Vietnamese"), ("th", "Thai"), ("id", "Indonesian"),
    ]

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .dictation) {
            Section("Microphone") {
                Picker("Input device", selection: $settings.microphoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { Text($0.name).tag(String?.some($0.id)) }
                }
                Toggle("Boost quiet speech (whisper mode)", isOn: $settings.whisperBoost)
                Stepper("Maximum recording: \(settings.maxRecordingMinutes) min", value: $settings.maxRecordingMinutes, in: 1...60)
            }

            Section {
                Picker("Model", selection: $settings.speechModel) {
                    ForEach(SpeechModelID.allCases) { Text($0.displayName).tag($0) }
                }
                Text(settings.speechModel.detail).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Status") {
                    speechStatus
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Boost dictionary words during recognition", isOn: $settings.vocabularyBoost)
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Runs entirely on this Mac. Parakeet v3 covers 25 European languages; use Whisper for others.")
            }
        }
        .task { devices = AudioDevices.inputDevices() }
    }

    @ViewBuilder
    private var speechStatus: some View {
        switch controller.speech.state {
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading \(Int(fraction * 100))%").font(.caption) }.frame(width: 200)
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Loading…") }
        case .failed(let message):
            HStack {
                Text(message).foregroundStyle(.red).lineLimit(2)
                Button("Retry") { controller.speech.activate(settings.speechModel, download: true) }
            }
        case .idle:
            Button("Download") { controller.speech.activate(settings.speechModel, download: true) }
        }
    }
}

private struct AISettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var controller
    @State private var availableModels: [String] = []
    @State private var serverReachable: Bool?
    @State private var askingCustomModel = false
    @State private var customModel = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var residency: ModelResidency?
    @State private var residencyChecked = false
    @State private var unloading = false

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .ai) {
            Section {
                Toggle("AI formatting", isOn: $settings.aiFormatting)
                Toggle("Command Mode", isOn: $settings.commandModeEnabled)
                Picker("Provider", selection: $settings.llmProvider) {
                    ForEach(LLMProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                if settings.llmProvider == .ollama {
                    TextField("Ollama URL", text: $settings.ollamaURL)
                    modelPicker(selection: $settings.ollamaModel)
                    modelAdvice
                    Picker("Free the model's memory", selection: $settings.modelIdleMinutes) {
                        Text("after 5 minutes idle").tag(5)
                        Text("after 15 minutes idle").tag(15)
                        Text("after 30 minutes idle").tag(30)
                        Text("after 1 hour idle").tag(60)
                        Text("never, keep it loaded").tag(0)
                    }
                    HStack {
                        Text(residencyText).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(unloading ? "Unloading…" : "Unload now") {
                            Task {
                                unloading = true
                                await controller.unloadLLM()
                                try? await Task.sleep(for: .seconds(0.5))
                                await refreshResidency()
                                unloading = false
                            }
                        }
                        .disabled(residency == nil || unloading)
                    }
                } else {
                    TextField("Base URL", text: $settings.openAIBaseURL)
                    modelPicker(selection: $settings.openAIModel)
                    SecureField("API key (optional)", text: Binding(get: { settings.openAIKey }, set: { settings.openAIKey = $0 }))
                }
                HStack {
                    Button(testing ? "Testing…" : "Test formatting") { Task { await runTest() } }
                        .disabled(testing)
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                    }
                }
            } header: {
                Text("Language model")
            } footer: {
                Text("Formatting removes filler words, applies your corrections and matches the style of each app. Smaller models are faster; gemma4:26b gives the best cleanup.")
            }

            Section("Inserting text") {
                Toggle("Voice commands (say “press enter” to send)", isOn: $settings.voiceCommands)
                Toggle("Smart spacing between dictations", isOn: $settings.smartSpacing)
                Toggle("Restore clipboard after pasting", isOn: $settings.restoreClipboard)
            }
        }
        .task(id: settings.ollamaModel + settings.ollamaURL) {
            while !Task.isCancelled {
                await refreshResidency()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task(id: "\(settings.llmProvider.rawValue)|\(settings.ollamaURL)|\(settings.openAIBaseURL)") { await loadModels() }
    }

    /// What suits this Mac, a warning when the chosen model is likely too big, and a download for one that isn't installed.
    @ViewBuilder
    private var modelAdvice: some View {
        let pick = ModelDownloader.recommendation
        let memory = ModelDownloader.memoryGB
        let chosen = settings.ollamaModel.trimmed
        let installed = availableModels.contains(chosen) || availableModels.contains(chosen + ":latest")
        let downloader = ModelDownloader.shared
        let installer = OllamaInstaller.shared
        VStack(alignment: .leading, spacing: 6) {
            if serverReachable == false || installer.isWorking {
                if case .downloading(let fraction) = installer.phase {
                    ProgressView(value: fraction) { Text(installer.statusLine ?? "") }
                } else {
                    HStack {
                        Text(installer.statusLine ?? (OllamaInstaller.installedURL != nil
                                                      ? "Ollama is installed but isn't running."
                                                      : "Ollama isn't installed. It is the free software that runs the language model on your Mac."))
                        Spacer()
                        if !installer.isWorking {
                            Button(OllamaInstaller.installedURL != nil ? "Open Ollama" : "Install Ollama…") {
                                Task {
                                    if OllamaInstaller.installedURL != nil {
                                        await installer.open(serverURL: settings.ollamaURL)
                                    } else {
                                        await installer.installWithConsent(serverURL: settings.ollamaURL)
                                    }
                                    await loadModels()
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                if chosen == pick.model {
                    Text("\(pick.model) is the model suggested for this Mac's \(memory) GB of memory.")
                } else if ModelAdvisor.isTooLarge(chosen, memoryGB: memory) {
                    Text("\(chosen) is likely too large for \(memory) GB of memory. Suggested: \(pick.model).").foregroundStyle(.orange)
                } else {
                    Text("Suggested for this Mac's \(memory) GB of memory: \(pick.model). \(pick.reason)")
                }
                Spacer()
                if chosen != pick.model { Button("Use") { settings.ollamaModel = pick.model } }
            }
            if let downloading = downloader.model {
                ProgressView(value: downloader.progress ?? 0) { Text("Downloading \(downloading)…") }
            } else if !chosen.isEmpty, !installed, !availableModels.isEmpty || downloader.error != nil {
                HStack {
                    Text(downloader.error ?? "\(chosen) isn't installed in Ollama yet.")
                    Spacer()
                    Button("Download") {
                        Task {
                            await downloader.pull(chosen, from: settings.ollamaURL)
                            await loadModels()
                        }
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// A real menu: the sizes that suit different Macs, whatever else is installed, and a way to type any other name.
    private func modelPicker(selection: Binding<String>) -> some View {
        let current = selection.wrappedValue.trimmed
        let isOllama = settings.llmProvider == .ollama
        let suggested = isOllama ? ModelAdvisor.tiers.map(\.recommendation).reversed() : []
        let suggestedNames = Set(suggested.map(\.model))
        let others = availableModels.filter { !suggestedNames.contains($0) && !$0.lowercased().contains("embed") }
        func installed(_ name: String) -> Bool { availableModels.contains(name) || availableModels.contains(name + ":latest") }
        return LabeledContent("Model") {
            Menu {
                if isOllama {
                    Section("Gemma 4, by Mac memory") {
                        ForEach(Array(suggested), id: \.model) { pick in
                            Button {
                                selection.wrappedValue = pick.model
                            } label: {
                                let fits = pick.model == ModelDownloader.recommendation.model ? " · suggested for this Mac" : ""
                                let state = installed(pick.model) ? "installed" : "\(pick.downloadGB.formatted()) GB download"
                                Label("\(pick.model) · \(state)\(fits)", systemImage: current == pick.model ? "checkmark" : "")
                            }
                        }
                    }
                }
                if !others.isEmpty {
                    Section(isOllama ? "Also installed" : "Available on your server") {
                        ForEach(others, id: \.self) { model in
                            Button { selection.wrappedValue = model } label: {
                                Label(model, systemImage: current == model ? "checkmark" : "")
                            }
                        }
                    }
                }
                Divider()
                Button("Other…") {
                    customModel = current
                    askingCustomModel = true
                }
            } label: {
                Text(current.isEmpty ? "Choose a model" : current)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .alert("Use another model", isPresented: $askingCustomModel) {
            TextField(isOllama ? "An Ollama tag, such as gemma4:12b" : "The model name your server expects", text: $customModel)
            Button("Use") {
                let name = customModel.trimmed
                guard !name.isEmpty else { return }
                if isOllama { settings.ollamaModel = name } else { settings.openAIModel = name }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(isOllama ? "Any model from the Ollama library works. If it isn't installed yet, Binders offers to download it." : "Type the model name exactly as your server lists it.")
        }
    }

    private func loadModels() async {
        let client: LLMClient?
        switch settings.llmProvider {
        case .ollama: client = URL(string: settings.ollamaURL).map { OllamaClient(baseURL: $0, model: "") }
        case .openAICompatible:
            client = URL(string: settings.openAIBaseURL).map { OpenAICompatibleClient(baseURL: $0, model: "", apiKey: settings.openAIKey.isEmpty ? nil : settings.openAIKey) }
        }
        do {
            availableModels = try await client?.listModels() ?? []
            serverReachable = true
        } catch {
            availableModels = []
            serverReachable = false
        }
    }

    private var residencyText: String {
        guard settings.llmProvider == .ollama else { return "" }
        guard residencyChecked else { return "Checking whether the model is in memory…" }
        guard let residency else { return "\(settings.ollamaModel) is not in memory. It loads when a dictation starts, or when notes, digests or promises need it." }
        let size = ByteCountFormatter.string(fromByteCount: residency.bytes, countStyle: .memory)
        if let expires = residency.expiresAt {
            let minutes = max(0, Int(expires.timeIntervalSinceNow / 60))
            return "\(settings.ollamaModel) is in memory (\(size)) · frees in \(minutes < 1 ? "under a minute" : "\(minutes) min") unless used again"
        }
        return "\(settings.ollamaModel) is in memory (\(size)) · kept loaded"
    }

    private func refreshResidency() async {
        guard settings.llmProvider == .ollama, let client = settings.makeLLMClient() else { residency = nil; residencyChecked = true; return }
        residency = await client.residency()
        residencyChecked = true
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        let start = Date()
        let result = await controller.format(raw: "um so I think we should uh meet at 2 actually no 3 pm tomorrow and bring the the slides",
                                             context: AppContext(appName: "Settings"))
        let millis = Int(Date().timeIntervalSince(start) * 1000)
        if result.usedLLM {
            testResult = "✓ \(millis) ms — \(result.text)"
        } else {
            testResult = "✗ \(result.fallbackReason ?? "AI formatting is off") — \(result.text)"
        }
    }
}

private struct MeetingsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .meetings) {
            Section {
                Toggle("Offer to take notes when a call starts", isOn: $settings.meetingDetection)
                Picker("Notes template", selection: $settings.meetingTemplateID) {
                    ForEach(MeetingTemplate.all) { Text($0.name).tag($0.id) }
                }
                Picker("Stop after silence", selection: $settings.meetingAutoStopMinutes) {
                    Text("Never").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Maximum length", selection: $settings.meetingMaxHours) {
                    ForEach([1, 2, 3, 4], id: \.self) { Text("\($0) hours").tag($0) }
                }
                Toggle("Keep meeting audio", isOn: $settings.meetingKeepAudio)
                Toggle("Use Calendar for titles and attendees", isOn: Binding(
                    get: { settings.meetingUseCalendar },
                    set: { enabled in
                        settings.meetingUseCalendar = enabled
                        guard enabled else { return }
                        Task { if !(await CalendarContext.requestAccess()) { settings.meetingUseCalendar = false } }
                    }))
                LabeledContent("System audio access") {
                    Button("Open Privacy Settings") { Permissions.openSystemAudioSettings() }
                }
            } footer: {
                Text("Records your mic and the call's audio on this Mac — no bot joins. Transcripts, speaker labels and notes are all produced locally.")
            }
        }
    }
}

private struct KnowledgeSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KnowledgeService.self) private var knowledge
    @State private var ignoredEntities: [KnowledgeStore.IgnoredEntity] = []

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .knowledge) {
            Section {
                Toggle("Link people, projects and topics (uses your language model)", isOn: $settings.knowledgeGraph)
                Toggle("Write digests for notes: title, summary, to-dos (uses your language model)", isOn: $settings.noteDigests)
                HStack {
                    TextField("Embedding model", text: $settings.embeddingModel)
                    Button(knowledge.pullProgress == nil ? "Download" : "Downloading…") {
                        Task { await knowledge.pullEmbeddingModel() }
                    }
                    .disabled(knowledge.pullProgress != nil || settings.llmProvider != .ollama)
                }
                if let progress = knowledge.pullProgress {
                    ProgressView(value: progress)
                }
                LabeledContent("Index") {
                    Text(knowledge.status.summary).foregroundStyle(.secondary)
                }
                if let issue = knowledge.status.embeddingIssue ?? knowledge.status.extractionIssue {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
                Button("Rebuild index") { Task { await knowledge.rebuild() } }
                if !ignoredEntities.isEmpty {
                    DisclosureGroup("Removed names (\(ignoredEntities.count))") {
                        ForEach(ignoredEntities) { item in
                            HStack {
                                Text(item.name)
                                Text(item.type).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Restore") { Task { await knowledge.restore(ignoredKey: item.key) } }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            } footer: {
                Text("Search combines keywords with meaning, using a small local embedding model (embeddinggemma). Nothing leaves this Mac. Names removed from Knowledge stay out until restored here.")
            }
        }
        .task(id: knowledge.revision) { ignoredEntities = await knowledge.ignoredEntities() }
    }
}

private struct WritingCaptureSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .writing) {
            Section {
                ForEach(WritingCaptureService.knownApps, id: \.bundleID) { app in
                    Toggle(isOn: Binding(get: { settings.captureApps.contains(app.bundleID) },
                                         set: { on in
                                             if on { settings.captureApps.append(app.bundleID) } else { settings.captureApps.removeAll { $0 == app.bundleID } }
                                         })) {
                        HStack(spacing: 6) {
                            Text(app.name)
                            if app.isBrowser { Text(settings.captureAllSites ? "any site" : "listed sites only").font(.caption).foregroundStyle(.secondary) }
                            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) == nil {
                                Text("not installed").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Toggle("Capture on any site (login, payment and banking pages are always skipped)", isOn: $settings.captureAllSites)
                if !settings.captureAllSites {
                    TextField("Listed sites", text: Binding(
                        get: { settings.captureHosts.joined(separator: ", ") },
                        set: { settings.captureHosts = $0.components(separatedBy: CharacterSet(charactersIn: ", ")).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }),
                              axis: .vertical)
                        .lineLimit(1...4)
                }
            } header: {
                Text("Where")
            } footer: {
                Text("Off until you switch it on (\(settings.hotkeys.capture?.displayString() ?? "menu bar") or the menu bar). While on, what you write in these apps is kept once you send or save it, filed in the open binder and indexed like a note. Keystrokes are never recorded, secure fields are never read, and card numbers, passwords and keys are redacted before anything is stored. Everything stays on this Mac.")
            }

            Section("What happens to it") {
                Stepper("Keep captured writing for \(settings.captureRetentionDays) days", value: $settings.captureRetentionDays, in: 7...730, step: 7)
                Toggle("Turn promises and asks in captured messages into to-dos (uses your language model)", isOn: $settings.captureCommitments)
                Toggle("Remind me on the day a promise is due", isOn: $settings.commitmentReminders)
                Button("Open the capture log") { HubWindowController.shared.show(section: .writing) }
            }
        }
    }
}

private struct TeamSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TeamSyncService.self) private var team
    @State private var confirmLeave = false
    @State private var teamError: String?

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .team) {
            Section {
                TextField("Your name", text: $settings.teamMemberName, prompt: Text(NSFullUserName()))
                if let folder = team.folderURL {
                    LabeledContent("Team space") {
                        HStack {
                            Text(team.status.teamName ?? folder.lastPathComponent)
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                        }
                    }
                    LabeledContent("Folder") {
                        Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    LabeledContent("Members") {
                        let others = team.status.members.filter { $0.id != settings.teamMemberID }.map(\.name)
                        Text(others.isEmpty ? "Just you so far — share this folder with your team" : others.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    Text("Sharing is per binder: flip the switch on a binder and everything in it, including what you add later, syncs to the team.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    LabeledContent("Sync") {
                        Text(teamSyncSummary).foregroundStyle(.secondary)
                    }
                    if let error = team.status.error {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Sync now") { Task { await team.syncNow() } }
                        Spacer()
                        Button("Leave team space…", role: .destructive) { confirmLeave = true }
                    }
                } else {
                    HStack {
                        Button("Create team space…") { chooseTeamFolder(create: true) }
                        Button("Join team space…") { chooseTeamFolder(create: false) }
                    }
                    if let teamError {
                        Text(teamError).font(.caption).foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Share meetings and notes with your team through a folder synced by OneDrive, Dropbox, Google Drive or iCloud Drive — no server. Only what you share leaves this Mac (never audio), and it's stored as Markdown, so the folder also opens as an Obsidian vault.")
            }
        }
        .confirmationDialog("Leave the team space?", isPresented: $confirmLeave) {
            Button("Leave", role: .destructive) { Task { await team.leave() } }
        } message: {
            Text("Teammates' meetings and notes are removed from this Mac. What you already shared stays in the team folder.")
        }
    }

    private var teamSyncSummary: String {
        let status = team.status
        var parts = [status.lastSync.map { "Synced \($0.formatted(date: .omitted, time: .shortened))" } ?? "Not synced yet"]
        parts.append("you share \(status.sharedMeetings) meetings and \(status.sharedNotes) notes")
        parts.append("\(status.teamMeetings + status.teamNotes) from teammates")
        return parts.joined(separator: " · ")
    }

    private func chooseTeamFolder(create: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = create ? "Create Team Space" : "Join"
        panel.message = create
            ? "Choose or create an empty folder in OneDrive, Dropbox, Google Drive or iCloud Drive, then share that folder with your team."
            : "Choose the team folder a teammate shared with you."
        let cloudStorage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        if FileManager.default.fileExists(atPath: cloudStorage.path) { panel.directoryURL = cloudStorage }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if create { try team.createTeam(at: url) } else { try team.join(folder: url) }
            teamError = nil
        } catch {
            teamError = error.localizedDescription
        }
    }
}

private struct PrivacySettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(DictationController.self) private var controller
    @State private var confirmDelete = false
    /// Bumped when Binders comes to the front, e.g. back from System Settings, so permission labels catch up.
    @State private var permissionsRevision = 0

    var body: some View {
        @Bindable var settings = settings
        SettingsPageForm(page: .privacy) {
            Section("Your data") {
                Toggle("Keep audio for re-transcription", isOn: $settings.saveAudio)
                Stepper("Delete audio after \(settings.audioRetentionDays) days", value: $settings.audioRetentionDays, in: 1...90)
                HStack {
                    Button("Open data folder") { NSWorkspace.shared.open(AppPaths.support) }
                    Button("Acknowledgements") {
                        if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") { NSWorkspace.shared.open(url) }
                    }
                    Spacer()
                    Button("Delete all history", role: .destructive) { confirmDelete = true }
                }
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    permissionStatus(Permissions.microphone == .authorized) { Permissions.openMicrophoneSettings() }
                }
                LabeledContent("Accessibility") {
                    permissionStatus(Permissions.accessibility) {
                        Permissions.promptAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
                LabeledContent("Keyboard listener") {
                    Text(controller.hotkeys.isRunning ? "Active" : "Waiting for Accessibility").foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Delete all dictation history and saved audio?", isPresented: $confirmDelete) {
            Button("Delete All", role: .destructive) { Store.shared.deleteAllHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissionsRevision += 1 }
    }

    private func permissionStatus(_ granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            let _ = permissionsRevision
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Grant…", action: open)
            }
        }
    }
}

// MARK: - Shortcut recorder

struct HotkeyRecorder: View {
    @Environment(DictationController.self) private var controller
    @Binding var hotkey: Hotkey?
    var allowsNone = true
    @State private var recording = false
    @State private var monitor: Any?
    @State private var peak: ModifierSet = []

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : startRecording()
            } label: {
                Text(recording ? "Press shortcut…" : (hotkey?.displayString(keyName: KeyCode.name) ?? "Not set"))
                    .frame(minWidth: 120)
            }
            if allowsNone, hotkey != nil, !recording {
                Button { hotkey = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
        // Leaving the app mid-recording would otherwise keep every global shortcut paused.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func startRecording() {
        recording = true
        peak = []
        controller.hotkeys.isPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let modifiers = Self.modifiers(event.modifierFlags)
            if event.type == .keyDown {
                if event.keyCode == KeyCode.escape, modifiers.subtracting(.function).isEmpty {
                    stop()
                    return nil
                }
                let combo = modifiers.subtracting(.function)
                let isFunctionKey = KeyCode.name(event.keyCode).hasPrefix("F")
                guard !combo.subtracting(.shift).isEmpty || isFunctionKey else {
                    NSSound.beep()
                    return nil
                }
                hotkey = Hotkey(modifiers: combo, keyCode: event.keyCode)
                stop()
                return nil
            }
            if modifiers.isEmpty {
                if !peak.isEmpty {
                    hotkey = Hotkey(modifiers: peak)
                    stop()
                }
            } else {
                peak.formUnion(modifiers)
            }
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        controller.hotkeys.isPaused = false
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ModifierSet {
        var result = ModifierSet()
        if flags.contains(.function) { result.insert(.function) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}
