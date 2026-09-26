import AppKit
import ServiceManagement
import SwiftUI
import BindersKit

/// The categories down the left of Settings. Each is a short page rather than a stop on one long scroll.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, dictation, ai, meetings, knowledge, writing, automations, mcp, team, privacy

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
        case .automations: "Automations"
        case .mcp: "MCP"
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
        case .automations: "bolt"
        case .mcp: "cable.connector"
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
        case .automations: "Rules that run Shortcuts, scripts and web hooks, and links from other apps."
        case .mcp: "Let Claude Code, Claude Desktop and other AI tools search, ask and add to your knowledge base."
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
        case .automations: AutomationsSettings()
        case .mcp: MCPSettings()
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
    @State private var recordingField: HotkeyBindings.Field?
    @State private var conflict: ShortcutConflict?

    var body: some View {
        SettingsPageForm(page: .shortcuts) {
            Section {
                ForEach(HotkeyBindings.Field.allCases, id: \.self) { field in
                    LabeledContent(field.title) {
                        ShortcutField(field: field, hotkey: settings.hotkeys[field], recordingField: $recordingField,
                                      onRecord: { record($0, for: field) }, onClear: { settings.hotkeys[field] = nil })
                    }
                    if let conflict, conflict.field == field {
                        conflictRow(conflict)
                    }
                }
                Button("Reset to defaults") {
                    conflict = nil
                    settings.hotkeys = .default
                }
            } footer: {
                Text("Hold to talk, release to insert. Double-tap the dictation shortcut to go hands-free, press it again to finish, Esc to cancel. The other shortcuts can be a key combination such as ⌥S, or a modifier tapped twice: click, then tap ⌥ twice.")
            }
        }
    }

    private func record(_ hotkey: Hotkey, for field: HotkeyBindings.Field) {
        conflict = nil
        if let other = settings.hotkeys.conflict(for: hotkey, in: field) {
            conflict = ShortcutConflict(field: field, hotkey: hotkey, other: other)
        } else {
            settings.hotkeys[field] = hotkey
        }
    }

    @ViewBuilder
    private func conflictRow(_ conflict: ShortcutConflict) -> some View {
        let name = conflict.hotkey.displayString(keyName: KeyCode.name)
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            if conflict.other == .dictation {
                Text("\(name) is how you dictate. Pick another shortcut.")
                Spacer()
                Button("OK") { self.conflict = nil }
            } else {
                Text("\(name) is already used for \(conflict.other.title).")
                Spacer()
                Button("Use it here") {
                    settings.hotkeys[conflict.other] = nil
                    settings.hotkeys[conflict.field] = conflict.hotkey
                    self.conflict = nil
                }
                Button("Cancel") { self.conflict = nil }
            }
        }
        .font(.callout)
    }
}

private struct ShortcutConflict: Equatable {
    let field: HotkeyBindings.Field
    let hotkey: Hotkey
    let other: HotkeyBindings.Field
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

// MARK: - Automations

private struct AutomationsSettings: View {
    private let service = AutomationService.shared
    @State private var editing: AutomationRule?
    @State private var deleting: AutomationRule?

    private static let links: [(String, String)] = [
        ("Add a to-do", "binders://todo?text=call%20Sam%20tomorrow"),
        ("Add to the calendar", "binders://calendar?text=lunch%20with%20Sam%20tomorrow%20at%20noon"),
        ("Ask the knowledge base", "binders://ask?q=what%20did%20we%20decide%20about%20pricing"),
        ("Start or stop hands-free dictation", "binders://dictate"),
        ("Writing capture on or off", "binders://capture/toggle"),
        ("Start or stop meeting notes", "binders://meeting/toggle"),
    ]

