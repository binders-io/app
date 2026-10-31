import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// Draws one page of the hub, on the demo data, to a PNG, to look at a change: `--selftest-draw home out.png`, or
    /// `today`, `binder`, `board`, `note` (one open in the binder), `card` (a card opened, at its window's default size),
    /// `card:<state>` and `cards` (the card window's states, `SelfTestCardDrawings`), `meeting` (a meeting's
    /// transcript in the binder; `meeting-sent` once it's been sent to a binder as a note), `ask` (its Ask tab, with a question asked), `knowledge` (the binder's Knowledge, a
    /// person open), `meetings` (the binder's Meetings tab, its Record button), `slash` (a note's slash menu, as it opens on
    /// the binder's pages), `settings:<page>`, `agent-editor` (an agent's sheet). With `--colour <0-7>` the demo binder wears
    /// that binder colour. `settings:ai` takes `--decision-folder <folder>`, a decision model's folder put in as Tev1 0.8B's
    /// (cloned, so it takes no space), and `--decision <choice>`, a decision model chosen as Settings stores it ("off", a
    /// folder's path, a server's address), and is drawn once its folder check has had time to answer. In a throwaway folder
    /// (BINDERS_DATA_DIR) only.
    /// The card's own states: `card:<state>` and `cards` (`drawCards`), with `--size 880x600` for one.
    @MainActor
    static func drawSelfTest(page: String, to url: URL, colour: Int? = nil, size: String? = nil) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this seeds the demo data")
            return 1
        }
        let controller = DictationController()
        guard await DemoData.seed(knowledge: controller.knowledge),
              let harbor = Store.shared.binders().first(where: { $0.name == DemoData.binderName }) else { return 1 }
        if let colour { harbor.colorIndex = colour }
        if page == "cards" || page.hasPrefix("card:") {
            let asked = CardLayout.size(from: size).map { NSSize(width: $0.width, height: $0.height) }
            return await drawCards(page: page, to: url, size: asked, controller: controller, harbor: harbor)
        }
        let navigation = HubNavigation()
        var decisionDrawn = false
        switch page {
        case "today": navigation.selection = .today
        case "binder":
            navigation.binderID = harbor.id
            navigation.selection = .binder
        case "board":
            navigation.binderID = harbor.id
            navigation.pendingBinderTab = .board
            navigation.selection = .binder
        case "note":
            let notes = (try? Store.shared.context.fetch(FetchDescriptor<NoteItem>())) ?? []
            navigation.binderID = harbor.id
            navigation.pendingBinderTab = .notes
            // The same note every time, so pictures compare: the first by title with a digest.
            navigation.pendingNoteID = notes.filter { $0.binderID == harbor.id && !$0.digest.isEmpty }.min { $0.title < $1.title }?.id
            navigation.selection = .binder
        case "knowledge":
            // The first person or topic in the binder, open: its page, its mentions, and the small controls beside them.
            let entities = await controller.knowledge.store.entities(limit: 50, binder: harbor.id.uuidString)
            navigation.binderID = harbor.id
            navigation.pendingBinderTab = .knowledge
            navigation.pendingEntityID = entities.min { $0.name < $1.name }?.id
            navigation.selection = .binder
        case "meetings":
            navigation.binderID = harbor.id
            navigation.pendingBinderTab = .meetings
            navigation.selection = .binder
        case "work": navigation.selection = .work
        case "agents":
            let repository = AppPaths.support.appendingPathComponent("harbor-web", isDirectory: true)
            try? FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
            AgentRegistry.shared.upsert(AgentProfile(name: "Claude Code · harbor-web", wake: .claudeCode(ClaudeCodeWake(repository: repository.path))))
            AgentRegistry.shared.upsert(AgentProfile(name: "Pennant", wake: .board))
            navigation.selection = .agents
        case "settings:agents":
            // Two example agents to show: Claude Code in a repository, and one that checks the board itself.
            let repository = AppPaths.support.appendingPathComponent("harbor-web", isDirectory: true)
            try? FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
            AgentRegistry.shared.upsert(AgentProfile(name: "Claude Code · harbor-web", wake: .claudeCode(ClaudeCodeWake(repository: repository.path)),
                                                     preset: "claude-code"))
            AgentRegistry.shared.upsert(AgentProfile(name: "Pennant", wake: .board))
            navigation.pendingSettingsPage = .agents
            navigation.selection = .settings
        case let settings where settings.hasPrefix("settings:"):
            if settings == "settings:ai" { decisionDrawn = prepareDecisionModel() }
            navigation.pendingSettingsPage = SettingsPage(rawValue: String(settings.dropFirst("settings:".count)))
            navigation.selection = .settings
        default: navigation.selection = .home
        }
        var view = AnyView(HubView().environment(navigation).environment(controller).environment(controller.meetings)
            .environment(controller.knowledge).environment(controller.team).environment(controller.capture)
            .environment(controller.commitments).environment(AppSettings.shared).modelContainer(Store.shared.container)
            .defaultAppStorage(throwawayDefaults))
        // `--height <points>` for a page whose part runs long, such as Settings → AI with its Decision model.
        var size = NSSize(width: 1500, height: drawArgument("--height").flatMap(Double.init) ?? 1000)
        if page == "agent-editor" {
            // An agent that checks the board itself, in its sheet: who it sends cards to and what it's for, as you said.
            let pennant = AgentProfile(name: "Pennant", wake: .board, vendor: "Anthropic, through Pennant",
                                       purpose: "Personal errands: appointments, email, bookings")
            view = AnyView(AgentEditor(agent: pennant, isNew: false).modelContainer(Store.shared.container).defaultAppStorage(throwawayDefaults))
            size = NSSize(width: 600, height: 660)
        }
        if page == "slash" {
            // The menu on its own, as it opens over a note on the binder's pages: its first row selected.
            view = AnyView(SlashMenu.drawn(colour: harbor.colorIndex).padding(24).pageGround().binderTint(harbor.colorIndex))
            size = NSSize(width: 330, height: 370)
        }
        if page == "card" {
            // A blocked card, opened: its controls and its timeline, as the sheet shows them.
            guard let card = controller.board.cards(in: harbor.id).first(where: { $0.column == .blocked }) else { return 1 }
            view = AnyView(CardDetailView(card: card).environment(controller).environment(navigation).modelContainer(Store.shared.container)
                .defaultAppStorage(throwawayDefaults))
            size = NSSize(width: CardLayout.defaultWidth, height: CardLayout.defaultHeight)
        }
        if page == "meeting" || page == "meeting-sent" || page == "ask" {
            // The launch review as the binder's Meetings tab shows it, on its transcript or, with a question asked and
            // answered, on Ask.
            let meetings = (try? Store.shared.context.fetch(FetchDescriptor<MeetingRecord>())) ?? []
            guard let review = meetings.first(where: { $0.title == DemoData.meetingTitle }) else { return 1 }
            if page == "meeting-sent" { MeetingNotes.send(review, to: harbor, transcript: false) }
            if page == "ask" {
                review.chat = [.init(role: "user", text: "What did we decide about the launch date?"),
                               .init(role: "assistant", text: "It stays the **28th**. A slip is decided on Monday, not before.")]
            }
            view = AnyView(MeetingDetailView(meeting: review, onDelete: {}, initialTab: page == "ask" ? .ask : .transcript)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .pageGround()
                .binderTint(harbor.colorIndex)
                .environment(controller).environment(controller.meetings).environment(controller.knowledge).environment(controller.team)
                .environment(navigation).environment(AppSettings.shared).modelContainer(Store.shared.container)
                .defaultAppStorage(throwawayDefaults))
            size = NSSize(width: 1000, height: 700)
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFrontRegardless()
        // A decision model put in or chosen: its folder check, fingerprint or a server's probes answer first.
        try? await Task.sleep(for: .milliseconds(decisionDrawn ? 9000 : 2500))
        let directory = url.deletingLastPathComponent()
        capture(hosting, name: url.deletingPathExtension().lastPathComponent, directory: directory)
        print("DRAWN: \(url.path)")
        return 0
    }
}

extension SelfTest {
    /// For drawing Settings → AI's Decision model: `--decision-folder <folder>` cloned in as Tev1 0.8B's folder, and
    /// `--decision <choice>` chosen as Settings would store it. Whether either was given.
    @MainActor
    static func prepareDecisionModel() -> Bool {
        var given = false
        if let folder = drawArgument("--decision-folder") {
            given = cloneModel(URL(fileURLWithPath: folder, isDirectory: true), to: MLXDecisionBackend.tev1Folder)
            print(given ? "DECISION FOLDER: \(folder) as \(MLXDecisionBackend.tev1FolderName)" : "ERROR: \(folder) couldn't be put in")
        }
        if let stored = drawArgument("--decision") {
            DecisionModels.shared.use(DecisionChoice(stored: stored, appleSilicon: MLXModels.isSupported))
            print("DECISION MODEL: \(DecisionModels.name(DecisionModels.shared.choice))")
            given = true
        }
        return given
    }

    /// The value after `flag` on the command line, if any.
    static func drawArgument(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        return arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
}
