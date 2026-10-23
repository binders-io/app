import AppKit
import SwiftUI
import BindersKit

extension SelfTest {
    /// Lane UI1, part of --selftest-window-fit: every text field in Settings and in its sheets has its name above it and a
    /// box from the row's left edge, at least half the row wide, inside the window (`StackedField`, by its `field.` probes).
    /// Each Settings page, scrolled top to bottom, at 1020 × 720 and 840 × 560, light and dark (AI once for each provider,
    /// Writing with listed sites, iPhone with its addresses); then the agent editor (Claude Code, a command over SSH, a
    /// web hook with a status address, Codex), the automation editor (a command, a web hook), the team database's sheets, the
    /// decision server's, and where MLX models come from, opened. Draws each screen to `directory` as it scrolls:
    /// settings-<page>-<width>-<theme>-<step>.png and sheet-<name>-<theme>-<step>.png.
    @MainActor
    static func formFieldsFit(directory: URL, controller: DictationController, hub: (@escaping (HubNavigation) -> Void) -> AnyView,
                              check: (Bool, String) -> Void) async {
        let themes: [(name: String, appearance: NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        var seen = Set<String>()

        /// The fields shown in `window` now, each checked against `bounds`; their names go into `seen`.
        func fields(in window: NSWindow, within bounds: NSRect) -> (names: Set<String>, bad: [String]) {
            let shown = Set(FitProbe.all(in: window).map(\.name).filter { $0.hasPrefix("field.") && !$0.hasSuffix(".box") })
            var bad: [String] = []
            for name in shown.sorted() {
                guard let row = FitProbe.frames(name, in: window).first, let box = FitProbe.frames(name + ".box", in: window).first else {
                    bad.append("\(name) has no box")
                    continue
                }
                seen.insert(name)
                // Window coordinates, origin at the bottom left: the name's line sits above the box's top.
                let underName = row.maxY - box.maxY >= 10
                let fromLeft = abs(box.minX - row.minX) < 1
                let wide = box.width >= row.width * 0.5
                let inside = box.minX >= bounds.minX - 0.5 && box.maxX <= bounds.maxX + 0.5 && row.maxX <= bounds.maxX + 0.5
                if !(underName && fromLeft && wide && inside) {
                    bad.append("\(name): box \(Int(box.minX))–\(Int(box.maxX)) y\(Int(box.maxY)), row \(Int(row.minX))–\(Int(row.maxX)) y\(Int(row.maxY))")
                }
            }
            return (shown, bad)
        }

        /// The form's scroll view: the tallest one at least 300 pt wide.
        func formScroll(in view: NSView) -> NSScrollView? {
            var found: [NSScrollView] = []
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView, scroll.frame.width >= 300 { found.append(scroll) }
                view.subviews.forEach(walk)
            }
            walk(view)
            return found.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
        }

        /// Scrolls the form top to bottom a screen at a time, checking the fields and drawing each screen.
        func walkForm(_ window: NSWindow, bounds: () -> NSRect, label: String, drawing name: String) async {
            guard let content = window.contentView else { return check(false, "\(label): its window has a view") }
            var names = Set<String>(), bad: [String] = [], step = 0
            let scroll = formScroll(in: content)
            if let scroll, let document = scroll.documentView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? 0 : max(0, document.frame.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            while step < 14 {
                try? await Task.sleep(for: .milliseconds(step == 0 ? 400 : 350))
                content.layoutSubtreeIfNeeded()
                let found = fields(in: window, within: bounds())
                names.formUnion(found.names)
                bad += found.bad
                snapshot(content, name: "\(name)-\(step)", directory: directory)
                guard let scroll, let document = scroll.documentView else { break }
                let visible = scroll.contentView.bounds
                let total = document.frame.height
                let shownTo = document.isFlipped ? visible.maxY : total - visible.minY
                if shownTo >= total - 1 { break }
                let next = min(total - visible.height, (document.isFlipped ? visible.minY : total - visible.maxY) + visible.height * 0.85)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? next : total - visible.height - next))
                scroll.reflectScrolledClipView(scroll.contentView)
                step += 1
            }
            check(bad.isEmpty, "\(label): \(names.count) text fields shown, each with its name above a box from the row's left edge, inside the window"
                  + (bad.isEmpty ? "" : "; " + Array(Set(bad)).sorted().joined(separator: "; ")))
        }

        // Settings, every page.
        let settings = AppSettings.shared
        let provider = settings.llmProvider, allSites = settings.captureAllSites, phoneLink = settings.phoneLink
        defer { settings.llmProvider = provider; settings.captureAllSites = allSites; settings.phoneLink = phoneLink }
        // Listed sites, and Your iPhone's addresses (the setting alone, in the throwaway store: nothing starts listening).
        settings.captureAllSites = false
        settings.phoneLink = true
        var runs: [(name: String, group: SettingsPage.Group, provider: LLMProviderKind?)] = SettingsPage.Group.allCases
            .filter { !$0.visiblePages.isEmpty }.map { ($0 == .intelligence ? "intelligence-\(provider.rawValue)" : $0.rawValue, $0, nil) }
        for other in LLMProviderKind.available where other != provider {
            runs.append(("intelligence-\(other.rawValue)", .intelligence, other))
        }
        for run in runs {
            settings.llmProvider = run.provider ?? provider
            guard let first = run.group.visiblePages.first else { continue }
            let window = HubWindowController.makeWindow(hub { $0.selection = .settings; $0.pendingSettingsPage = first }, size: HubWindowController.defaultSize)
            window.alphaValue = 0
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(2_000))
            let slug = run.name.lowercased().replacingOccurrences(of: " ", with: "-")
            for size in [HubWindowController.defaultSize, HubWindowController.smallestSize] {
                window.setContentSize(size)
                for theme in themes {
                    window.appearance = NSAppearance(named: theme.appearance)
                    try? await Task.sleep(for: .milliseconds(600))
                    let pane: () -> NSRect = {
                        let sidebar = FitProbe.frames("sidebar", in: window).first
                        return NSRect(x: sidebar?.maxX ?? 0, y: 0, width: size.width - (sidebar?.maxX ?? 0), height: size.height)
                    }
                    await walkForm(window, bounds: pane, label: "Settings → \(run.name) at \(Int(size.width)) × \(Int(size.height)), \(theme.name)",
                                   drawing: "settings-\(slug)-\(Int(size.width))-\(theme.name)")
                }
            }
            window.close()
            try? await Task.sleep(for: .milliseconds(200))
        }
        settings.llmProvider = provider

