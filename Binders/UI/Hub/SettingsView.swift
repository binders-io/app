import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import BindersKit

/// The parts of Settings. Each has a section on one of Settings' six pages (`Group`); each was a page of its own before.
/// A part's name is what a deep link (`binders://open?section=settings&page=automations`), the quick switcher, the
/// "settingsPage" setting and `HubNavigation.pendingSettingsPage` use, and asking for one opens its page at its section.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, shortcuts, dictation, ai, meetings, allDay, knowledge, writing, automations, mcp, agents, phone, team, privacy

    var id: String { rawValue }

    /// Settings' six pages, down the left: how Binders behaves, what it writes down, how it thinks, what it records, who
    /// it hands work to, and your devices and privacy. Each scrolls through a section for each of its parts.
    enum Group: String, CaseIterable, Identifiable {
        case general = "General"
        case dictation = "Dictation and writing"
        case intelligence = "AI and knowledge"
        case capture = "Capture"
        case agents = "Agents and automations"
        case devices = "Devices and privacy"

        var id: String { rawValue }
        var title: String { rawValue }

        /// Its parts, in the order the page shows them.
        var pages: [SettingsPage] {
            switch self {
            case .general: [.general, .shortcuts]
            case .dictation: [.dictation, .writing]
            case .intelligence: [.ai, .knowledge]
            case .capture: [.meetings, .allDay]
            case .agents: [.agents, .automations, .mcp]
            case .devices: [.phone, .team, .privacy]
            }
        }

        /// Its parts that show.
        @MainActor var visiblePages: [SettingsPage] {
            let visible = SettingsPage.visible
            return pages.filter(visible.contains)
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .dictation: "mic"
            // The language model, which no agent is: not the sparkle.
            case .intelligence: "brain"
            case .capture: "waveform.and.mic"
            case .agents: "wand.and.stars"
            case .devices: "lock.shield"
            }
        }

        /// One line under the page's title: what's on it.
        @MainActor var summary: String {
            switch self {
            case .general: "Appearance, sounds, the Flow bar and updates, and the keys that start dictation and everything else."
            case .dictation: "Your microphone and speech recognition, and what you write in other apps."
            case .intelligence: "The language model, and how your binders are searched, linked and summed up."
            case .capture: "Notes on calls, and conversations heard through the day."
            case .agents: "Who takes cards from your boards, rules that run on their own, and AI tools that use your binders."
            case .devices: visiblePages.contains(.phone) ? "Your iPhone, a team you share with, and what is kept and for how long."
                                                         : "A team you share with, and what is kept and for how long."
            }
        }
    }

    var group: Group {
        Group.allCases.first { $0.pages.contains(self) } ?? .general
    }

    /// The parts that show: all of them. The iPhone's was held back until Binders for iPhone shipped; from 0.10.0 it shows
    /// on every Mac.
    @MainActor static var visible: [SettingsPage] { allCases }

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .dictation: "Dictation"
        case .ai: "AI"
        case .meetings: "Meetings"
        case .allDay: "All-day capture"
        case .knowledge: "Knowledge"
        case .writing: "Writing capture"
        case .automations: "Automations"
        case .mcp: "MCP"
        case .agents: "Agents"
        case .phone: "iPhone"
        case .team: "Team"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        case .dictation: "mic"
        // The language model, which no agent is: not the sparkle.
        case .ai: "brain"
        case .meetings: "person.wave.2"
        case .allDay: "waveform.and.mic"
        case .knowledge: "point.3.connected.trianglepath.dotted"
        case .writing: "pencil.line"
        case .automations: "bolt"
        case .mcp: "cable.connector"
        case .agents: "wand.and.stars"
        case .phone: "iphone"
        case .team: "person.2"
        case .privacy: "lock.shield"
        }
    }

    /// One line under the part's name: what it decides.
    @MainActor var summary: String {
        switch self {
        case .general: "Appearance, sounds, the Flow bar and updates."
        case .shortcuts: "The keys that start dictation and everything else."
        case .dictation: "Microphone and speech recognition."
        case .ai: "The language model that formats, answers and links."
        case .meetings: "Taking notes on calls."
        case .allDay: "Conversations heard through the day, on this Mac and on your iPhone."
        case .knowledge: "Search, the graph and note digests."
        case .writing: "What you write in messages and mail, kept once it is sent."
        case .automations: "Rules that run Shortcuts, scripts and web hooks, and links from other apps."
        case .mcp: "Let Claude Code, Claude Desktop and other AI tools search, ask and add to your knowledge base."
        case .agents: "Agents that take cards from your boards: how Binders hands one over, and how it hears back."
        case .phone: "Pair your iPhone with Binders on this Mac, at home or anywhere through your VPN."
        // The team database is held back from 0.10.0 behind its default (TeamDatabaseFeature): unnamed while it's off. On,
        // it says how this Mac shares (lane DB7).
        case .team: TeamDatabaseFeature.subtitle(TeamDatabaseFeature.way)
        case .privacy: "What is kept, for how long, and permissions."
        }
    }
}

/// Settings as six pages: their list on the left, one page on the right with a section for each of its parts. The part
/// last opened is remembered, and its page shows; a part asked for from elsewhere (a link, the quick switcher, a button on
/// another page) opens its page at its section.
struct SettingsView: View {
    @Environment(HubNavigation.self) private var navigation
    @Environment(\.colorScheme) private var colorScheme
    /// The part last opened, by name, as it always was kept.
    @AppStorage("settingsPage", store: AppDefaults.store) private var pageID = SettingsPage.general.rawValue
    @State private var hovered: SettingsPage.Group?
    /// The part to bring into view once its page has drawn.
    @State private var landing: SettingsPage?
    /// Bumped to open the page afresh, at its top: choosing it in the list, or asking for a part from elsewhere.
    @State private var opened = 0

    private var part: SettingsPage { SettingsPage(rawValue: pageID) ?? .general }
    private var group: SettingsPage.Group { part.group }
    private var dark: Bool { colorScheme == .dark }
    private var ink: Color { BindersTheme.ink }

    var body: some View {
        HStack(spacing: 0) {
            pageList
            Divider()
            SettingsGroupPage(group: group, landing: $landing)
                .id("\(group.rawValue)#\(opened)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Where you left it.
            landing = part
            openPending()
        }
        .onChange(of: navigation.pendingSettingsPage) { openPending() }
    }

    private var pageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPage.Group.allCases.filter { !$0.visiblePages.isEmpty }) { row($0) }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .frame(width: 226)
        .background(BindersTheme.ground2)
    }

    /// A page: its name, and under it the parts it holds.
    private func row(_ item: SettingsPage.Group) -> some View {
        let selected = group == item
        let parts = item.visiblePages
        return Button {
            pageID = parts.first?.rawValue ?? pageID
            opened += 1
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? BindersTheme.accentText : ink.opacity(0.7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(ink.opacity(selected ? 1 : 0.82))
                    Text(parts.map(\.title).joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(BindersTheme.muted)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? BindersTheme.accent.opacity(dark ? 0.3 : 0.14) : (hovered == item ? ink.opacity(0.06) : .clear)))
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
        opened += 1
        landing = pending
        navigation.pendingSettingsPage = nil
    }
}

