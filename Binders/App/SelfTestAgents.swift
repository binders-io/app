import Foundation
import BindersKit

extension SelfTest {
    /// An agent Binders wakes with a command, through the same tools agents and the phone use: woken when you make a card
    /// ready for it, answer it or send its work back (and when you comment on a card it holds in progress, which
    /// `--selftest-agent-comments` checks), never by an agent or by anything not yours, capped per hour, and with a receipt
    /// on the card; and one that may not act for you drafts first and asks your approval
    /// (`agentApprovalChecks`). In a throwaway folder (BINDERS_DATA_DIR) only.
    @MainActor
    static func agentsSelfTest() async -> Int32 {
        guard AppPaths.isDemo else {
            print("ERROR: set BINDERS_DATA_DIR to an empty folder; this test writes cards and agents")
            return 1
        }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let controller = DictationController()
        let board = controller.board
        let dispatcher = controller.agents
        let registry = AgentRegistry.shared
        let write = MCPServer.writeInApp(controller: controller)
        let echoActor = BoardActor(name: "Echo", kind: .agent), other = BoardActor(name: "Helper", kind: .agent)
        func call(_ tool: String, _ arguments: [String: Any], as actor: BoardActor) async -> (ok: Bool, text: String) {
            do { return (true, try await MCPServer.call(tool, arguments, knowledge: controller.knowledge, write: write, actor: actor)) }
            catch { return (false, (error as? MCPCore.ToolFailure)?.message ?? error.localizedDescription) }
        }
        func id(_ text: String) -> String { ((try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["id"] as? String) ?? "" }

        Store.shared.insert(BinderRecord(name: "Launch", colorIndex: 2))
        let folder = AppPaths.support
        let heard = folder.appendingPathComponent("echo.txt")
        try? FileManager.default.removeItem(at: heard)
        func wakes() -> [String] { ((try? String(contentsOf: heard, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("WAKE ") }.map(String.init) }
        func waitForWakes(_ count: Int) async {
            for _ in 0..<60 where wakes().count < count { try? await Task.sleep(for: .milliseconds(100)) }
        }

        // The card arrives as BINDERS_* variables and as JSON on standard input; the command is the agent's own words.
        let command = #"printf 'WAKE %s %s %s\n' "$BINDERS_EVENT" "$BINDERS_CARD" "$BINDERS_TITLE" >> echo.txt; cat >> echo.txt; printf '\n' >> echo.txt"#
        let echo = AgentProfile(name: "Echo", wake: .command(command: command, folder: folder.path), wakesPerHour: 6)
        check(registry.upsert(echo) == nil, "an agent is saved")
        check(registry.upsert(AgentProfile(name: "You", wake: .board)) != nil, "an agent can't go by your name")
        check(registry.upsert(AgentProfile(name: "Rogue", wake: .command(command: "claude -p --permission-mode bypassPermissions"))) != nil,
              "nor run with its permission checks off")
        let file = (try? String(contentsOf: folder.appendingPathComponent("agents.json"), encoding: .utf8)) ?? ""
        check(file.contains("\"Echo\"") && !registry.changedOutside.contains(echo.id), "agents.json has it, approved as saved")

        // a) You make a card ready for it: one wake, with the card.
        let first = id((await call("create_task", ["title": "Draft the release notes", "binder": "Launch", "column": "ready", "for": "Echo"], as: .you)).text)
        await waitForWakes(1)
        for _ in 0..<30 where !contents(heard).contains("\"card\":\"\(first)\"") { try? await Task.sleep(for: .milliseconds(100)) }
        let firstLog = contents(heard)
        check(wakes() == ["WAKE ready \(first) Draft the release notes"], "a card you made ready for it wakes it once: \(wakes())")
        check(firstLog.contains("\"title\":\"Draft the release notes\"") && firstLog.contains("\"card\":\"\(first)\""), "with the card as JSON on its input")
        let receipt = board.timeline(UUID(uuidString: first)!).last { $0.kind == .woke }
        check(receipt?.author == "Echo" && receipt?.text.contains("Woke Echo") == true, "the card says it was woken: \(receipt?.text ?? "none")")
        check(board.card(UUID(uuidString: first)!)?.links.contains { $0.hasPrefix("file://") && $0.contains("Logs/Binders/Agents") } == true,
              "and links what its run wrote")

        // b) A title is data, never a command.
        let sneaky = id((await call("create_task", ["title": "$(touch pwned)", "binder": "Launch", "column": "ready", "for": "Echo"], as: .you)).text)
        await waitForWakes(2)
        check(wakes().last == "WAKE ready \(sneaky) $(touch pwned)" && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("pwned").path),
              "a title that looks like a command arrives as words, and nothing runs")

        // c) An agent's choice is a suggestion: nothing wakes until you confirm it.
        let suggested = id((await call("create_task", ["title": "Check the screenshots", "binder": "Launch", "column": "ready", "for": "Echo"], as: other)).text)
        try? await Task.sleep(for: .milliseconds(2600))
        check(wakes().count == 2, "a card an agent meant for Echo wakes nothing")
        _ = await call("update_task", ["id": suggested, "for": "Echo"], as: .you)
        await waitForWakes(3)
        check(wakes().count == 3 && wakes().last?.contains(suggested) == true, "until you give it to Echo yourself")

        // d) Its own moves wake nothing.
        _ = await call("claim_task", ["id": first], as: echoActor)
        _ = await call("release_task", ["id": first, "note": "Not now"], as: echoActor)
        try? await Task.sleep(for: .milliseconds(2600))
        check(wakes().count == 3, "its own claim and release wake nothing")

        // e) Your answer to its question wakes it.
        _ = await call("claim_task", ["id": suggested], as: echoActor)
        _ = await call("ask_on_task", ["id": suggested, "question": "Light or dark screenshots?"], as: echoActor)
        _ = await call("comment_task", ["id": suggested, "text": "Dark, please."], as: .you)
        await waitForWakes(4)
        check(wakes().last == "WAKE answered \(suggested) Check the screenshots", "your answer wakes it: \(wakes().last ?? "")")
        // Its command writes the wake line first, then the card from its input: wait for that too.
        for _ in 0..<30 where !contents(heard).contains("\"answer\":\"Dark, please.\"") { try? await Task.sleep(for: .milliseconds(100)) }
        check(contents(heard).contains("\"answer\":\"Dark, please.\""), "with your answer")

        // f) Sending its work back wakes it.
        _ = await call("complete_task", ["id": suggested, "summary": "Done, dark ones"], as: echoActor)
        _ = await call("update_task", ["id": suggested, "column": "in_progress"], as: .you)
        await waitForWakes(5)
        check(wakes().last == "WAKE sent_back \(suggested) Check the screenshots", "sending it back wakes it: \(wakes().last ?? "")")

        // g) At most six an hour, unless you tap Wake Now.
        let sixth = id((await call("create_task", ["title": "Update the FAQ", "binder": "Launch", "column": "ready", "for": "Echo"], as: .you)).text)
        await waitForWakes(6)
        let seventh = id((await call("create_task", ["title": "Tidy the changelog", "binder": "Launch", "column": "ready", "for": "Echo"], as: .you)).text)
        try? await Task.sleep(for: .milliseconds(2600))
        check(wakes().count == 6 && wakes().last?.contains(sixth) == true, "a seventh wake in the hour waits")
        check(dispatcher.outcomes[UUID(uuidString: seventh)!]?.message.contains("6 times in the last hour") == true, "and the card says why")
        check(board.card(UUID(uuidString: seventh)!).map { dispatcher.wakeNow($0) == nil } == true, "Wake Now goes past it")
        await waitForWakes(7)
        check(wakes().count == 7 && wakes().last?.contains(seventh) == true, "and wakes it")

        // h) A request file that names you still acts as an agent.
        let mine = id((await call("create_task", ["title": "Book the venue", "binder": "Launch", "column": "ready"], as: .you)).text)
        _ = await call("claim_task", ["id": mine], as: .you)
        let forged = InboxCommands.fromAgent(InboxRequest(action: "update_task", fields: ["id": mine, "column": "done", "actor": "You", "actor_kind": "person"]))
        let forgedResult = await InboxCommands.perform(forged, controller: controller)
        check(!forgedResult.ok && board.card(UUID(uuidString: mine)!)?.column == .inProgress, "an inbox request that says it's you acts as an agent: \(forgedResult.error ?? "")")

        // i) Paused: nothing wakes, and agents can't take cards.
        registry.setPaused(true)
        let whilePaused = id((await call("create_task", ["title": "Write the welcome email", "binder": "Launch", "column": "ready", "for": "Echo"], as: .you)).text)
        try? await Task.sleep(for: .milliseconds(2600))
        let refused = await call("claim_task", ["id": whilePaused], as: other)
        check(wakes().count == 7 && !refused.ok && refused.text.contains("paused"), "paused, nothing wakes and agents can't take cards: \(refused.text)")
        registry.setPaused(false)

        // j) Changed outside Binders: nothing runs until it's saved here again.
        let path = folder.appendingPathComponent("agents.json")
        let edited = ((try? String(contentsOf: path, encoding: .utf8)) ?? "").replacingOccurrences(of: "WAKE", with: "OWNED")
        try? edited.write(to: path, atomically: true, encoding: .utf8)
        registry.load()
        check(registry.changedOutside.contains(echo.id), "a command changed outside Binders is noticed")
        _ = await call("create_task", ["title": "Plan the launch party", "binder": "Launch", "column": "ready", "for": "Echo"], as: .you)
        try? await Task.sleep(for: .milliseconds(2600))
        check(wakes().count == 7 && !contents(heard).contains("OWNED"), "and doesn't run")

        // k) A run Binders starts gets the board's tools alone.
        setenv("BINDERS_TOOLS", "board", 1)
        let offered = Set(MCPServer.offered.map(\.name))
        check(offered == MCPServer.boardTools.subtracting([PullRequests.tool]), "a woken run gets the board's tools and nothing that reads your binders: \(offered.count)")
        // l) ... for its own card alone, as exactly the agent it woke.
        let own = id((await call("create_task", ["title": "Tidy the changelog", "binder": "Launch", "column": "ready"], as: .you)).text)
        let theirs = id((await call("create_task", ["title": "Plan the offsite", "binder": "Launch", "column": "ready"], as: .you)).text)
        setenv("BINDERS_CARD", own, 1)
        setenv("BINDERS_AGENT", "Echo", 1)
        let listed = await call("list_tasks", [:], as: echoActor)
        check(listed.text.contains(own) && !listed.text.contains(theirs), "a woken run sees only its own card")
        let peeked = await call("get_task", ["id": theirs], as: echoActor), taken = await call("claim_task", ["id": theirs], as: echoActor)
        check(!peeked.ok && !taken.ok, "and can't read or take another")
        let made = await call("create_task", ["title": "More work"], as: echoActor)
        check(!made.ok && !Set(MCPServer.offered.map(\.name)).contains("create_task"), "nor make new cards")
        let claimed = await call("claim_task", ["id": own, "agent": "Someone Else"], as: echoActor)
        let holder = board.card(UUID(uuidString: own)!)?.assignee ?? "nobody"
        check(claimed.ok && holder == "Echo", "it acts as the agent it woke, whatever it calls itself: \(holder)")
        unsetenv("BINDERS_CARD")
        unsetenv("BINDERS_AGENT")
        unsetenv("BINDERS_TOOLS")

        // m) Names: a card's "for" wakes only the agent with that very name; an agent can't take a tool's own name.
        let site = AgentProfile(name: "Echo Site", wake: .command(command: command, folder: folder.path))
        check(registry.upsert(site) == nil && registry.agent(named: "echo site")?.id == site.id && registry.agent(named: "Echo")?.id == echo.id,
              "each agent by its own name")
        check(registry.agent(named: "Ech") == nil && registry.agent(named: "Echo Site Two") == nil, "never by part of a name, or a longer one")
        registry.remove(site.id)
        check(registry.upsert(AgentProfile(name: "claude code", wake: .board)) != nil, "an agent can't go by Claude Code's own name")
        let repository = AppPaths.support.appendingPathComponent("fake-repo")
        try? FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let refusal = registry.upsert(AgentProfile(name: "Claude Code · fake", wake: .claudeCode(ClaudeCodeWake(repository: repository.path, executable: "/bin/sh"))))
        check(refusal?.contains("claude program") == true, "and a Claude Code agent runs claude itself, nothing in its place: \(refusal ?? "saved")")
        // A folder that isn't a git repository (a workspace holding several): refused for worktrees, taken in the folder itself.
        let plain = AppPaths.support.appendingPathComponent("plain-workspace")
        try? FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let inWorktree = registry.upsert(AgentProfile(name: "Claude Code · plain", wake: .claudeCode(ClaudeCodeWake(repository: plain.path))))
        check(inWorktree?.contains("Work in the Folder Itself") == true, "a folder with no repository is refused for worktrees, saying what to turn on: \(inWorktree ?? "saved")")
        let inFolder = AgentProfile(name: "Claude Code · plain", wake: .claudeCode(ClaudeCodeWake(repository: plain.path, inFolder: true)))
        let takenInFolder = registry.upsert(inFolder)
        check(takenInFolder == nil, "and taken to work in the folder itself: \(takenInFolder ?? "saved")")
        registry.remove(inFolder.id)

        // n) Agents that could act in the world draft first: request_approval, your decision on it, and its receipt.
        failures += await agentApprovalChecks(controller: controller)

        registry.remove(echo.id)
        print(failures == 0 ? "AGENTS_OK" : "AGENTS_FAILED: \(failures)")
        return failures == 0 ? 0 : 1
    }

    private static func contents(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}
