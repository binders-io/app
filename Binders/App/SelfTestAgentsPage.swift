import AppKit
import SwiftData
import SwiftUI
import BindersKit

extension SelfTest {
    /// The Agents page as a place to talk to your agents: who's on the list and in what order (the Manager first, a
    /// local model only there), which cards are an agent's conversations, a message turned into a card meant for it and
    /// handed over, and the page drawn with the Manager, an agent and a conversation picked, in light and dark, inside
    /// the window at its smallest. In a throwaway folder (BINDERS_DATA_DIR) only; no agent or model runs.
    ///
    ///     BINDERS_DATA_DIR=$(mktemp -d) Binders --selftest-agents-page /tmp/agents-page -notesShowMarkdown NO
    @MainActor
    static func agentsPageSelfTest(drawingTo directory: URL) async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards, agents and the Manager's file")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = DictationController()
        let board = controller.board
        let registry = AgentRegistry.shared
        let manager = controller.manager
        let store = Store.shared
        let app = BinderRecord(name: "Binders App", colorIndex: 2)
        let site = BinderRecord(name: "Website", colorIndex: 5)
        store.insert(app)
        store.insert(site)

        // A message as a card.
        check(AgentNote.card(from: "Why does the board clip at 1100 pt?") == ("Why does the board clip at 1100 pt?", ""), "a one-line message is the title")
        let long = AgentNote.card(from: "Look into the board\nIt clips at 1100 pt on my 14-inch screen.")
        check(long.title == "Look into the board" && long.details.hasSuffix("14-inch screen."), "a longer one keeps its first line as the title and all of it as details")
        let wordy = AgentNote.card(from: String(repeating: "word ", count: 40))
        check(wordy.title.count <= AgentNote.titleLimit + 1 && wordy.title.hasSuffix("…") && !wordy.title.contains("wor…"), "a long first line is cut at a word")
        check(AgentsPick(AgentsPick.card(app.id).raw) == .card(app.id) && AgentsPick("other:Grok Bot") == .other("Grok Bot") && AgentsPick("nonsense") == nil,
              "what's picked is kept and read back")

        // Agents: two that take cards, and a local model that's only the Manager.
        let claude = AgentProfile(name: "Claude Code · app", wake: .board)
        let pennant = AgentProfile(name: "Pennant", wake: .board, binders: [site.id])
        let local = AgentProfile(name: "Manager", wake: .localModel(LocalModelWake(model: "qwen3:14b")), manager: true)
        registry.upsert(claude)
        registry.upsert(pennant)
        registry.upsert(local, isManager: true)

        // Conversations: one it's working on with a reply, one waiting for you, one done; one a teammate's session holds.
        let working = board.create(title: "Why does the board clip at 1100 pt?", details: "On my 14-inch screen the last column is cut off.", binderID: app.id, by: .you)
        board.give(working, to: claude.name, by: .you)
        let agent = BoardActor(name: claude.name, kind: .agent)
        try? board.claim(working, by: agent)
        _ = board.comment(working, text: "Looking at BoardColumnsView now. The minimum column width is 260 pt, so six columns need 1,560 pt.", by: agent)
        _ = board.comment(working, text: "Can it fold Done into a narrower strip?", by: .you)
        let review = board.create(title: "Update the download link to 0.11.1", binderID: app.id, by: .you)
        board.give(review, to: claude.name, by: .you)
        try? board.claim(review, by: agent)
        board.report(review, progress: "Changed site/index.html and the help page; ready to check.", by: agent)
        try? board.move(review, to: .review, by: agent)
        let done = board.create(title: "Rename the Distill note wording", binderID: app.id, by: .you)
        board.give(done, to: claude.name, by: .you)
        try? board.claim(done, by: agent)
        try? board.move(done, to: .review, by: agent)
        try? board.move(done, to: .done, by: .you)
        let session = board.create(title: "Tidy the CHANGELOG", binderID: site.id, by: .you)
        try? board.claim(session, by: BoardActor(name: "Codex · site", kind: .agent))
        store.save()

        check(AgentsView.isFor(working, claude.name) && AgentsView.isFor(done, claude.name) && !AgentsView.isFor(working, pennant.name),
              "an agent's conversations are the cards it holds or that you meant for it")
        check(!local.takesCards(from: app.id), "the Manager's local model takes no cards")

        // A message from the page: a card meant for it, in Ready, handed over (Pennant checks the board itself, so
        // nothing starts).
        let parts = AgentNote.card(from: "Draft the launch post for 0.11.1")
        let sent = board.create(title: parts.title, details: parts.details, binderID: site.id, column: .backlog, by: .you)
        let handed = board.give(sent, to: pennant.name, by: .you)
        check(sent.meantFor == pennant.name && sent.column == .ready, "a message becomes a card meant for it, in Ready (\(handed))")
        check(AgentsView.isFor(sent, pennant.name), "and shows as its conversation")

        // The Manager's conversation, answered by a stand-in.
        manager.localPump = {
            let waiting = (try? FileManager.default.contentsOfDirectory(atPath: InboxCommands.directory.path)) ?? []
            for file in waiting where file.hasSuffix(".request.json") {
                await InboxCommands.apply(named: String(file.dropLast(".request.json".count)), controller: controller)
            }
        }
        manager.localModel = { _, _ in
            ScriptedModel { _, _, user in
                user.contains("plate")
                    ? #"{"action":"reply","tool":"","arguments":[],"reply":"Two cards need you: the download link is ready to check, and Claude Code asked whether Done can fold. Pennant has the launch post."}"#
                    : #"{"action":"reply","tool":"","arguments":[],"reply":"Done: nothing in Website needed moving."}"#
            }
        }
        let first = manager.ask("What's on my plate today?", from: .mac)
        let end = Date().addingTimeInterval(60)
        while manager.request(first.id)?.isOver != true, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        let second = manager.tidy(binder: site.id, from: .iphone)
        while manager.request(second.id)?.isOver != true, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        check(manager.request(first.id)?.status == .answered && manager.request(second.id)?.status == .answered, "the Manager answered both")

        // Drawn: the Manager, an agent, a conversation; at the window's smallest and a usual size, light and dark.
        func draw(_ pick: AgentsPick, _ name: String, size: NSSize, dark: Bool) async {
            AgentsView.drawnPick = pick.raw
            let navigation = HubNavigation()
            navigation.binderID = app.id
            navigation.selection = .agents
            let view = HubView().environment(navigation).environment(controller).environment(controller.meetings)
                .environment(controller.knowledge).environment(controller.team).environment(controller.capture)
                .environment(controller.commitments).environment(AppSettings.shared).modelContainer(Store.shared.container)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: view)
            window.contentView = hosting
            window.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(1_800))
            check(window.frame.width <= size.width + 0.5, "\(name): the page fits \(Int(size.width)) pt (\(Int(window.frame.width)))")
            snapshot(hosting, name: name, directory: directory)
            window.close()
        }
        await draw(.manager, "agents-manager", size: NSSize(width: 1280, height: 800), dark: false)
        await draw(.agent(claude.id), "agents-agent", size: NSSize(width: 1280, height: 800), dark: false)
        await draw(.card(working.id), "agents-conversation", size: NSSize(width: 1280, height: 800), dark: false)
        await draw(.card(working.id), "agents-conversation-dark", size: NSSize(width: 1280, height: 800), dark: true)
        await draw(.agent(pennant.id), "agents-agent-smallest", size: HubWindowController.smallestSize, dark: true)
        AgentsView.drawnPick = nil

        print(failures == 0 ? "AGENTS_PAGE_OK" : "AGENTS_PAGE_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}