/// One of Settings' pages: its name and what's on it, then a section for each of its parts in one form that scrolls. A
/// part asked for is brought to the top.
private struct SettingsGroupPage: View {
    let group: SettingsPage.Group
    @Binding var landing: SettingsPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(BindersTheme.title(22))
                Text(group.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 10)
            // The page's sections scroll under its title: a hairline keeps the two apart.
            BindersTheme.line.frame(height: 1)
            ScrollViewReader { proxy in
                // The page's ground shows behind the form's groups.
                Form {
                    ForEach(group.visiblePages) { SettingsPart(part: $0) }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .coordinateSpace(name: SettingsHeading.space)
                .onAppear { land(proxy) }
                .onChange(of: landing) { land(proxy) }
            }
        }
    }

    /// Brings the part asked for to the top once the form has laid out. The first part is where the page starts, so the
    /// page stays put for it.
    private func land(_ proxy: ScrollViewProxy) {
        guard let part = landing else { return }
        landing = nil
        guard group.visiblePages.contains(part), part != group.visiblePages.first else { return }
        DispatchQueue.main.async {
            withAnimation(nil) { proxy.scrollTo(part, anchor: .top) }
        }
    }
}

/// A part's sections, on its page.
private struct SettingsPart: View {
    let part: SettingsPage

    var body: some View {
        switch part {
        case .general: GeneralSettings()
        case .shortcuts: ShortcutsSettings()
        case .dictation: DictationSettings()
        case .ai: AISettings()
        case .meetings: MeetingsSettings()
        case .allDay: AllDayCaptureSettings()
        case .knowledge: KnowledgeSettings()
        case .writing: WritingCaptureSettings()
        case .automations: AutomationsSettings()
        case .mcp: MCPSettings()
        case .agents: AgentsSections()
        case .phone: PhoneSettings()
        case .team: TeamSettings()
        case .privacy: PrivacySettings()
        }
    }
}

/// Where a part starts on its page, as the header of its first group of settings: its name and one line on what it
/// decides, then that group's own name when it has one. A link to the part lands here. The part that shares its page's
/// name (General) shows nothing of its own: the page's title and summary say it.
struct SettingsHeading: View {
    let part: SettingsPage
    /// The name of the group of settings it heads, if it has one.
    var group: String? = nil
    /// The line under the part's name, when its page works it out as it draws (Team's); else the part's own.
    var summary: String? = nil

