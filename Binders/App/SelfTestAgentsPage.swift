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

        // What the iPhone's Agents screen hears: each agent's binders, and the Manager; never a local model, which takes no cards.
        let listed = (try? await MCPServer.call("list_agents", [:], knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller), actor: .you))
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["agents"] as? [[String: Any]] ?? []
        func entry(_ name: String) -> [String: Any]? { listed.first { $0["name"] as? String == name } }
        check(entry(local.name) == nil && entry(claude.name) != nil, "list_agents leaves out the local-model Manager")
        check(Set(entry(claude.name)?["binders"] as? [String] ?? []) == Set(store.binders().map(\.name)) && entry(pennant.name)?["binders"] as? [String] == [site.name],
              "and says which binders each takes cards from (\(String(describing: entry(pennant.name)?["binders"])))")
        let asAgent = (try? await MCPServer.call("list_agents", [:], knowledge: controller.knowledge, write: MCPServer.writeInApp(controller: controller),
                                                 actor: BoardActor(name: claude.name, kind: .agent)))
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["agents"] as? [[String: Any]] ?? []
        check(asAgent.allSatisfy { $0["binders"] == nil }, "an agent hears names and kinds only")

        // Conversations: one it's working on with a reply, one waiting for you, one done; one a teammate's session holds.
        let working = board.create(title: "Why does the board clip at 1100 pt?", details: "On my 14-inch screen the last column is cut off.", binderID: app.id, by: .you)
        board.give(working, to: claude.name, by: .you)
        let agent = BoardActor(name: claude.name, kind: .agent)
        try? board.claim(working, by: agent)
        _ = board.comment(working, text: "Looking at BoardColumnsView now. The minimum column width is 260 pt, so six columns need 1,560 pt.", by: agent)
        _ = board.comment(working, text: "Can it fold Done into a narrower strip?", by: .you)
        // Its run, live (lane LS1): Binders' log of a Claude Code run, as stream-json, in the throwaway folder's logs.
        let logs = AgentPlaces.logs
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("\(working.id.uuidString.prefix(8).lowercased())-20261028T010000.jsonl")
        let stream = [
            #"{"type":"system","subtype":"init","session_id":"s1"}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"p1","name":"TodoWrite","input":{"todos":[{"content":"Read the board","status":"completed"},{"content":"Narrow Done","activeForm":"Narrowing Done","status":"in_progress"},{"content":"Spacing tokens","status":"pending"},{"content":"Open PR","status":"pending"}]}}]}}"#,
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"text","text":"On it. I'll fold **Done** into a narrow strip and move the column widths to tokens."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/repo/Binders/Board/BoardColumnsView.swift"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"..."}]}}"#,
            #"{"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/repo/Binders/Board/BoardColumnsView.swift","old_string":"a\n.frame(minWidth: 260)\nb","new_string":"a\n.frame(minWidth: column == .done ? 120 : 260)\n.animation(.snappy, value: folded)\nb"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#,
            #"{"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift test --filter BoardTests"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"Executed 24 tests, with 0 failures"}]}}"#,
            #"{"type":"assistant","message":{"id":"m5","content":[{"type":"tool_use","id":"t4","name":"Edit","input":{"file_path":"/repo/Binders/Board/BoardTokens.swift","old_string":".padding(12)","new_string":".padding(Spacing.md)"}}]}}"#,
        ].joined(separator: "\n") + "\n"
        try? Data(stream.utf8).write(to: log)
        board.woke(working, agent: claude.name, text: "Started Claude Code in /repo/.claude/worktrees/binders-x (acceptEdits, ready). To look in: claude --resume 3f2a3c55-1111-4222-8333-944455556666 there.", log: log)
        let workingRun = AgentSessionWatch.run(of: working, timeline: board.timeline(working.id))
        check(workingRun?.log.lastPathComponent == log.lastPathComponent && workingRun?.tool == .claude, "the card's run is found from its wake and its log")
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
        func draw(_ pick: AgentsPick, _ name: String, size: NSSize, dark: Bool, then later: AgentsPick? = nil) async {
            // Picked as a click picks it: in the hub's navigation.
            let navigation = HubNavigation()
            navigation.binderID = app.id
            navigation.selection = .agents
            navigation.agentsPick = pick.raw
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
            if let later {
                // Picking another, as a click does, changes what the page shows.
                func pixels() -> Data? {
                    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    return rep.tiffRepresentation
                }
                let before = pixels()
                navigation.agentsPick = later.raw
                try? await Task.sleep(for: .milliseconds(1_200))
                check(before != nil && pixels() != before, "\(name): picking another shows it")
                snapshot(hosting, name: name + "-then", directory: directory)
            }
            window.close()
        }
        // A chat with an agent that checks the board itself, answered in Markdown (lane AC1).
        var chatID: UUID?
        if case .success(let chat) = controller.chats.send("What's waiting on me today?", to: claude.name, via: "mac") {
            chatID = chat.id
            _ = controller.chats.reply("""
                Two things wait on you:

                **Waiting on you**
                • *Update the download link to 0.11.1*: ready in Review, check `site/index.html`.
                • *Why does the board clip at 1100 pt?*: I asked whether Done can fold.

                1. Check the download link
                2. Answer about Done

                ```
                open site/index.html
                ```
                """, chat: chat.id, by: claude.name)
            _ = controller.chats.send("Fold Done into a narrow strip.", to: claude.name, chat: chat.id, via: "iphone")
        }
        check(chatID.flatMap { controller.chats.chat($0) }?.status == .waiting, "a chat with it waits for it to check the board")
        await draw(.manager, "agents-manager", size: NSSize(width: 1280, height: 800), dark: false, then: .agent(claude.id))
        if let chatID {
            await draw(.chat(chatID), "agents-chat", size: NSSize(width: 1280, height: 800), dark: false)
            await draw(.chat(chatID), "agents-chat-dark", size: HubWindowController.smallestSize, dark: true)
        }
        await draw(.agent(claude.id), "agents-agent", size: NSSize(width: 1280, height: 800), dark: false)
        await draw(.card(working.id), "agents-conversation", size: NSSize(width: 1280, height: 800), dark: false)
        await draw(.card(working.id), "agents-conversation-dark", size: NSSize(width: 1280, height: 800), dark: true)
        await draw(.agent(pennant.id), "agents-agent-smallest", size: HubWindowController.smallestSize, dark: true)

        print(failures == 0 ? "AGENTS_PAGE_OK" : "AGENTS_PAGE_FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }
}
