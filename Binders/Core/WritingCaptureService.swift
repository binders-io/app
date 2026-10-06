import AppKit
import ApplicationServices
import Observation
import BindersKit

/// Writing capture: while switched on, keeps what you write in allowed apps once you've sent or saved it. It never
/// records keystrokes. It watches the focused text field through Accessibility and files its contents the moment the
/// field is cleared (a message went out) or the window it lived in has been gone for a while (a mail was sent, a
/// document closed). Secure fields are never read; secrets are redacted before anything is stored.
@MainActor
@Observable
final class WritingCaptureService {
    private(set) var isOn = false
    private(set) var capturedThisSession = 0
    private(set) var lastCaptureSummary: String?
    /// Runs after a message is filed (promise detection hangs off it).
    var afterCommit: ((WritingRecord) -> Void)?

    /// Apps whose fields may be captured, and which of them are browsers (captured only on allowed sites).
    static let knownApps: [(bundleID: String, name: String, isBrowser: Bool)] = [
        ("com.microsoft.teams2", "Microsoft Teams", false),
        ("com.microsoft.teams", "Microsoft Teams (classic)", false),
        ("com.microsoft.Outlook", "Microsoft Outlook", false),
        ("com.apple.mail", "Mail", false),
        ("com.tinyspeck.slackmacgap", "Slack", false),
        ("com.google.Chrome", "Google Chrome", true),
        ("com.apple.Safari", "Safari", true),
        ("com.microsoft.edgemac", "Microsoft Edge", true),
        ("org.mozilla.firefox", "Firefox", true),
        ("company.thebrowser.Browser", "Arc", true),
    ]
    static let defaultApps = ["com.microsoft.teams2", "com.microsoft.teams", "com.microsoft.Outlook", "com.apple.mail",
                              "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac"]
    static let defaultHosts = ["teams.microsoft.com", "teams.cloud.microsoft", "outlook.office.com", "outlook.office365.com",
                               "outlook.live.com", "mail.google.com"]
    /// Never captured, whatever the allow-list says.
    private static let deniedApps: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.lastpass.lastpassmacapp",
                                                  "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords", "com.apple.Terminal",
                                                  "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
                                                  "org.alacritty", "com.github.wez.wezterm"]
    private static let deniedURLWords = ["login", "signin", "sign-in", "auth", "password", "checkout", "payment", "bank", "wallet"]
    /// Built on Chromium: their text fields are only exposed once asked, see `ContextReader.setEnhancedAccessibility`.
    private static let chromiumApps: Set<String> = ["com.microsoft.teams2", "com.google.Chrome", "com.microsoft.edgemac", "com.tinyspeck.slackmacgap",
                                                    "company.thebrowser.Browser", "com.brave.Browser", "com.vivaldi.Vivaldi"]
    /// Browsers beyond the ones listed in Settings, for apps added there: captured on allowed sites only, like the others.
    private static let otherBrowsers: Set<String> = ["com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.kagi.kagimacOS",
                                                     "com.duckduckgo.macos.browser", "app.zen-browser.zen", "com.google.Chrome.beta",
                                                     "com.google.Chrome.canary", "com.microsoft.edgemac.Beta", "org.mozilla.firefoxdeveloperedition"]

    nonisolated static func isBrowser(_ bundleID: String) -> Bool {
        knownApps.first { $0.bundleID == bundleID }?.isBrowser ?? otherBrowsers.contains(bundleID)
    }

    /// Password managers and terminals, which are never captured.
    nonisolated static func isNeverCaptured(_ bundleID: String) -> Bool { deniedApps.contains(bundleID) }

    /// Terminals, whose screens aren't read: the prompts you send agents in them are, from the agents' own history.
    nonisolated static func isTerminal(_ bundleID: String) -> Bool {
        ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
         "org.alacritty", "com.github.wez.wezterm"].contains(bundleID)
    }

    /// An app's name as Finder shows it, from its bundle identifier.
    nonisolated static func appName(_ bundleID: String) -> String {
        if let known = knownApps.first(where: { $0.bundleID == bundleID }) { return known.name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Electron apps (Discord, Notion, WhatsApp…) are Chromium inside, and need asking for their text fields too.
    private static var electron: [String: Bool] = [:]
    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        if let known = electron[id] { return known }
        let found = app.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) } ?? false
        electron[id] = found
        return found
    }

    private struct Draft {
        var key: String
        var text: String
        var context: AppContext
        var recipients: [String]
        var subject: String?
        var placeholder: String?
        var lastSeen: Date
        var missingSince: Date?
    }

    private let flowBar: FlowBarController
    private var timer: Timer?
    private var draft: Draft?
    private var recentHashes: [String: Date] = [:]
    private var lastCommittedByKey: [String: String] = [:]
    private var lastNoField: (key: String, at: Date)?
    private var enhancedPIDs = Set<pid_t>()
    private var observers: [pid_t: AXObserver] = [:]
    private var lastNotifiedTick = Date.distantPast
    private var pendingTick: DispatchWorkItem?
    private var lastSiteNote: (host: String, at: Date)?
    private let agents = AgentPromptCapture()
    private var settings: AppSettings { AppSettings.shared }
    /// The harnesses capture reads now: the ones on this Mac that aren't turned off.
    private var agentHarnesses: [AgentHarness] {
        AgentHarnesses.all().filter { !settings.captureAgentsOff.contains($0.id) && AgentHarnesses.isInstalled($0) }
    }

    init(flowBar: FlowBarController) {
        self.flowBar = flowBar
    }

    var hotkeyHint: String { settings.hotkeys.capture?.displayString() ?? "the menu bar" }

    func toggle() {
        if isOn { stop() } else { start() }
    }

    /// `requireAccessibility` is false only in tests: prompts to agents don't need it, reading other apps' fields does.
    func start(requireAccessibility: Bool = true) {
        guard !isOn else { return }
        guard AXIsProcessTrusted() || !requireAccessibility else {
            flowBar.toast("Writing capture needs Accessibility access — grant it in Settings", symbol: "pencil.slash", duration: 5)
            return
        }
        isOn = true
        capturedThisSession = 0
        draft = nil
        for app in NSWorkspace.shared.runningApplications where Self.isAllowed(bundleID: app.bundleIdentifier ?? "", apps: settings.captureApps) {
            requestFullAccessibility(of: app)
        }
        // Hooks keep prompts only while this is there; their record starts empty each time.
        FileManager.default.createFile(atPath: AgentHarnesses.captureFlag.path, contents: nil)
        try? Data().write(to: AgentHarnesses.hookRecord)
        agents.start(agentHarnesses)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        let apps = Self.knownApps.filter { settings.captureApps.contains($0.bundleID) && !$0.isBrowser }.map(\.name)
            + settings.captureApps.filter { id in !Self.knownApps.contains { $0.bundleID == id } && !Self.isBrowser(id) }.map(Self.appName)
        let browsers = settings.captureApps.contains(where: Self.isBrowser)
        var scope = apps
        if browsers { scope.append(settings.captureAllSites ? "any website" : "mail and chat sites") }
        scope += agentHarnesses.filter { $0.id != AgentHarness.hooksID && !AgentHarnesses.files(of: $0).isEmpty }.map { "prompts to \($0.name)" }
        flowBar.toast("Writing capture on · \(scope.isEmpty ? "no apps allowed yet" : scope.joined(separator: ", ")) · \(hotkeyHint) to stop",
                      symbol: "pencil.line", duration: 5)
        Log.app.notice("Writing capture on")
    }

    func stop() {
        guard isOn else { return }
        keepAgentPrompts()
        agents.stop()
        try? FileManager.default.removeItem(at: AgentHarnesses.captureFlag)
        if let draft, !draft.text.isEmpty { commit(draft) }
        draft = nil
        timer?.invalidate()
        timer = nil
        isOn = false
        if !NSWorkspace.shared.isVoiceOverEnabled {
            for pid in enhancedPIDs { ContextReader.setEnhancedAccessibility(pid: pid, enabled: false) }
        }
        enhancedPIDs.removeAll()
        stopObserving()
        flowBar.toast(capturedThisSession == 0 ? "Writing capture off" : "Writing capture off · kept \(capturedThisSession) \(capturedThisSession == 1 ? "message" : "messages")",
                      symbol: "pencil.slash", duration: 4)
        Log.app.notice("Writing capture off after \(self.capturedThisSession) captures")
    }

    // MARK: Watching

    private func tick() {
        keepAgentPrompts()
        guard isOn, let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier ?? ""
        guard Self.isAllowed(bundleID: bundleID, apps: settings.captureApps) else {
            noteFieldGone()
            return
        }
        requestFullAccessibility(of: app)
        observe(app)
        let snapshot = ContextReader.capture(pid: app.processIdentifier, bundleID: bundleID, appName: app.localizedName)
        if snapshot.isSecure {
            draft = nil
            return
        }
        let isBrowser = Self.isBrowser(bundleID)
        if Self.isHeaderOrSearchField(label: snapshot.fieldLabel) {
            // The To, Subject or a search box: part of the same message (or not writing at all), never a message of its own.
            if var current = draft, current.key == Self.key(for: app, snapshot: snapshot) { current.missingSince = nil; draft = current }
            return
        }
        if isBrowser {
            guard let url = snapshot.context.url, Self.isAllowed(url: url, hosts: settings.captureHosts, allSites: settings.captureAllSites) else {
                let host = snapshot.context.url.flatMap { URLComponents(string: $0)?.host } ?? "no page"
                if lastSiteNote?.host != host || Date().timeIntervalSince(lastSiteNote?.at ?? .distantPast) > 60 {
                    lastSiteNote = (host, Date())
                    Log.app.notice("Capture: \(app.localizedName ?? bundleID, privacy: .public) on \(host, privacy: .private) is not captured (\(snapshot.context.url == nil ? "not a web page" : "site not allowed", privacy: .public))")
                }
                noteFieldGone()
                return
            }
        } else if let url = snapshot.context.url, !Self.isAllowed(url: url, hosts: settings.captureHosts, allSites: true) {
            // An embedded web view inside an allowed app can still be a login page.
            noteFieldGone()
            return
        }
        let key = Self.key(for: app, snapshot: snapshot)
        let text = (snapshot.value ?? "").replacingOccurrences(of: "\\p{Cf}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.wordCount
        if snapshot.value == nil {
            let noteKey = "\(bundleID)|\(snapshot.focusedRole ?? "none")"
            if lastNoField?.key != noteKey || Date().timeIntervalSince(lastNoField?.at ?? .distantPast) > 60 {
                lastNoField = (noteKey, Date())
                Log.app.notice("Capture: \(app.localizedName ?? bundleID, privacy: .public) focus is \(snapshot.focusedRole ?? "nothing", privacy: .public), no readable value")
            }
        }

        if words >= 3 {
            if var current = draft, current.key == key {
                current.text = text
                current.context = snapshot.context
                current.lastSeen = Date()
                current.missingSince = nil
                draft = current
            } else {
                if let previous = draft { commit(previous) }
                let header = ContextReader.headerFields(pid: app.processIdentifier)
                let recipients = Self.recipients(from: snapshot.context, header: header)
                draft = Draft(key: key, text: text, context: snapshot.context,
                              recipients: recipients, subject: header.subject, placeholder: snapshot.placeholder,
                              lastSeen: Date(), missingSince: nil)
                Log.app.notice("Capture: draft in \(app.localizedName ?? bundleID, privacy: .public) (\(snapshot.focusedRole ?? "?", privacy: .public)), \(words) words, to \(recipients.count) recipient(s)")
            }
            return
        }

        // The field is empty or something else is focused.
        guard var current = draft else { return }
        if current.key == key, snapshot.value != nil {
            // Same window, same field, now empty: the message went out.
            commit(current)
            draft = nil
        } else {
            noteFieldGone()
            if let since = draft?.missingSince, Date().timeIntervalSince(since) >= 8 {
                current = draft!
                commit(current)
                draft = nil
            }
        }
    }

    // MARK: Field change notifications

    /// Polling alone reads the field up to 1.5 s late, so a message sent right after typing lost its last letters.
    /// Value and focus notifications from the app trigger an immediate read instead.
    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, writingCaptureObserverCallback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func stopObserving() {
        for observer in observers.values { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
        observers.removeAll()
        pendingTick?.cancel()
        pendingTick = nil
    }

    /// Reads at most every 40 ms during a burst of notifications, always ending with a trailing read.
    fileprivate func fieldChanged() {
        guard isOn else { return }
        let elapsed = Date().timeIntervalSince(lastNotifiedTick)
        if elapsed >= 0.04 {
            lastNotifiedTick = Date()
            tick()
        } else if pendingTick == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingTick = nil
                self.lastNotifiedTick = Date()
                self.tick()
            }
            pendingTick = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.04 - elapsed), execute: item)
        }
    }

    /// Which window and page a field belongs to. The unread count Teams prefixes to its title must not look like a new
    /// window, and Outlook puts the subject in the title, so there only the account part counts.
    private static func key(for app: NSRunningApplication, snapshot: FocusSnapshot) -> String {
        var title = (snapshot.context.windowTitle ?? "").replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        if app.bundleIdentifier == "com.microsoft.Outlook", let range = title.range(of: " • ") { title = String(title[range.upperBound...]) }
        return "\(app.processIdentifier)|\(title)|\(pageKey(snapshot.context.url) ?? "")"
    }

    /// "To", "Subject", "Search (⌘ E)": a short label that is the field's job. A long description is prose about a body.
    static func isHeaderOrSearchField(label: String) -> Bool {
        label.split(separator: "|").contains { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            return trimmed.split(separator: " ").count <= 3
                && trimmed.range(of: #"^(to|cc|bcc|subject|search|find|address|recipients?|url|location|from)\b"#, options: .regularExpression) != nil
        }
    }

    private func requestFullAccessibility(of app: NSRunningApplication) {
        guard Self.chromiumApps.contains(app.bundleIdentifier ?? "") || Self.isElectron(app), enhancedPIDs.insert(app.processIdentifier).inserted else { return }
        ContextReader.setEnhancedAccessibility(pid: app.processIdentifier, enabled: true)
    }

    private func noteFieldGone() {
        guard var current = draft else { return }
        if current.missingSince == nil {
            current.missingSince = Date()
            draft = current
        } else if Date().timeIntervalSince(current.missingSince!) >= 8 {
            commit(current)
            draft = nil
        }
    }

    // MARK: Filing

    private func commit(_ draft: Draft) {
        let text = WritingCleanup.stripSignature(draft.text.trimmingCharacters(in: .whitespacesAndNewlines), userName: NSFullUserName())
        guard text.wordCount >= 3, text.contains(where: \.isLetter) else { return }
        if let placeholder = draft.placeholder, ContextReader.comparable(placeholder) == ContextReader.comparable(text) { return }
        if lastCommittedByKey[draft.key] == text { return }
        let hash = text.hashValue.description
        if let seen = recentHashes[hash], Date().timeIntervalSince(seen) < 600 { return }
        recentHashes[hash] = Date()
        recentHashes = recentHashes.filter { Date().timeIntervalSince($0.value) < 3_600 }
        lastCommittedByKey[draft.key] = text

        let redacted = Redactor.redact(text)
        let record = WritingRecord(text: redacted.text)
        record.appName = draft.context.appName
        record.bundleID = draft.context.bundleID
        record.windowTitle = draft.context.windowTitle
        record.url = draft.context.url
        record.recipients = draft.recipients.joined(separator: ", ")
        record.subject = draft.subject
        record.redactions = redacted.count
        record.source = Self.source(bundleID: draft.context.bundleID ?? "", url: draft.context.url)
        let binder = Store.shared.binder(settings.currentBinderID) ?? Store.shared.defaultBinder()
        record.binderID = binder.id
        Store.shared.insert(record)
        AutomationService.shared.fire(.writingCaptured, payload: AutomationPayload(
            text: redacted.text, title: draft.subject ?? "", app: draft.context.appName ?? "", binder: binder.name,
            summary: draft.recipients.joined(separator: ", "), link: "binders://open?section=writing"))
        capturedThisSession += 1
        Log.app.notice("Capture: kept \(record.wordCount) words from \(record.appName ?? "app", privacy: .public), \(redacted.count) redacted")
        afterCommit?(record)
        let target = draft.recipients.first.map { " → \($0)" } ?? (draft.subject.map { " · \($0)" } ?? "")
        lastCaptureSummary = "\(draft.context.appName ?? "app")\(target)"
        flowBar.toast("Kept \(record.wordCount) words\(target)\(redacted.count > 0 ? " · \(redacted.count) redacted" : "")", symbol: "pencil.line", duration: 2.5)
    }

    // MARK: Agents in the terminal

    /// What you sent AI agents since the last look, kept like other writing: redacted, in the open binder, searchable.
    /// They're instructions to an agent, not promises to people, so they aren't read for to-dos.
    private func keepAgentPrompts() {
        guard isOn else { return }
        for (tool, prompt) in agents.poll() {
            let hash = (tool + prompt.text).hashValue.description
            if let seen = recentHashes[hash], Date().timeIntervalSince(seen) < 600 { continue }
            recentHashes[hash] = Date()
            let redacted = Redactor.redact(prompt.text)
            let record = WritingRecord(text: redacted.text)
            record.createdAt = prompt.date
            record.appName = tool
            record.subject = prompt.projectName.map { "\(tool) · \($0)" } ?? tool
            record.windowTitle = prompt.project
            record.redactions = redacted.count
            record.source = "agent"
            record.analyzedAt = Date()
            let binder = Store.shared.binder(settings.currentBinderID) ?? Store.shared.defaultBinder()
            record.binderID = binder.id
            Store.shared.insert(record)
            AutomationService.shared.fire(.writingCaptured, payload: AutomationPayload(
                text: redacted.text, title: record.subject ?? "", app: tool, binder: binder.name, summary: "",
                link: "binders://open?section=writing"))
            capturedThisSession += 1
            lastCaptureSummary = record.subject
            Log.app.notice("Capture: kept \(record.wordCount) words sent to \(tool, privacy: .public), \(redacted.count) redacted")
        }
    }

    // MARK: Rules

    static func isAllowed(bundleID: String, apps: [String]) -> Bool {
        !deniedApps.contains(bundleID) && apps.contains(bundleID)
    }

    static func isAllowed(url: String, hosts: [String], allSites: Bool) -> Bool {
        guard let components = URLComponents(string: url), let host = components.host?.lowercased() else { return allSites }
        let path = (components.path + (components.fragment ?? "")).lowercased()
        if deniedURLWords.contains(where: { host.contains($0) || path.contains($0) }) { return false }
        if allSites { return true }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func pageKey(_ url: String?) -> String? {
        guard let url, let components = URLComponents(string: url) else { return nil }
        return (components.host ?? "") + components.path + (components.fragment.map { "#" + $0 } ?? "")
    }

    static func source(bundleID: String, url: String?) -> String {
        if bundleID.hasPrefix("com.microsoft.teams") || (url?.contains("teams.") ?? false) { return "teams" }
        if bundleID == "com.microsoft.Outlook" || (url?.contains("outlook.") ?? false) { return "outlook" }
        if bundleID == "com.apple.mail" || (url?.contains("mail.google.com") ?? false) { return "mail" }
        if bundleID == "com.tinyspeck.slackmacgap" { return "slack" }
        return isBrowser(bundleID) ? "browser" : "other"
    }

    /// Who the writing is for: the To field when the window exposes one, else the person or channel named in the
    /// window title ("Noah Chen | Microsoft Teams", "Chat | Acme | Microsoft Teams").
    static func recipients(from context: AppContext, header: ContextReader.HeaderFields) -> [String] {
        let fromHeader = header.to.compactMap(WritingCleanup.cleanName)
        if !fromHeader.isEmpty { return fromHeader }
        // A browser's title is the page, not a person; only chat apps name the conversation in the title.
        if isBrowser(context.bundleID ?? "") { return [] }
        guard let title = context.windowTitle, title.contains(" | ") else { return [] }
        var parts = title.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }
        parts.removeAll { $0.isEmpty || $0.localizedCaseInsensitiveContains("Microsoft Teams") || $0.localizedCaseInsensitiveContains("Outlook") }
        parts = parts.map { $0.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression) }
        let generic: Set<String> = ["chat", "activity", "teams", "calendar", "calls", "files", "mail", "inbox", "compose"]
        if let name = parts.last(where: { !generic.contains($0.lowercased()) }), name.count <= 80 {
            return name.components(separatedBy: ",").compactMap(WritingCleanup.cleanName)
        }
        return []
    }
}

private func writingCaptureObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let service = Unmanaged<WritingCaptureService>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { service.fieldChanged() }
}