    /// The form's coordinate space, which the headings report their place in.
    static let space = "settingsForm"
    /// For self-tests: where each heading last was, from the top of the form's visible area, in points.
    nonisolated(unsafe) static var tops: [SettingsPage: CGFloat] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if part.title != part.group.title {
                Label {
                    Text(part.title).font(BindersTheme.title(17)).foregroundStyle(.sectionInk)
                } icon: {
                    Image(systemName: part.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.tintText)
                }
                Text(summary ?? part.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                    .padding(.bottom, group == nil ? 0 : 14)
            }
            if let group {
                Text(group).font(.headline).foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A little more room above a part that follows another on the page.
        .padding(.top, part != part.group.visiblePages.first ? 10 : 0)
        .id(part)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { Self.tops[part] = $0 }
        .onDisappear { Self.tops[part] = nil }
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
        } header: {
            SettingsHeading(part: .general)
        }
        .task {
            automaticChecks = UpdateService.shared.automaticChecks
            automaticDownloads = UpdateService.shared.automaticDownloads
            launchAtLogin = await Task.detached { SMAppService.mainApp.status == .enabled }.value
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
}

private struct ShortcutsSettings: View {
    @Environment(AppSettings.self) private var settings
    /// The shortcut being recorded, global or in Binders: one at a time.
    @State private var recording: String?
    @State private var conflict: ShortcutConflict?
    @State private var menuShortcuts: [MenuCommand: Hotkey] = [:]
    @State private var menuConflict: (command: MenuCommand, hotkey: Hotkey, other: String, otherCommand: MenuCommand?)?

    var body: some View {
        Section {
            ForEach(HotkeyBindings.Field.allCases, id: \.self) { field in
                LabeledContent(field.title) {
                    ShortcutField(key: field.rawValue, isHold: field.isHold, removable: field != .dictation, hotkey: settings.hotkeys[field],
                                  recording: $recording, onRecord: { record($0, for: field) }, onClear: { settings.hotkeys[field] = nil })
                }
                if let conflict, conflict.field == field {
                    conflictRow(conflict)
                }
            }
            Button("Reset to defaults") {
                conflict = nil
                settings.hotkeys = .default
            }
        } header: {
            SettingsHeading(part: .shortcuts, group: "Anywhere on your Mac")
        } footer: {
            Text("Hold to talk, release to insert. Double-tap the dictation shortcut to go hands-free, press it again to finish, Esc to cancel. The other shortcuts can be a key combination such as ⌥S, or a modifier tapped twice: click, then tap ⌥ twice.")
        }
        Section {
            ForEach(MenuCommand.allCases) { command in
                LabeledContent(command.title) {
                    ShortcutField(key: "menu." + command.rawValue, isHold: false, requiresKey: true, removable: true, hotkey: menuShortcuts[command],
                                  recording: $recording, onRecord: { recordMenu($0, for: command) },
                                  onClear: { setMenu(nil, for: command) })
                }
                if let menuConflict, menuConflict.command == command {
                    HStack(spacing: 10) {
                        StatusLabel("\(menuConflict.hotkey.displayString(keyName: KeyCode.name)) is already \(menuConflict.other).", .problem)
                        Spacer()
                        if let other = menuConflict.otherCommand {
                            Button("Use it here") {
                                setMenu(nil, for: other)
                                setMenu(menuConflict.hotkey, for: command)
                            }
                        } else {
                            Button("OK") { self.menuConflict = nil }
                        }
                    }
                }
            }
            Button("Reset to defaults") {
                menuConflict = nil
                MenuShortcuts.reset()
                loadMenuShortcuts()
            }
        } header: {
            Text("In Binders")
        } footer: {
            Text("These work while Binders is in front, and show in its menus. Pop Out and Fold into a Bubble act on the note you're in, in Binders or in its own window.")
        }
        .onAppear(perform: loadMenuShortcuts)
    }

    private func loadMenuShortcuts() {
        menuShortcuts = Dictionary(uniqueKeysWithValues: MenuCommand.allCases.compactMap { command in MenuShortcuts.shortcut(for: command).map { (command, $0) } })
    }

    private func setMenu(_ hotkey: Hotkey?, for command: MenuCommand) {
        menuConflict = nil
        MenuShortcuts.set(hotkey, for: command)
        loadMenuShortcuts()
    }

    private func recordMenu(_ hotkey: Hotkey, for command: MenuCommand) {
        menuConflict = nil
        if let field = HotkeyBindings.Field.allCases.first(where: { settings.hotkeys[$0] == hotkey }) {
            menuConflict = (command, hotkey, "your \(field.title) shortcut, which works everywhere", nil)
        } else if let other = MenuShortcuts.conflict(for: hotkey, except: command) {
            menuConflict = (command, hotkey, "used for \(other)", MenuCommand.allCases.first { $0.title == other })
        } else {
            setMenu(hotkey, for: command)
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
            if conflict.other == .dictation {
                StatusLabel("\(name) is how you dictate. Pick another shortcut.", .problem)
                Spacer()
                Button("OK") { self.conflict = nil }
            } else {
                StatusLabel("\(name) is already used for \(conflict.other.title).", .problem)
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
        Section {
            Picker("Input device", selection: $settings.microphoneUID) {
                Text("System default").tag(String?.none)
                ForEach(devices) { Text($0.name).tag(String?.some($0.id)) }
            }
            Toggle("Boost quiet speech (whisper mode)", isOn: $settings.whisperBoost)
            Stepper("Maximum recording: \(settings.maxRecordingMinutes) min", value: $settings.maxRecordingMinutes, in: 1...60)
        } header: {
            SettingsHeading(part: .dictation, group: "Microphone")
        }
        .task { devices = AudioDevices.inputDevices() }

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

    @ViewBuilder
    private var speechStatus: some View {
        switch controller.speech.state {
        case .ready:
            StatusLabel("Ready", .ready)
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading \(Int(fraction * 100))%").font(.caption) }.frame(width: 200)
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Loading…") }
        case .failed(let message):
            HStack {
                StatusLabel(message, .problem).lineLimit(2)
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
    /// How the last test went, and what it gave back.
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var residency: ModelResidency?
    @State private var residencyChecked = false
    @State private var unloading = false

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("AI formatting", isOn: $settings.aiFormatting)
            Toggle("Command Mode", isOn: $settings.commandModeEnabled)
            Toggle(isOn: $settings.readAnswersAloud) {
                Text("Read answers aloud")
                Text("Ask Command Mode what's happening with your work streams, and Binders says the answer as well as showing it.")
            }
            .disabled(!settings.commandModeEnabled)
            Picker("Provider", selection: $settings.llmProvider) {
                ForEach(LLMProviderKind.available) { Text($0.displayName).tag($0) }
            }
            if settings.llmProvider == .ollama {
                StackedField(label: "Ollama URL", text: $settings.ollamaURL, probe: "field.ai.ollamaURL")
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
            } else if settings.llmProvider == .mlx {
                MLXModelSettings()
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
                            await refreshResidency()
                            unloading = false
                        }
                    }
                    .disabled(residency == nil || unloading)
                }
            } else {
                StackedField(label: "Base URL", text: $settings.openAIBaseURL, probe: "field.ai.baseURL")
                modelPicker(selection: $settings.openAIModel)
                StackedField(label: "API key (optional)", text: Binding(get: { settings.openAIKey }, set: { settings.openAIKey = $0 }), secure: true, probe: "field.ai.apiKey")
            }
            HStack {
                Button(testing ? "Testing…" : "Test formatting") { Task { await runTest() } }
                    .disabled(testing)
                if let testResult {
                    StatusLabel(testResult.text, testResult.ok ? .ready : .problem).font(.caption).textSelection(.enabled).lineLimit(3)
                }
            }
        } header: {
            SettingsHeading(part: .ai, group: "Language model")
        } footer: {
            Text("Formatting removes filler words, applies your corrections and matches the style of each app. Smaller models are faster; Gemma 4 26B gives the best cleanup.")
        }
        .task(id: settings.llmProvider.rawValue + settings.ollamaModel + settings.ollamaURL + settings.mlxModel) {
            while !Task.isCancelled {
                await refreshResidency()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task(id: "\(settings.llmProvider.rawValue)|\(settings.ollamaURL)|\(settings.openAIBaseURL)") { await loadModels() }

        // Distill may read with a model of its own (lane DS3): a slower one that lists work better.
        DistillModelSection()

        // The decision model runs inside Binders or in a server on this Mac, so it's here whatever the language model's
        // provider.
        DecisionModelSection()

        Section("Inserting text") {
            Toggle("Voice commands (say “press enter” to send)", isOn: $settings.voiceCommands)
            Toggle("Smart spacing between dictations", isOn: $settings.smartSpacing)
            Toggle("Restore clipboard after pasting", isOn: $settings.restoreClipboard)
        }
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
                    StatusLabel("\(chosen) is likely too large for \(memory) GB of memory. Suggested: \(pick.model).", .problem)
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
        case .mlx: client = nil
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
        guard settings.llmProvider != .openAICompatible else { return "" }
        let model = settings.llmModelName
        guard residencyChecked else { return "Checking whether the model is in memory…" }
        guard let residency else { return "\(model) is not in memory. It loads when a dictation starts, or when notes, digests or promises need it." }
        let size = ByteCountFormatter.string(fromByteCount: residency.bytes, countStyle: .memory)
        if let expires = residency.expiresAt {
            let minutes = max(0, Int(expires.timeIntervalSinceNow / 60))
            return "\(model) is in memory (\(size)) · frees in \(minutes < 1 ? "under a minute" : "\(minutes) min") unless used again"
        }
        return "\(model) is in memory (\(size)) · kept loaded"
    }

    private func refreshResidency() async {
        guard settings.llmProvider != .openAICompatible, let client = settings.makeLLMClient() else { residency = nil; residencyChecked = true; return }
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
            testResult = (true, "\(millis) ms — \(result.text)")
        } else {
            testResult = (false, "\(result.fallbackReason ?? "AI formatting is off") — \(result.text)")
        }
    }
}

private struct MeetingsSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
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
        } header: {
            SettingsHeading(part: .meetings)
        } footer: {
            Text("Records your mic and the call's audio on this Mac — no bot joins. Transcripts, speaker labels and notes are all produced locally.")
        }
    }
}

private struct AllDayCaptureSettings: View {
    @Environment(DictationController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @State private var importing = false
    @State private var imported: String?

    var body: some View {
        @Bindable var settings = settings
        let capture = controller.allDay
        Section {
            Toggle("Listen for conversations on this Mac", isOn: Binding(get: { capture.isOn }, set: { on in
                if on { Task { await capture.turnOn() } } else { capture.turnOff() }
            }))
            if capture.isOn {
                LabeledContent("Now") {
                    HStack(spacing: 8) {
                        statusGlyph(capture)
                        Text(capture.status.title + (capture.inConversation ? " · in a conversation" : ""))
                        Button(capture.isMuted ? "Unmute" : "Mute") {
                            if capture.isMuted { capture.unmute() } else { capture.mute() }
                        }
                    }
                }
            }
            if let error = capture.error {
                StatusLabel(error, .problem).font(.callout)
            }
            LabeledContent("Today", value: "\(Self.duration(capture.onToday())) listening · \(Int((capture.speechSeconds / 60).rounded())) min of speech")
            if let activity = capture.activity {
                LabeledContent("Writing down", value: activity)
            }
            Toggle("Keep audio for 24 hours", isOn: $settings.allDayKeepAudio)
        } header: {
            SettingsHeading(part: .allDay)
        } footer: {
            Text("Binders listens through the day and cuts it into conversations. Only speech is written to disk, with a second either side, and the audio is deleted once it's written down. Each conversation is summarized, its promises become to-dos, and it's filed in the binder it belongs to, never shared with your team. It pauses while a meeting is recorded, and what you dictate isn't part of a conversation. If your iPhone listens too, a conversation near both is written down twice.")
        }
        Section {
            Toggle("Offer cards for what you said you'd do", isOn: $settings.suggestCards)
            Toggle("Answer questions you asked, from your binders", isOn: $settings.suggestAnswers)
        } header: {
            Text("After a capture")
        } footer: {
            Text("Once a capture is written up, Binders offers to put the things you said you'd do on the binder's board, and answers a question you asked if your notes, meetings or earlier conversations hold the answer. They come as notifications on the device that heard it, and wait on the capture's page.")
        }
        Section {
            Text("Binders for iPhone sends its captures over the phone link. When the network can't, share them from the iPhone by AirDrop, or save them to Files, and open the file here.")
                .foregroundStyle(.secondary)
            Button("Open a Binders File…") { importing = true }
            if let imported { Text(imported).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("From your iPhone")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(exportedAs: BindersTransfer.typeIdentifier)],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            imported = urls.map { BindersFiles.open($0, controller: controller) }.last
        }
    }

    /// Red while the microphone listens, moving only while someone speaks; muted, with its glyph, while muted or paused.
    @ViewBuilder
    private func statusGlyph(_ capture: AllDayCaptureService) -> some View {
        switch capture.status {
        case .listening:
            ListeningWaveform { await capture.hearsSpeech() }
        case .muted:
            Image(systemName: "mic.slash").foregroundStyle(.secondary).accessibilityHidden(true)
        case .paused:
            Image(systemName: BindersTheme.waitingSymbol).foregroundStyle(.secondary).accessibilityHidden(true)
        case .off:
            EmptyView()
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

private struct KnowledgeSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(KnowledgeService.self) private var knowledge
    @State private var ignoredEntities: [KnowledgeStore.IgnoredEntity] = []

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Link people, projects and topics (uses your language model)", isOn: $settings.knowledgeGraph)
            Toggle("Write digests for notes: title, summary, to-dos (uses your language model)", isOn: $settings.noteDigests)
            if settings.llmProvider == .mlx {
                // Built in: the search model is downloaded like the language model, under AI on this page.
                let model = settings.mlxEmbeddingModel
                HStack {
                    LabeledContent("Embedding model", value: model)
                    if MLXModels.directory(for: model) == nil {
                        if let fraction = MLXModels.shared.progress[model] {
                            ProgressView(value: fraction).frame(width: 80)
                        } else {
                            Button("Download") { MLXModels.shared.download(model) }
                        }
                    }
                }
            } else {
                StackedField(label: "Embedding model", text: $settings.embeddingModel, probe: "field.knowledge.embeddingModel") {
                    Button(knowledge.pullProgress == nil ? "Download" : "Downloading…") {
                        Task { await knowledge.pullEmbeddingModel() }
                    }
                    .disabled(knowledge.pullProgress != nil || settings.llmProvider != .ollama)
                }
                if let progress = knowledge.pullProgress {
                    ProgressView(value: progress)
                }
            }
            LabeledContent("Index") {
                Text(knowledge.status.summary).foregroundStyle(.secondary)
            }
            if let issue = knowledge.status.embeddingIssue ?? knowledge.status.extractionIssue {
                StatusLabel(issue, .problem).font(.caption)
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
        } header: {
            SettingsHeading(part: .knowledge)
        } footer: {
            Text("Search combines keywords with meaning. Meaning comes from an embedding model (embeddinggemma) where your language model runs: on this Mac by default, or on the server you chose under AI, above. Names removed from Knowledge stay out until restored here.")
        }
        .task(id: knowledge.revision) { ignoredEntities = await knowledge.ignoredEntities() }
    }
}

private struct WritingCaptureSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var addingApps = false

    var body: some View {
        @Bindable var settings = settings
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
            // Apps added from the list of what's running, or from Applications.
            ForEach(settings.captureApps.filter { id in !WritingCaptureService.knownApps.contains { $0.bundleID == id } }, id: \.self) { id in
                HStack(spacing: 8) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                    }
                    Text(WritingCaptureService.appName(id))
                    if WritingCaptureService.isBrowser(id) {
                        Text(settings.captureAllSites ? "any site" : "listed sites only").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { settings.captureApps.removeAll { $0 == id } } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Stop capturing in \(WritingCaptureService.appName(id))")
                }
            }
            Button("Add an App…") { addingApps = true }
                .help("Pick from the apps open now, or any app in Applications")
            Toggle("Capture on any site (login, payment and banking pages are always skipped)", isOn: $settings.captureAllSites)
            if !settings.captureAllSites {
                StackedField(label: "Listed sites", text: Binding(
                    get: { settings.captureHosts.joined(separator: ", ") },
                    set: { settings.captureHosts = $0.components(separatedBy: CharacterSet(charactersIn: ", ")).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty } }),
                             lines: 1...4, probe: "field.writing.sites")
            }
        } header: {
            SettingsHeading(part: .writing, group: "Where")
        } footer: {
            Text("Off until you switch it on (\(settings.hotkeys.capture?.displayString() ?? "menu bar") or the menu bar). While on, what you write in these apps is kept once you send or save it, filed in the open binder and indexed like a note. Keystrokes are never recorded, secure fields are never read, and card numbers, passwords and keys are redacted before anything is stored. Everything stays on this Mac.")
        }
        .sheet(isPresented: $addingApps) {
            CaptureAppPicker(current: Set(settings.captureApps)) { ids in
                settings.captureApps += ids.filter { !settings.captureApps.contains($0) }
            }
        }