    var body: some View {
        SettingsPageForm(page: .automations) {
            Section {
                if service.rules.isEmpty {
                    Text("No rules yet. A rule runs a Shortcut, opens a URL, runs a script or calls a web hook, either when you say a phrase in Command Mode (hold fn ⌃) or when something happens in Binders.")
                        .foregroundStyle(.secondary)
                }
                ForEach(service.rules) { rule in
                    ruleRow(rule)
                }
                Button("Add rule…") {
                    editing = AutomationRule(name: "", trigger: .phrase(text: ""), action: .shortcut(name: "", input: "{text}"))
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Placeholders: {text}, {title}, {when}, {date}, {app}, {binder}, {summary}, {link}. What you say after a phrase is {text}; a time at its end becomes {when} and {date}. Rules are kept in automations.json in the data folder. A web hook sends its payload to the address you give it; nothing else leaves this Mac.")
            }

            Section {
                ForEach(Self.links, id: \.1) { title, link in
                    LabeledContent(title) {
                        HStack(spacing: 6) {
                            Text(link).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            copyButton(link)
                        }
                    }
                }
            } header: {
                Text("From other apps")
            } footer: {
                Text("Anything that can open a link can drive Binders: Shortcuts, Raycast, Alfred, Keyboard Maestro, a script. Text goes in the query, percent-encoded. AI tools connect through the MCP page instead.")
            }
        }
        .sheet(item: $editing) { rule in
            AutomationEditor(rule: rule) { saved in service.upsert(saved) }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { rule in
            Button("Delete", role: .destructive) { service.remove(rule.id) }
        }
    }

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled" : rule.name).fontWeight(.medium)
                Text("\(Self.describe(rule.trigger)) → \(Self.describe(rule.action))").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let outcome = service.outcomes[rule.id] {
                    Text("\(outcome.ok ? "✓" : "✗") \(outcome.message) · \(outcome.at.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(outcome.ok ? Color.secondary : Color.orange).lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { service.setEnabled(rule.id, $0) })).labelsHidden()
            Button("Edit") { editing = rule }
            Button { deleting = rule } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    private func copyButton(_ text: String) -> some View {
        CopyButton(text: text)
    }

    static func describe(_ trigger: AutomationRule.Trigger) -> String {
        switch trigger {
        case .phrase(let text): "Say “\(text)”"
        case .event(let name): name.title
        }
    }

    static func describe(_ action: AutomationRule.Action) -> String {
        switch action {
        case .shortcut(let name, _): "run Shortcut “\(name)”"
        case .openURL(let template): "open \(template)"
        case .script(let command): "run `\(command.prefix(40))`"
        case .webhook(let url, _): "POST to \(url)"
        }
    }
}

/// Copies a line to the clipboard.
private struct CopyButton: View {
    let text: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

// MARK: - MCP

/// The Model Context Protocol server: what it offers, and the tools it can be added to.
private struct MCPSettings: View {
    @State private var hostMessages: [MCPHost: String] = [:]
    @State private var showingInstructions: MCPHost?
    /// Bumped after adding to a tool, so its row re-reads the configuration.
    @State private var hostRevision = 0

    private var executable: String { MCPHost.executable }
    private var mcpJSON: String { "{\"mcpServers\":{\"binders\":{\"command\":\"\(executable)\",\"args\":[\"--mcp\"]}}}" }
    private var readingTools: [String] { MCPServer.tools.map(\.name).filter { !Self.isWrite($0) } }
    private var addingTools: [String] { MCPServer.tools.map(\.name).filter(Self.isWrite) }

    private static func isWrite(_ name: String) -> Bool {
        ["add_", "append_", "create_", "set_"].contains { name.hasPrefix($0) }
    }

    var body: some View {
        SettingsPageForm(page: .mcp) {
            Section {
                LabeledContent("Command") {
                    HStack(spacing: 6) {
                        Text("\(executable) --mcp").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        CopyButton(text: "\(executable) --mcp")
                    }
                }
                LabeledContent("Reads") {
                    Text(readingTools.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                LabeledContent("Adds") {
                    Text(addingTools.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("A tool that supports the Model Context Protocol starts this command and talks to it over a pipe. It runs only while that tool is connected, reads the same data the app does, and everything stays on this Mac. Reads go straight to the database; anything added is handed to the app, so your windows update and the index picks it up. Nothing can be deleted this way.")
            }

            Section {
                ForEach(MCPHost.allCases) { host in
                    hostRow(host)
                }
            } header: {
                Text("Add it to a tool")
            } footer: {
                Text("Each tool keeps its servers in its own file. Binders makes a dated backup beside that file first, and changes only the binders entry. The ⓘ button shows how to do it by hand.")
            }

            Section {
                LabeledContent("Configuration") {
                    HStack(spacing: 6) {
                        Text(mcpJSON).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        CopyButton(text: mcpJSON)
                    }
                }
            } header: {
                Text("Anything else")
            } footer: {
                Text("Any other host that takes a stdio server wants the same two things: the command above and the argument --mcp.")
            }
        }
    }

    /// One tool: whether it is here, whether Binders is in it, a button to add it, and the way to do it by hand.
    private func hostRow(_ host: MCPHost) -> some View {
        let _ = hostRevision
        let status = host.status
        return LabeledContent(host.name) {
            HStack(spacing: 8) {
                if let message = hostMessages[host] {
                    Text(message).font(.caption).foregroundStyle(message.hasPrefix("Added") ? Color.secondary : Color.orange).lineLimit(2)
                } else if !status.present {
                    Text("Not found on this Mac").font(.caption).foregroundStyle(.tertiary)
                } else if status.configured {
                    Label("Added", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                Button(status.configured ? "Add again" : "Add") {
                    Task {
                        do {
                            hostMessages[host] = try await host.add()
                        } catch {
                            hostMessages[host] = error.localizedDescription
                        }
                        hostRevision += 1
                    }
                }
                .disabled(!status.present)
                Button {
                    showingInstructions = host
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("How to add it by hand")
                .popover(isPresented: Binding(get: { showingInstructions == host }, set: { if !$0 { showingInstructions = nil } })) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(host.instructions).font(.body.monospaced()).textSelection(.enabled)
                        HStack {
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(host.instructions, forType: .string)
                            }
                        }
                    }
                    .padding(14)
                    .frame(width: 520)
                }
            }
        }
    }
}

/// One rule, edited in a sheet. The trigger and action are picked by kind; only the fields that kind needs show.
private struct AutomationEditor: View {
    enum TriggerKind: String, CaseIterable, Identifiable {
        case phrase, event
        var id: String { rawValue }
    }
    enum ActionKind: String, CaseIterable, Identifiable {
        case shortcut, url, script, webhook
        var id: String { rawValue }
        var title: String {
            switch self {
            case .shortcut: "Run a Shortcut"
            case .url: "Open a URL"
            case .script: "Run a script"
            case .webhook: "Call a web hook"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let onSave: (AutomationRule) -> Void
    private let id: UUID
    private let isEnabled: Bool
    @State private var name: String
    @State private var triggerKind: TriggerKind
    @State private var phrase = ""
    @State private var event: AutomationEvent = .todoAdded
    @State private var actionKind: ActionKind
    @State private var shortcutName = ""
    @State private var shortcutInput = "{text}"
    @State private var urlTemplate = ""
    @State private var script = ""
    @State private var webhookURL = ""
    @State private var webhookBody = ""
    @State private var shortcuts: [String] = []
    @State private var testing = false
    @State private var testOutcome: AutomationService.Outcome?

    init(rule: AutomationRule, onSave: @escaping (AutomationRule) -> Void) {
        self.onSave = onSave
        id = rule.id
        isEnabled = rule.isEnabled
        _name = State(initialValue: rule.name)
        switch rule.trigger {
        case .phrase(let text):
            _triggerKind = State(initialValue: .phrase)
            _phrase = State(initialValue: text)
        case .event(let name):
            _triggerKind = State(initialValue: .event)
            _event = State(initialValue: name)
        }
        switch rule.action {
        case .shortcut(let name, let input):
            _actionKind = State(initialValue: .shortcut)
            _shortcutName = State(initialValue: name)
            _shortcutInput = State(initialValue: input)
        case .openURL(let template):
            _actionKind = State(initialValue: .url)
            _urlTemplate = State(initialValue: template)
        case .script(let command):
            _actionKind = State(initialValue: .script)
            _script = State(initialValue: command)
        case .webhook(let url, let body):
            _actionKind = State(initialValue: .webhook)
            _webhookURL = State(initialValue: url)
            _webhookBody = State(initialValue: body)
        }
    }

    private var rule: AutomationRule {
        let trigger: AutomationRule.Trigger = triggerKind == .phrase ? .phrase(text: phrase.trimmed) : .event(name: event)
        let action: AutomationRule.Action
        switch actionKind {
        case .shortcut: action = .shortcut(name: shortcutName.trimmed, input: shortcutInput)
        case .url: action = .openURL(template: urlTemplate.trimmed)
        case .script: action = .script(command: script)
        case .webhook: action = .webhook(url: webhookURL.trimmed, body: webhookBody)
        }
        return AutomationRule(id: id, name: name.trimmed, isEnabled: isEnabled, trigger: trigger, action: action)
    }

    private var isComplete: Bool {
        guard !name.trimmed.isEmpty else { return false }
        if triggerKind == .phrase, phrase.trimmed.isEmpty { return false }
        switch actionKind {
        case .shortcut: return !shortcutName.trimmed.isEmpty
        case .url: return !urlTemplate.trimmed.isEmpty
        case .script: return !script.trimmed.isEmpty
        case .webhook: return !webhookURL.trimmed.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Send to Things"))
                }
                Section("When") {
                    Picker("Trigger", selection: $triggerKind) {
                        Text("I say a phrase in Command Mode").tag(TriggerKind.phrase)
                        Text("Something happens in Binders").tag(TriggerKind.event)
                    }
                    if triggerKind == .phrase {
                        TextField("Phrase", text: $phrase, prompt: Text("send to things"))
                        Text("Hold fn ⌃ and say the phrase, then the rest: what follows is {text}; a time at the end becomes {when} and {date}.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Event", selection: $event) {
                            ForEach(AutomationEvent.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                Section("Do") {
                    Picker("Action", selection: $actionKind) {
                        ForEach(ActionKind.allCases) { Text($0.title).tag($0) }
                    }
                    switch actionKind {
                    case .shortcut:
                        if shortcuts.isEmpty {
                            TextField("Shortcut name", text: $shortcutName)
                        } else {
                            Picker("Shortcut", selection: $shortcutName) {
                                Text("Choose…").tag("")
                                if !shortcutName.isEmpty, !shortcuts.contains(shortcutName) { Text(shortcutName).tag(shortcutName) }
                                ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        TextField("Input the Shortcut receives", text: $shortcutInput, prompt: Text("{text}"))
                    case .url:
                        TextField("URL", text: $urlTemplate, prompt: Text("things:///add?title={title}&when={date}"))
                        Text("Placeholders are percent-encoded, so they are safe inside a query.").font(.caption).foregroundStyle(.secondary)
                    case .script:
                        TextField("Command (zsh)", text: $script, prompt: Text("echo \"$BINDERS_TEXT\" >> ~/log.txt"), axis: .vertical)
                            .lineLimit(2...6)
                            .font(.body.monospaced())
                        Text("The payload arrives as BINDERS_TEXT, BINDERS_TITLE, BINDERS_WHEN, BINDERS_DATE… and the text on standard input.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .webhook:
                        TextField("URL", text: $webhookURL, prompt: Text("https://…"))
                        TextField("JSON body", text: $webhookBody, prompt: Text("Leave empty to send every field"), axis: .vertical)
                            .lineLimit(2...6)
                            .font(.body.monospaced())
                        Text("Placeholders are escaped for JSON. This sends the payload off this Mac, to the address above.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack {
                        Button(testing ? "Testing…" : "Test with sample text") {
                            Task {
                                testing = true
                                testOutcome = await AutomationService.shared.run(rule, payload: AutomationService.sample, quietly: true)
                                testing = false
                            }
                        }
                        .disabled(!isComplete || testing)
                        if let testOutcome {
                            Text("\(testOutcome.ok ? "✓" : "✗") \(testOutcome.message)").font(.caption).foregroundStyle(testOutcome.ok ? Color.secondary : Color.orange).lineLimit(2)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(rule)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete)
            }
            .padding(12)
        }
        .frame(width: 580, height: 560)
        .task { shortcuts = await AutomationService.installedShortcuts() }
    }
}

// MARK: - Shortcut recorder

/// One shortcut in Settings. Recording goes through the same event tap that runs the shortcuts, which hands every key
/// to the recorder meanwhile: pressing a shortcut that is already set records it instead of doing it.
private struct ShortcutField: View {
    @Environment(DictationController.self) private var controller
    let field: HotkeyBindings.Field
    let hotkey: Hotkey?
    @Binding var recordingField: HotkeyBindings.Field?
    let onRecord: (Hotkey) -> Void
    let onClear: () -> Void

    @State private var recorder = ShortcutRecorder(isHold: false)
    @State private var live = ""
    @State private var hint: String?
    @State private var localMonitor: Any?
    @State private var tick: Task<Void, Never>?

    private var isRecording: Bool { recordingField == field }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    isRecording ? stop() : start()
                } label: {
                    Text(isRecording ? (live.isEmpty ? "Press keys… (Esc cancels)" : live) : (hotkey?.displayString(keyName: KeyCode.name) ?? "Not set"))
                        .monospacedDigit()
                        .frame(minWidth: 150)
                }
                .tint(isRecording ? .accentColor : nil)
                .buttonStyle(.bordered)
                // Always there, hidden when it can't be used, so every field lines up.
                let clearable = field != .dictation && hotkey != nil && !isRecording
                Button(action: onClear) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this shortcut")
                    .opacity(clearable ? 1 : 0)
                    .disabled(!clearable)
                    .accessibilityHidden(!clearable)
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: recordingField) { _, current in
            if current != field { stop(clearOwner: false) }
        }
        .onDisappear { stop() }
        // Leaving the app mid-recording would otherwise keep the shortcuts off.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        recordingField = field
        recorder = ShortcutRecorder(isHold: field.isHold)
        live = ""
        hint = field.isHold ? nil : "A key combination, or tap a modifier twice."
        if !controller.hotkeys.startRecording({ input, time in handle(input, at: time) }) {
            // No event tap (Accessibility is off): listen to this window instead.
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                let modifiers = Self.modifiers(event.modifierFlags)
                let input: HotkeyInput = event.type == .keyDown
                    ? .keyDown(keyCode: event.keyCode, modifiers: modifiers, isRepeat: event.isARepeat)
                    : .flagsChanged(modifiers)
                handle(input, at: ProcessInfo.processInfo.systemUptime)
                return nil
            }
        }
    }

    private func handle(_ input: HotkeyInput, at time: TimeInterval) {
        guard isRecording else { return }
        apply(recorder.handle(input, at: time))
    }

    private func apply(_ outcome: ShortcutRecorder.Outcome) {
        switch outcome {
        case .listening(let held):
            live = held.isEmpty ? "" : "\(held)…"
        case .awaitingSecondTap(let modifiers):
            live = "Tap \(modifiers.symbols) again…"
            tick?.cancel()
            let window = recorder.doubleTapWindow
            tick = Task { @MainActor in
                try? await Task.sleep(for: .seconds(window + 0.05))
                guard !Task.isCancelled, isRecording, let late = recorder.tick(at: ProcessInfo.processInfo.systemUptime) else { return }
                apply(late)
            }
        case .recorded(let hotkey):
            stop()
            hint = nil
            onRecord(hotkey)
        case .cancelled:
            stop()
            hint = nil
        case .rejected(let reason):
            live = ""
            hint = reason
        }
    }

    /// Ends this field's recording. Only the field that is recording hands the keyboard back to the shortcuts; when
    /// another field has just started (`clearOwner` false), the keyboard is already theirs.
    private func stop(clearOwner: Bool = true) {
        tick?.cancel()
        tick = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        if clearOwner, isRecording {
            controller.hotkeys.stopRecording()
            recordingField = nil
        }
        live = ""
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