        // The sheets, at their own sizes.
        let repository = AppPaths.support.appendingPathComponent("harbor-web", isDirectory: true)
        try? FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let claude = AgentProfile(name: "Claude Code · harbor-web",
                                  wake: .claudeCode(ClaudeCodeWake(repository: repository.path, model: "sonnet", maxBudgetUSD: 5,
                                                                   allowedDomains: ["github.com", "registry.npmjs.org", "pypi.org", "files.pythonhosted.org"])),
                                  vendor: "Anthropic", purpose: "Code changes in the harbor website: fixes, small features and their tests, reviewed before they merge")
        let command = AgentProfile(name: "Errands", wake: .command(command: "~/bin/wake-agent --board harbor --notify", folder: nil),
                                   report: .ssh(host: "sam@studio-mac.local"), purpose: "Personal errands: appointments, email, bookings")
        let hook = AgentProfile(name: "Pennant", wake: .webhook(url: "https://agents.example.test/pennant/wake"), report: .status(url: "https://agents.example.test/pennant/status"))
        let codex = AgentProfile(name: "Codex · harbor-web", wake: .cliAgent(CLIAgentWake(tool: .codex, repository: repository.path)))
        let script = AutomationRule(name: "Log to-dos", trigger: .phrase(text: "log this"), action: .script(command: "echo \"$BINDERS_TEXT\" >> ~/log.txt"))
        let webhook = AutomationRule(name: "Post to-dos", trigger: .event(name: .todoAdded),
                                     action: .webhook(url: "https://example.test/hook", body: "{\"title\": \"{title}\", \"binder\": \"{binder}\"}"))
        func environment<V: View>(_ view: V) -> AnyView {
            AnyView(view.environment(controller).environment(controller.team).environment(AppSettings.shared).modelContainer(Store.shared.container)
                .defaultAppStorage(throwawayDefaults))
        }
        let sheets: [(name: String, size: NSSize, view: AnyView)] = [
            ("agent-claude", NSSize(width: 600, height: 660), environment(AgentEditor(agent: claude, isNew: false))),
            ("agent-command", NSSize(width: 600, height: 660), environment(AgentEditor(agent: command, isNew: false))),
            ("agent-webhook", NSSize(width: 600, height: 660), environment(AgentEditor(agent: hook, isNew: false))),
            ("agent-codex", NSSize(width: 600, height: 660), environment(AgentEditor(agent: codex, isNew: false))),
            ("automation-command", NSSize(width: 580, height: 560), environment(AutomationEditor(rule: script) { _, _ in })),
            ("automation-webhook", NSSize(width: 580, height: 560), environment(AutomationEditor(rule: webhook) { _, _ in })),
            ("team-database", NSSize(width: 520, height: 640), environment(TeamDatabaseSetUpSheet { _ in })),
            ("team-update", NSSize(width: 480, height: 360), environment(TeamDatabaseUpdateSheet { _ in })),
            ("team-member", NSSize(width: 460, height: 420), environment(TeamAddMemberSheet { _ in })),
            ("decision-server", NSSize(width: 520, height: 320), environment(DecisionServerSheet(address: "") { _ in })),
            // Settings → AI's "Where models come from", opened, in a grouped form as the page has it.
            ("mlx-source", NSSize(width: 560, height: 300), environment(Form { MLXModelSource(shows: true) }.formStyle(.grouped))),
        ]
        for sheet in sheets {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: sheet.size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            let hosting = NSHostingView(rootView: sheet.view)
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1_500))
            for theme in themes {
                window.appearance = NSAppearance(named: theme.appearance)
                try? await Task.sleep(for: .milliseconds(400))
                await walkForm(window, bounds: { NSRect(origin: .zero, size: sheet.size) }, label: "the \(sheet.name) sheet, \(theme.name)",
                               drawing: "sheet-\(sheet.name)-\(theme.name)")
            }
            window.close()
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Every field the sweep stacked was drawn and checked somewhere.
        let expected = ["field.agent.name", "field.agent.vendor", "field.agent.purpose", "field.agent.ownKinds", "field.agent.model", "field.agent.budget",
                        "field.agent.domains", "field.agent.command", "field.agent.sshHost", "field.agent.address", "field.agent.token",
                        "field.agent.statusAddress", "field.agent.statusToken", "field.agent.cliModel",
                        "field.automation.name", "field.automation.phrase", "field.automation.command", "field.automation.webhookURL",
                        "field.automation.body", "field.automation.token",
                        "field.teamdb.server", "field.teamdb.database", "field.teamdb.adminLogin", "field.teamdb.adminPassword", "field.teamdb.teamName",
                        "field.teamdb.yourName", "field.teamdb.update.adminLogin", "field.teamdb.update.adminPassword", "field.teamdb.member.name",
                        "field.teamdb.member.login", "field.decision.server",
                        "field.mlx.endpoint", "field.mlx.token", "field.ai.ollamaURL", "field.ai.baseURL", "field.ai.apiKey", "field.writing.sites", "field.team.name", "field.phone.address"]
        let missing = expected.filter { !seen.contains($0) }
        check(missing.isEmpty, "every stacked field was drawn and checked (\(seen.count) of them)" + (missing.isEmpty ? "" : "; not seen: \(missing.joined(separator: ", "))"))
    }

    /// What `view` shows now, scroll views and all, as a PNG in `directory`.
    @MainActor
    static func snapshot(_ view: NSView, name: String, directory: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