        Section {
            ForEach(AgentHarnesses.all().filter { $0.id != AgentHarness.hooksID }) { harness in
                Toggle(isOn: Binding(get: { !settings.captureAgentsOff.contains(harness.id) },
                                     set: { on in
                                         if on { settings.captureAgentsOff.removeAll { $0 == harness.id } } else { settings.captureAgentsOff.append(harness.id) }
                                     })) {
                    HStack(spacing: 6) {
                        Text("Prompts you send \(harness.name)")
                        if !AgentHarnesses.isInstalled(harness) { Text("not on this Mac").font(.caption).foregroundStyle(.tertiary) }
                    }
                }
            }
            AgentHookRow(off: Binding(get: { settings.captureAgentsOff.contains(AgentHarness.hooksID) },
                                      set: { off in
                                          if off { settings.captureAgentsOff.append(AgentHarness.hooksID) } else { settings.captureAgentsOff.removeAll { $0 == AgentHarness.hooksID } }
                                      }))
        } header: {
            Text("In the terminal")
        } footer: {
            Text("Exactly what you type to them, from the record each keeps on this Mac, in any terminal or editor. The screen and command output are never read, pasted blocks aren't kept, and shell commands are left out. Captured while capture is on, from then on.")
        }

        Section("What happens to it") {
            Stepper("Keep captured writing for \(settings.captureRetentionDays) days", value: $settings.captureRetentionDays, in: 7...730, step: 7)
            Toggle("Turn promises and asks in captured messages into to-dos (uses your language model)", isOn: $settings.captureCommitments)
            Toggle("Remind me on the day a promise is due", isOn: $settings.commitmentReminders)
            Button("Open the capture log") { HubWindowController.shared.show(section: .writing) }
        }
    }
}

private struct TeamSettings: View {
    @Environment(AppSettings.self) private var settings
    @Environment(TeamSyncService.self) private var team
    @Environment(DictationController.self) private var controller
    @State private var confirmLeave = false
    @State private var teamError: String?
    /// Move This Team to a Database… (lane DB3).
    @State private var moving = false
    /// Join a Team… and Set Up a Team… (lane DB7), Set Up a Team Database… from it, and where to go once a sheet closes.
    @State private var joining = false
    @State private var choosingSetUp = false
    @State private var settingUpDatabase = false
    @State private var next: TeamNextStep?
    /// What came of joining or setting up a team here.
    @State private var said: String?
    /// The team database, held back from 0.10.0 behind its default (TeamDatabaseFeature), read as it changes.
    @AppStorage(TeamDatabaseFeature.key, store: AppDefaults.store) private var teamDatabaseOn = false

    var body: some View {
        @Bindable var settings = settings
        // How this Mac shares, read with the default so the page follows it (lane DB7).
        let way = teamDatabaseOn ? TeamDatabaseFeature.way(hasFolder: team.folderURL != nil) : .folderOnly
        Section {
            StackedField(label: "Your name", text: $settings.teamMemberName, prompt: NSFullUserName(), probe: "field.team.name")
            // An invite opened on this Mac (a link, or a file from Finder): it asks before it joins, and while team
            // databases are off, whether to turn them on (lane DB7). A Mac on a team database has its team.
            if way != .database, let invite = controller.teamBoard.pendingInvite {
                TeamInviteQuestion(invite: invite, featureOn: teamDatabaseOn, folderTeam: team.folderURL != nil,
                                   said: { said = $0; teamError = nil }, failed: { teamError = $0 }, move: { moving = true })
            }
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
                LabeledContent("Folders") {
                    Text(folderLine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent("Sync") {
                    Text(teamSyncSummary).monospacedDigit().foregroundStyle(.secondary)
                }
                if let error = team.status.error {
                    StatusLabel(error, .problem).font(.caption)
                }
                // A teammate moved the team to a team database (lane DB3). Held back from 0.10.0 with the team database.
                if teamDatabaseOn, let moved = team.status.moved {
                    StatusLabel(moved.line, .needsYou).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Sync now") { Task { await team.syncNow() } }
                    if teamDatabaseOn {
                        Button("Move This Team to a Database…") { moving = true }
                            .help("Everything the team folder shares goes into a team database once, and this Mac stops syncing the folder")
                            .fitProbe("team.database")
                    }
                    Spacer()
                    Button("Leave team space…", role: .destructive) { confirmLeave = true }
                }
            } else if way == .either {
                // No team yet, with team databases on (lane DB7): joining first, then setting one up, the database
                // first in each; a shared folder is the second way in both.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Join a Team…") { joining = true }
                            .buttonStyle(.borderedProminent)
                            .fitProbe("team.join")
                        Button("Set Up a Team…") { choosingSetUp = true }
                            .fitProbe("team.setUp")
                    }
                    Text("Join with the invite a teammate sent you, or set up a team and invite them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let teamError {
                    StatusLabel(teamError, .problem).font(.caption)
                }
            } else {
                // A Mac shares one way: a team folder, or a team database (lane DB2), while the team database is on.
                let database = way == .database
                HStack {
                    Button("Create team space…") { chooseTeamFolder(create: true) }
                    Button("Join team space…") { chooseTeamFolder(create: false) }
                }
                .disabled(database)
                if database {
                    Text("This Mac shares through a team database. A Mac shares one way: leave the team database first to use a team folder.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let teamError {
                    StatusLabel(teamError, .problem).font(.caption)
                }
            }
            if let said { StatusLabel(said, .done).font(.caption).fixedSize(horizontal: false, vertical: true) }
        } header: {
            SettingsHeading(part: .team, summary: TeamDatabaseFeature.subtitle(way))
        } footer: {
            // What's true for the way this Mac shares (lane DB7): the folder's words, the database's, or both.
            Text(TeamDatabaseFeature.footer(way))
                .fitProbe("team.footer.\(way.rawValue)")
        }
        .sheet(isPresented: $moving) { TeamMoveSheet() }
        .sheet(isPresented: $joining, onDismiss: goOn) {
            TeamJoinSheet(joined: { said = $0; teamError = nil }, throughFolder: { next = .joinFolder })
        }
        .sheet(isPresented: $choosingSetUp, onDismiss: goOn) { TeamSetUpChoiceSheet { next = $0 } }
        .sheet(isPresented: $settingUpDatabase) { TeamDatabaseSetUpSheet { said = $0; teamError = nil } }
        .confirmationDialog("Leave the team space?", isPresented: $confirmLeave) {
            Button("Leave", role: .destructive) { Task { await team.leave() } }
        } message: {
            Text("Teammates' meetings and notes are removed from this Mac. What you already shared stays in the team folder.")
        }
        // Held back from 0.10.0 behind its default (TeamDatabaseFeature): only the shared-folder way while it's off. On,
        // with no team yet, joining and setting up lead above (lane DB7); in a team folder or on a team database, its part.
        if way == .folder || way == .database {
            TeamDatabaseSection()
                .fitProbe("team.database")
        }
    }

    /// Where a sheet that just closed goes on to: Set Up a Team Database…, or a shared folder to create or join.
    private func goOn() {
        guard let step = next else { return }
        next = nil
        switch step {
        case .database: settingUpDatabase = true
        case .createFolder: chooseTeamFolder(create: true)
        case .joinFolder: chooseTeamFolder(create: false)
        }
    }

    /// Whether note files go into their folders' subfolders of the team folder yet, and what it waits for.
    private var folderLine: String {
        let status = team.status
        if status.filesMove { return "Notes in folders are in the same subfolders of Notes, so the team folder reads as Binders does, in Obsidian too." }
        let names = status.waitingForFolders
        let who = names.isEmpty ? "" : " Waiting for \(names.formatted(.list(type: .and))) to update Binders."
        let files = status.unreadableMembers > 0 ? " Waiting for a teammate's file in the team folder to finish downloading." : ""
        return "Each note's folder is kept in its file for now, and its file stays where it is. Files go into their folders' subfolders once everyone's Binders knows folders.\(who)\(files)"
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
            : "Choose the folder a teammate shared with you. It has Meetings, Notes and _binders in it."
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
        Section {
            Toggle("Keep audio for re-transcription", isOn: $settings.saveAudio)
            Stepper("Delete audio after \(settings.audioRetentionDays) days", value: $settings.audioRetentionDays, in: 1...90)
            // On one line when they fit, the delete on its own line under the others when the window is narrow (lane UI1).
            ViewThatFits(in: .horizontal) {
                HStack {
                    dataButtons
                    Spacer()
                    deleteButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { dataButtons }
                    deleteButton
                }
            }
        } header: {
            SettingsHeading(part: .privacy, group: "Your data")
        }
        .confirmationDialog("Delete all dictation history, saved audio and the sorting record?", isPresented: $confirmDelete) {
            Button("Delete All", role: .destructive) { Store.shared.deleteAllHistory() }
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
                Text(controller.hotkeys.isRunning ? "Active" : "Waiting for Accessibility: grant it above").foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissionsRevision += 1 }
    }

    @ViewBuilder
    private var dataButtons: some View {
        Button("Open data folder") { NSWorkspace.shared.open(AppPaths.support) }
        Button("Acknowledgements") {
            if let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") { NSWorkspace.shared.open(url) }
        }
    }

    private var deleteButton: some View {
        Button("Delete all history", role: .destructive) { confirmDelete = true }
    }

    private func permissionStatus(_ granted: Bool, open: @escaping () -> Void) -> some View {
        HStack {
            let _ = permissionsRevision
            if granted {
                StatusLabel("Granted", .ready)
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
            SettingsHeading(part: .automations, group: "Rules")
        } footer: {
            Text("Placeholders: {text}, {title}, {when}, {date}, {app}, {binder}, {summary}, {link}, and {todo_origin} for a to-do. What you say after a phrase is {text}; a time at its end becomes {when} and {date}. Rules are kept in automations.json in the data folder, and a web hook's token in your Keychain. A to-do rule runs for to-dos you made; one said to yourself, or added by an agent or a link, runs only the rules you let take it. A web hook sends its payload to the address you give it, a link opens in your browser, and a Shortcut or a script does what you wrote it to do.")
        }
        .sheet(item: $editing) { rule in
            AutomationEditor(rule: rule) { saved, token in service.upsert(saved, token: token) }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { rule in
            Button("Delete", role: .destructive) { service.remove(rule.id) }
        }

        Section {
            ForEach(Self.links, id: \.1) { title, link in
                StackedRow(title) {
                    HStack(spacing: 6) {
                        Text(link).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        copyButton(link)
                    }
                }
            }
        } header: {
            Text("From other apps")
        } footer: {
            Text("Anything that can open a link can drive Binders: Shortcuts, Raycast, Alfred, Keyboard Maestro, a script. Text goes in the query, percent-encoded. A link that would start dictation, writing capture or a recording asks you first, so nothing can turn them on unseen, and a to-do a link adds says so. binders://card/ and a card's id opens that card, and binders://note/ and a note's id opens that note. AI tools connect through MCP, below, instead.")
        }
    }

    private func ruleRow(_ rule: AutomationRule) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled" : rule.name).fontWeight(.medium)
                Text("\(Self.describe(rule.trigger)) → \(Self.describe(rule.action))\(Self.extras(rule, token: service.withToken.contains(rule.id)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let outcome = service.outcomes[rule.id] {
                    Label("\(outcome.message) · \(outcome.at.formatted(date: .omitted, time: .shortened))",
                          systemImage: outcome.ok ? "checkmark" : BindersTheme.problemSymbol)
                        .font(.caption).monospacedDigit().foregroundStyle(outcome.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)).lineLimit(1)
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

    /// What else the row says: a token in the Keychain, and to-dos it takes beyond yours.
    static func extras(_ rule: AutomationRule, token: Bool) -> String {
        var parts: [String] = []
        if case .webhook = rule.action, token { parts.append("with a token from your Keychain") }
        if case .event(.todoAdded) = rule.trigger, rule.anyOrigin == true { parts.append("also for to-dos said to yourself, from agents and from links") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }
}

/// Copies a line to the clipboard.
struct CopyButton: View {
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

/// The phone link: on or off, pairing, the paired devices, and the addresses this Mac offers an iPhone.
private struct PhoneSettings: View {
    @Environment(DictationController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @Environment(\.displayScale) private var displayScale
    @State private var newAddress = ""
    @State private var addProblem: String?

    var body: some View {
        let link = controller.link
        Section {
            Toggle("Let paired devices connect to this Mac", isOn: Binding(get: { settings.phoneLink }, set: { on in
                settings.phoneLink = on
                if on { link.start() } else { link.stop() }
            }))
            if settings.phoneLink { status(link) }
        } header: {
            SettingsHeading(part: .phone)
        } footer: {
            Text("Your iPhone talks to Binders on this Mac: over your Wi-Fi at home, or anywhere through your VPN (Covee, Tailscale or another) on both. Everything is encrypted with a key made when you pair, and nothing passes through anyone's server. The Mac needs to be awake; while it isn't, the phone keeps what you capture and sends it later.")
        }
        if settings.phoneLink {
            Section("Pair a device") {
                if let pairing = link.pairing {
                    HStack(alignment: .top, spacing: 16) {
                        if let code = Self.qrCode(pairing.url.absoluteString, scale: displayScale) {
                            Image(nsImage: code.image).interpolation(.none).resizable().frame(width: code.points, height: code.points)
                                .frame(width: 180, height: 180)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Scan this with your iPhone's camera.").font(BindersTheme.cardTitle)
                            Text("The code works once, until \(pairing.expires.formatted(date: .omitted, time: .shortened)). It's the only way a new device can join.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Cancel") { link.cancelPairing() }
                        }
                    }
                    .padding(.vertical, 6)
                } else if link.makingPairingCode {
                    Text("Making a pairing code…").foregroundStyle(.secondary)
                } else {
                    Button("Pair an iPhone…") { Task { await link.beginPairing() } }
                        .disabled(!link.isRunning)
                }
                if link.addressesRead, !link.addresses.isEmpty, LinkAddresses.offered(link.addresses).isEmpty {
                    StatusLabel("Every address is left out, so an iPhone has nowhere to pair. Include one, or add one.", .problem)
                        .font(.caption)
                }
            }
            Section("Paired devices") {
                if link.devices.isEmpty && link.devicesToPairAgain.isEmpty {
                    Text("None yet.").foregroundStyle(.secondary)
                }
                ForEach(link.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(detail(device, link: link))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { link.revoke(device.id) }
                            .help("Disconnect this device and delete its key. It would have to pair again.")
                    }
                }
                // In the devices file without a key in this Mac's Keychain (a data folder from another Mac, or a key that
                // couldn't be read): never let in, and listed so you can remove it.
                ForEach(link.devicesToPairAgain) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "iphone.slash").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text("Can't connect: its key isn't in this Mac's Keychain. Remove it, then pair it again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { link.revoke(device.id) }
                            .help("Take this device off the list. It would have to pair again.")
                    }
                }
            }
            addresses(link)
        }
    }

    /// What this Mac offers an iPhone, in the order it tries them: yours to remove, detected ones to leave out or take
    /// back, and a field to add a name or an address.
    @ViewBuilder
    private func addresses(_ link: LinkServer) -> some View {
        let port = link.boundPort ?? Link.port
        Section {
            if !link.addressesRead {
                Text("Looking for this Mac's addresses…").foregroundStyle(.secondary)
            } else if link.addresses.isEmpty {
                Text("No addresses yet. Connect this Mac to a network, or add an address.").foregroundStyle(.secondary)
            }
            ForEach(link.addresses) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.address.name(defaultPort: port)).monospacedDigit().textSelection(.enabled)
                            .foregroundStyle(entry.leftOut ? .secondary : .primary)
                        Text(Self.caption(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.isAdded {
                        Button("Remove") { link.removeAddress(entry.address.name(defaultPort: port)) }
                            .buttonStyle(.borderless)
                            .help("Remove the address you added. If this Mac finds it by itself, it stays offered: use Leave Out for that.")
                    } else if entry.leftOut {
                        Button("Include") { link.leaveOut(entry.address.host, false) }
                            .buttonStyle(.borderless)
                            .help("Offer this address to your iPhone again.")
                    } else {
                        Button("Leave Out") { link.leaveOut(entry.address.host, true) }
                            .buttonStyle(.borderless)
                            .help("Stop offering this address to your iPhone, for one it can't use.")
                    }
                }
                .accessibilityElement(children: .combine)
            }
            VStack(alignment: .leading, spacing: 4) {
                StackedField(label: "Add a name or address", text: $newAddress, prompt: "such as studio-mac.example.net", probe: "field.phone.address") {
                    Button("Add") { add(link) }
                        .disabled(newAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .onSubmit { add(link) }
                .onChange(of: newAddress) { addProblem = nil }
                if let addProblem {
                    StatusLabel(addProblem, .problem).font(.caption)
                }
            }
        } header: {
            Text("Addresses your iPhone tries")
        } footer: {
            Text("Your iPhone tries all of these at once and uses the first that answers. It learns this list each time it connects, and a new pairing code carries the likeliest ones. Add a name your VPN gives this Mac, or its VPN address to have it offered even while the VPN is down, and leave out one an iPhone can't use. An IPv6 address with a port goes in brackets: [fd7a::2]:7450.")
        }
        .task { await link.refreshAddresses() }
    }

    private func add(_ link: LinkServer) {
        guard !newAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let problem = link.addAddress(newAddress) {
            addProblem = problem
        } else {
            newAddress = ""
            addProblem = nil
        }
    }

    /// "Wi-Fi", "VPN · utun0", "Tailscale", "Added by you", and when it applies "· rarely reachable from an iPhone"; a
    /// left-out one says so instead.
    private static func caption(_ entry: LinkAddresses.Entry) -> String {
        if entry.leftOut { return "Left out: not offered to your iPhone" }
        var parts = [entry.address.label]
        if entry.address.kind == LinkAddress.Kind.vpn, let interface = entry.interface { parts.append(interface) }
        if entry.address.unlikely == true { parts.append("rarely reachable from an iPhone") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func status(_ link: LinkServer) -> some View {
        switch link.status {
        case .listening:
            StatusLabel("Listening on port \(String(link.boundPort ?? Link.port))", .ready)
        case .failed(let message):
            StatusLabel(message, .problem)
        case .off:
            Text("Starting the link…").foregroundStyle(.secondary)
        }
    }

    private func detail(_ device: LinkDevice, link: LinkServer) -> String {
        if link.connectedDevices.contains(device.id) {
            return link.connectedOver(device.id).map { "Connected over \($0)" } ?? "Connected"
        }
        let paired = "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"
        guard let seen = device.lastSeen else { return paired }
        return "\(paired) · last seen \(seen.formatted(.relative(presentation: .named)))"
    }

    /// The pairing code with every module the same whole number of pixels: made at one pixel a module, scaled by the
    /// largest whole number that fits `side` points on this display, and shown at that many points.
    static func qrCode(_ text: String, side: CGFloat = 180, scale: CGFloat) -> (image: NSImage, points: CGFloat)? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage, code.extent.width > 0 else { return nil }
        let modules = code.extent.width
        let scale = max(scale, 1)
        let factor = max(1, (side * scale / modules).rounded(.down))
        let output = code.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return (image, min(side, modules * factor / scale))
    }
}

private struct MCPSettings: View {
    @State private var hostMessages: [MCPHost: String] = [:]
    @State private var showingInstructions: MCPHost?
    /// Bumped after adding to a tool, so its row re-reads the configuration.
    @State private var hostRevision = 0
    /// Bumped when what a tool can read changes, so the checkboxes re-read it.
    @State private var readsRevision = 0

    private var executable: String { MCPHost.executable }
    private var mcpJSON: String { "{\"mcpServers\":{\"binders\":{\"command\":\"\(executable)\",\"args\":[\"--mcp\"]}}}" }
    private var readingTools: [String] { MCPServer.hostTools.filter(\.readOnly).map(\.name) }
    private var addingTools: [String] { MCPServer.hostTools.filter { !$0.readOnly && Self.isAdd($0.name) }.map(\.name) }
    private var changingTools: [String] { MCPServer.hostTools.filter { !$0.readOnly && !Self.isAdd($0.name) }.map(\.name) }

    /// Makes something new, rather than changing what's there.
    private static func isAdd(_ name: String) -> Bool {
        ["add_", "append_", "create_"].contains { name.hasPrefix($0) }
    }

    var body: some View {
        Section {
            StackedRow("Command") {
                HStack(spacing: 6) {
                    Text("\(executable) --mcp").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    CopyButton(text: "\(executable) --mcp")
                }
            }
            StackedRow("Reads") {
                Text(readingTools.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            StackedRow("Adds") {
                Text(addingTools.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            StackedRow("Changes") {
                Text(changingTools.joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
        } header: {
            SettingsHeading(part: .mcp, group: "Server")
        } footer: {
            Text("A tool that supports the Model Context Protocol starts this command and talks to it over a pipe. It runs only while that tool is connected and reads the same data the app does. What it reads goes wherever that tool sends it, often to its own AI model. Reads go straight to the database; anything added or changed is handed to the app, so your windows update and the index picks it up. Nothing can be deleted this way, and a note that's changed keeps its earlier version in its history.")
        }

        Section {
            ForEach([MCPHost.allCases.map(\.name), [MCPServer.otherTools]].flatMap { $0 }, id: \.self) { tool in
                readsRow(tool)
            }
        } header: {
            Text("What each tool can read")
        } footer: {
            Text("Notes, meeting notes, dictations, writing and the boards are always there. Captures (what All-day capture heard, often with other people), meeting transcripts and items your teammates share are left out until you tick them for a tool. Other tools are any that aren't listed above.")
        }

        Section {
            ForEach(MCPHost.allCases.filter(\.isListed)) { host in
                hostRow(host)
            }
        } header: {
            Text("Add it to a tool")
        } footer: {
            Text("Each tool keeps its servers in its own file. Binders makes a dated backup beside that file first, and changes only the binders entry. The question mark button shows how to do it by hand.")
        }

        Section {
            StackedRow("Configuration") {
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

    /// Which of captures, meeting transcripts and teammates' items one tool may read.
    private func readsRow(_ tool: String) -> some View {
        LabeledContent(tool) {
            HStack(spacing: 14) {
                readsToggle("Captures", list: MCPServer.captureReaders, tool: tool)
                readsToggle("Transcripts", list: MCPServer.transcriptReaders, tool: tool)
                readsToggle("Teammates' items", list: MCPServer.teamReaders, tool: tool)
            }
        }
    }

    private func readsToggle(_ title: String, list: String, tool: String) -> some View {
        let _ = readsRevision
        return Toggle(title, isOn: Binding(
            get: { MCPServer.ReadGrants.tools(list).contains(tool) },
            set: { allowed in
                var tools = MCPServer.ReadGrants.tools(list)
                if allowed { tools.insert(tool) } else { tools.remove(tool) }
                MCPServer.ReadGrants.set(tools, list)
                readsRevision += 1
            }))
            .toggleStyle(.checkbox)
            .font(.caption)
    }

    /// One tool: whether it is here, whether Binders is in it, a button to add it, and the way to do it by hand.
    private func hostRow(_ host: MCPHost) -> some View {
        let _ = hostRevision
        let status = host.status
        return LabeledContent(host.label) {
            HStack(spacing: 8) {
                if let message = hostMessages[host] {
                    if message.hasPrefix("Added") || message.hasPrefix("Removed") {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        StatusLabel(message, .problem).font(.caption).lineLimit(2)
                    }
                } else if !status.present {
                    Text("Not found on this Mac").font(.caption).foregroundStyle(.tertiary)
                } else if status.configured {
                    StatusLabel("Added", .ready).font(.caption)
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
                if host.removable, status.configured {
                    Button("Remove") {
                        do {
                            hostMessages[host] = try host.remove()
                        } catch {
                            hostMessages[host] = error.localizedDescription
                        }
                        hostRevision += 1
                    }
                }
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
struct AutomationEditor: View {
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
    /// The rule as saved, and its web hook token for the Keychain: nil leaves it as it is, "" removes it.
    let onSave: (AutomationRule, String?) -> Void
    private let id: UUID
    private let isEnabled: Bool
    /// A token for this rule is in the Keychain already.
    private let hasToken: Bool
    @State private var name: String
    @State private var triggerKind: TriggerKind
    @State private var phrase = ""
    @State private var event: AutomationEvent = .todoAdded
    @State private var anyOrigin: Bool
    @State private var actionKind: ActionKind
    @State private var shortcutName = ""
    @State private var shortcutInput = "{text}"
    @State private var urlTemplate = ""
    @State private var script = ""
    @State private var webhookURL = ""
    @State private var webhookBody = ""
    @State private var token = ""
    @State private var removingToken = false
    @State private var shortcuts: [String] = []
    @State private var testing = false
    @State private var testOutcome: AutomationService.Outcome?

    init(rule: AutomationRule, onSave: @escaping (AutomationRule, String?) -> Void) {
        self.onSave = onSave
        id = rule.id
        isEnabled = rule.isEnabled
        hasToken = AutomationService.shared.withToken.contains(rule.id)
        _name = State(initialValue: rule.name)
        _anyOrigin = State(initialValue: rule.anyOrigin == true)
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
        return AutomationRule(id: id, name: name.trimmed, isEnabled: isEnabled, trigger: trigger, action: action,
                              anyOrigin: takesOtherTodos && anyOrigin ? true : nil)
    }

    /// The rule runs when a to-do is added, so where the to-do came from matters.
    private var takesOtherTodos: Bool { triggerKind == .event && event == .todoAdded }

    /// The token to keep: what was typed, "" to remove the saved one, nil to leave it.
    private var tokenToSave: String? {
        guard actionKind == .webhook else { return nil }
        if !token.trimmed.isEmpty { return token.trimmed }
        return removingToken ? "" : nil
    }

    /// Why the link can't be used as it is, shown under it.
    private var urlProblem: String? {
        guard actionKind == .url, !urlTemplate.trimmed.isEmpty else { return nil }
        return AutomationTemplate.urlProblem(urlTemplate)
    }

    private var isComplete: Bool {
        guard !name.trimmed.isEmpty else { return false }
        if triggerKind == .phrase, phrase.trimmed.isEmpty { return false }
        switch actionKind {
        case .shortcut: return !shortcutName.trimmed.isEmpty
        case .url: return !urlTemplate.trimmed.isEmpty && urlProblem == nil
        case .script: return !script.trimmed.isEmpty && AgentCommands.isAllowed(script)
        case .webhook: return !webhookURL.trimmed.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    StackedField(label: "Name", text: $name, prompt: "Send to Things", probe: "field.automation.name")
                }
                Section("When") {
                    Picker("Trigger", selection: $triggerKind) {
                        Text("I say a phrase in Command Mode").tag(TriggerKind.phrase)
                        Text("Something happens in Binders").tag(TriggerKind.event)
                    }
                    if triggerKind == .phrase {
                        StackedField(label: "Phrase", text: $phrase, prompt: "send to things", probe: "field.automation.phrase")
                        Text("Hold fn ⌃ and say the phrase, then the rest: what follows is {text}; a time at the end becomes {when} and {date}.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Event", selection: $event) {
                            ForEach(AutomationEvent.allCases) { Text($0.title).tag($0) }
                        }
                        if takesOtherTodos {
                            Toggle("Also for to-dos said to yourself, from agents and from links", isOn: $anyOrigin)
                            Text(anyOrigin
                                 ? "It also runs for “Binders, …” and Tell Binders, which works with your iPhone locked, and for to-dos agents and links add, so they can leave this Mac without a tap."
                                 : "It runs for to-dos you made: typed, dictated, or a suggestion you tapped Add on. Nothing you said to yourself, and nothing an agent or a link added, goes through it without your tap.")
                                .font(.caption).foregroundStyle(.secondary)
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
                            StackedField(label: "Shortcut name", text: $shortcutName, probe: "field.automation.shortcutName")
                        } else {
                            Picker("Shortcut", selection: $shortcutName) {
                                Text("Choose…").tag("")
                                if !shortcutName.isEmpty, !shortcuts.contains(shortcutName) { Text(shortcutName).tag(shortcutName) }
                                ForEach(shortcuts, id: \.self) { Text($0).tag($0) }
                            }
                        }
                        StackedField(label: "Input the Shortcut receives", text: $shortcutInput, prompt: "{text}", probe: "field.automation.shortcutInput")
                    case .url:
                        StackedField(label: "URL", text: $urlTemplate, prompt: "things:///add?title={title}&when={date}", probe: "field.automation.url")
                        if let urlProblem {
                            Label(urlProblem, systemImage: "exclamationmark.circle").font(.caption)
                        } else {
                            Text("Placeholders go in the query, after ?, and are percent-encoded, so what a to-do or binder says can't change what the link opens.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    case .script:
                        StackedField(label: "Command (zsh)", text: $script, prompt: "echo \"$BINDERS_TEXT\" >> ~/log.txt", lines: 2...6, monospaced: true,
                                     probe: "field.automation.command")
                        Text("The payload arrives as BINDERS_TEXT, BINDERS_TITLE, BINDERS_WHEN, BINDERS_DATE…, a to-do's BINDERS_TODO_ORIGIN (voice, phone, suggestion, moment, agent or link), and the text on standard input.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .webhook:
                        StackedField(label: "URL", text: $webhookURL, prompt: "https://…", probe: "field.automation.webhookURL")
                        StackedField(label: "JSON body", text: $webhookBody, prompt: "Leave empty to send every field", lines: 2...6, monospaced: true,
                                     probe: "field.automation.body")
                        StackedField(label: "Token (kept in the Keychain)", text: $token,
                                     prompt: hasToken && !removingToken ? "Kept in your Keychain" : "None", secure: true, probe: "field.automation.token") {
                            if hasToken, token.isEmpty {
                                Button(removingToken ? "Keep Token" : "Remove Token") { removingToken.toggle() }
                            }
                        }
                        Text("Placeholders are escaped for JSON. This sends the payload off this Mac, to the address above. A token goes with it as Authorization: Bearer, from your Keychain, never from automations.json.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack {
                        Button(testing ? "Testing…" : "Test with sample text") {
                            Task {
                                testing = true
                                testOutcome = await AutomationService.shared.run(rule, payload: AutomationService.sample, quietly: true, token: tokenToSave)
                                testing = false
                            }
                        }
                        .disabled(!isComplete || testing)
                        if let testOutcome {
                            Label(testOutcome.message, systemImage: testOutcome.ok ? "checkmark" : BindersTheme.problemSymbol)
                                .font(.caption).foregroundStyle(testOutcome.ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)).lineLimit(2)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(rule, tokenToSave)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isComplete)
            }
            .padding(12)
        }
        .frame(width: 580, height: 560)
        .pageGround()
        .task { shortcuts = await AutomationService.installedShortcuts() }
    }
}

// MARK: - Shortcut recorder

/// One shortcut in Settings. Recording goes through the same event tap that runs the shortcuts, which hands every key
/// to the recorder meanwhile: pressing a shortcut that is already set records it instead of doing it.
private struct ShortcutField: View {
    @Environment(DictationController.self) private var controller
    /// Which shortcut this is, among all the fields on the page.
    let key: String
    /// Held while you talk (dictation), rather than pressed to do something.
    let isHold: Bool
    /// A menu's shortcut needs a key; a modifier on its own or tapped twice won't do.
    var requiresKey = false
    var removable = true
    let hotkey: Hotkey?
    @Binding var recording: String?
    let onRecord: (Hotkey) -> Void
    let onClear: () -> Void

    @State private var recorder = ShortcutRecorder(isHold: false)
    @State private var live = ""
    @State private var hint: String?
    @State private var localMonitor: Any?
    @State private var tick: Task<Void, Never>?

    private var isRecording: Bool { recording == key }

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
                .tint(isRecording ? BindersTheme.accent : nil)
                .buttonStyle(.bordered)
                // Always there, hidden when it can't be used, so every field lines up.
                let clearable = removable && hotkey != nil && !isRecording
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
        .onChange(of: recording) { _, current in
            if current != key { stop(clearOwner: false) }
        }
        .onDisappear { stop() }
        // Leaving the app mid-recording would otherwise keep the shortcuts off.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func start() {
        recording = key
        recorder = ShortcutRecorder(isHold: isHold)
        live = ""
        hint = requiresKey ? "A key with ⌘, ⌥ or ⌃, such as ⌥⌘B." : isHold ? nil : "A key combination, or tap a modifier twice."
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
            if requiresKey, hotkey.keyCode == nil {
                // Menus can't use a modifier alone: keep listening for a key.
                recorder = ShortcutRecorder(isHold: false)
                live = ""
                hint = "A menu shortcut needs a key as well, such as ⌥⌘B."
                return
            }
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
            recording = nil
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
