import XCTest
@testable import BindersKit

final class ManagerTests: XCTestCase {
    func testAManagerRunGetsItsRequestOrNothing() {
        let request = UUID()
        let run = ["BINDERS_RUN": "1", "BINDERS_TOOLS": "board", "BINDERS_AGENT": "Claude Code · manager",
                   "BINDERS_CARD": request.uuidString, "BINDERS_MANAGER": request.uuidString]
        XCTAssertEqual(MCPConfinement.read(run), .manager(request: request))
        XCTAssertEqual(MCPConfinement.read(run).managerRequest, request)
        XCTAssertNil(MCPConfinement.read(run).card, "no card of its own")
        XCTAssertFalse(MCPConfinement.read(run).boardOnly, "it reads the binders")
        XCTAssertTrue(MCPConfinement.read(run).pinsAgent)
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_CARD": UUID().uuidString]) { _, new in new }), .nothing, "card and request must match")
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_MANAGER": "not-a-request"]) { _, new in new }), .nothing)
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_AGENT": "You"]) { _, new in new }), .nothing)
        XCTAssertEqual(MCPConfinement.read(run.merging(["BINDERS_AGENT": " "]) { _, new in new }), .nothing)
        var noRun = run
        noRun["BINDERS_RUN"] = nil
        XCTAssertEqual(MCPConfinement.read(noRun), .board(card: request), "only a run Binders started is the Manager")
        XCTAssertFalse(MCPConfinement.everything.pinsAgent)
    }

    func testItManagesTheBindersButWorksNoCard() {
        let offered = ManagerTools.offered
        // An agent's own work on a card, and what reads beyond the binders, stay out.
        for tool in ["correct_knowledge", "add_to_calendar", "claim_task", "complete_task", "release_task", "request_approval", "ask_on_task",
                     "ask_knowledge", "recent_dictations", "list_messages", "reply_message"] {
            XCTAssertFalse(offered.contains(tool), tool)
        }
        XCTAssertTrue(offered.isSuperset(of: ["get_request", "reply", "edit_task", "close_task", "merge_tasks", "move_task", "assign_task", "delete_task",
                                              "list_proposals", "review_proposals", "update_note", "add_note", "delete_note", "create_binder",
                                              "edit_binder", "propose_note_edit", "move_item"]))
        XCTAssertTrue(ManagerTools.writes.isDisjoint(with: ManagerTools.own))
    }

    func testTheLaunchUsesBindersToolsAlone() throws {
        let request = UUID(), session = UUID()
        let wake = ClaudeCodeWake(repository: "/Users/me/code/app", permissionMode: "auto", model: "sonnet", maxBudgetUSD: 0.5)
        let launch = ManagerLaunch.make(request: request, boardName: "Claude Code · manager", wake: wake, binders: "/Applications/Binders.app/Contents/MacOS/Binders",
                                        dataFolder: "/Users/me/Library/Application Support/Binders", home: "/Users/me", session: session,
                                        directory: "/tmp/binders-manager")
        let args = launch.arguments
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(args[args.firstIndex(of: "--permission-mode")! + 1], "dontAsk", "never the agent's auto mode: it asks nothing and gets only what's allowed")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertEqual(args[args.firstIndex(of: "--allowedTools")! + 1], "mcp__binders_manager", "its own server's name, never one of yours")
        for tool in ["Bash", "Read", "Edit", "Write", "WebFetch", "WebSearch"] { XCTAssertTrue(args.contains(tool), tool) }
        XCTAssertFalse(args.contains("--worktree"))
        XCTAssertEqual(args[args.firstIndex(of: "--model")! + 1], "sonnet")
        XCTAssertEqual(args[args.firstIndex(of: "--max-budget-usd")! + 1], "0.50")
        XCTAssertEqual(launch.directory, "/tmp/binders-manager")
        XCTAssertTrue(launch.prompt.hasPrefix(ManagerPrompt.marker))
        XCTAssertTrue(launch.prompt.contains(request.uuidString))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[args.firstIndex(of: "--mcp-config")! + 1].utf8)) as? [String: Any])
        let env = try XCTUnwrap((((config["mcpServers"] as? [String: Any])?[ManagerLaunch.server]) as? [String: Any])?["env"] as? [String: String])
        XCTAssertEqual(MCPConfinement.read(env), .manager(request: request), "its server is the Manager's for this request")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[args.firstIndex(of: "--settings")! + 1].utf8)) as? [String: Any])
        let network = (((settings["sandbox"] as? [String: Any])?["network"]) as? [String: Any])?["allowedDomains"] as? [String]
        XCTAssertEqual(network, [], "no web")
        XCTAssertNil(settings["hooks"], "no card to report on")
        XCTAssertNil(AgentPrompts.worthKeeping(launch.prompt), "writing capture leaves it out")
    }

    func testUnderAManagedClaudeCodeAHookKeepsItToTheManagersTools() throws {
        let wake = ClaudeCodeWake(repository: "/Users/me/code/app", permissionMode: "auto")
        let launch = ManagerLaunch.make(request: UUID(), boardName: "Claude Code", wake: wake, binders: "/Applications/Binders.app/Contents/MacOS/Binders",
                                        dataFolder: "/Users/me/Library/Application Support/Binders", home: "/Users/me", session: UUID(),
                                        directory: "/tmp/binders-manager", strictMCP: false)
        let args = launch.arguments
        XCTAssertFalse(args.contains("--strict-mcp-config"), "a managed Claude Code refuses it")
        XCTAssertEqual(args[args.firstIndex(of: "--allowedTools")! + 1], "mcp__binders_manager")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(args[args.firstIndex(of: "--settings")! + 1].utf8)) as? [String: Any])
        let pre = try XCTUnwrap(((settings["hooks"] as? [String: Any])?["PreToolUse"]) as? [[String: Any]])
        XCTAssertEqual(pre.first?["matcher"] as? String, "mcp__.*")
        let command = try XCTUnwrap(((pre.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
        XCTAssertTrue(command.hasSuffix("--agent-hook \(ClaudeCodeToolGuard.managerHook)"), command)

        func asking(_ tool: String) -> Data { Data(#"{"tool_name":"\#(tool)"}"#.utf8) }
        XCTAssertNil(ClaudeCodeToolGuard.managerRefusal(asking("mcp__binders_manager__reply")))
        XCTAssertNil(ClaudeCodeToolGuard.managerRefusal(asking("mcp__binders_manager__edit_task")))
        XCTAssertNotNil(ClaudeCodeToolGuard.managerRefusal(asking("mcp__binders_manager__claim_task")), "not one of the Manager's")
        XCTAssertNotNil(ClaudeCodeToolGuard.managerRefusal(asking("mcp__binders__edit_task")), "nor a server of yours named binders, unconfined")
        XCTAssertNotNil(ClaudeCodeToolGuard.managerRefusal(asking("mcp__github__create_issue")), "not another server's")
        XCTAssertNotNil(ClaudeCodeToolGuard.managerRefusal(Data("nonsense".utf8)))
        XCTAssertNotNil(ClaudeCodeToolGuard.refusal(asking("mcp__binders__edit_task")), "a card run's hook stays as it was")
    }

    func testAPassageEditAppliesWhileItsThereOnce() {
        let note = "# Plan\n\nShip the thing on Friday.\n"
        let edit = NoteEditSuggestion(note: UUID(), noteTitle: "Plan", request: nil, agent: "M", why: "Clearer",
                                      find: "Ship the thing", replace: "Ship 0.12", base: NoteEditSuggestion.fingerprint(note))
        XCTAssertEqual(edit.applied(to: note), .success("# Plan\n\nShip 0.12 on Friday.\n"))
        XCTAssertEqual(edit.applied(to: note + "\nMore later.\n"), .success("# Plan\n\nShip 0.12 on Friday.\n\nMore later.\n"), "other changes don't matter")
        XCTAssertEqual(edit.applied(to: "# Plan\n\nShip it.\n"), .failure(.changed))
        XCTAssertEqual(edit.applied(to: note + "Ship the thing again.\n"), .failure(.changed), "twice is ambiguous")
        let whole = NoteEditSuggestion(note: UUID(), noteTitle: "Plan", request: nil, agent: "M", why: "Tidier", text: "# Plan\n\n- Ship\n",
                                       base: NoteEditSuggestion.fingerprint(note))
        XCTAssertEqual(whole.applied(to: note), .success("# Plan\n\n- Ship\n"))
        XCTAssertEqual(whole.applied(to: note + "x"), .failure(.changed), "the whole text only for the note it was for")
        let same = NoteEditSuggestion(note: UUID(), noteTitle: "Plan", request: nil, agent: "M", why: "", text: note, base: NoteEditSuggestion.fingerprint(note))
        XCTAssertEqual(same.applied(to: note), .failure(.nothing))
    }

    func testTheFileKeepsWhatItCantRead() throws {
        let request = ManagerRequest(kind: .tidy, text: ManagerRequest.tidyText(binder: "Personal"), from: .mac,
                                     changes: [ManagerChange(kind: .closedCard, id: UUID(), line: "Closed", before: "backlog"),
                                               ManagerChange(kind: .suggestedEdit, id: UUID(), line: "Suggested")])
        XCTAssertEqual(request.thread, request.id)
        XCTAssertEqual(request.undoable.map(\.kind), [.closedCard], "a suggestion waits for you anyway")
        var undone = request
        undone.undoneAt = Date()
        XCTAssertTrue(undone.undoable.isEmpty)
        let data = try JSONEncoder().encode(ManagerFile(requests: [request]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["requests"] = (object["requests"] as? [Any] ?? []) + [["id": "broken"]]
        let read = try JSONDecoder().decode(ManagerFile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(read.requests, [request], "one it can't read is skipped, not the file")
        let later = Data(#"{"kind":"somethingNew","id":"\#(UUID().uuidString)","line":"x"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ManagerChange.self, from: later).kind.undoable, false)
    }

    func testTrimKeepsTheNewest() {
        var file = ManagerFile(requests: (0..<(ManagerFile.keep + 5)).map { ManagerRequest(kind: .ask, text: "\($0)", from: .iphone) })
        let oldest = file.requests[0].id
        file.suggestions = [NoteEditSuggestion(note: UUID(), noteTitle: "", request: oldest, agent: "M", why: "", text: "x", base: "", status: .dismissed),
                            NoteEditSuggestion(note: UUID(), noteTitle: "", request: oldest, agent: "M", why: "", text: "x", base: "")]
        file.trim()
        XCTAssertEqual(file.requests.count, ManagerFile.keep)
        XCTAssertEqual(file.requests.first?.text, "5")
        XCTAssertEqual(file.suggestions.map(\.status), [.waiting], "one still waiting stays")
    }

    func testTheSchedule() {
        let now = Date()
        XCTAssertFalse(ManagerSchedule.off.isDue(last: nil, now: now))
        XCTAssertTrue(ManagerSchedule.daily.isDue(last: nil, now: now))
        XCTAssertFalse(ManagerSchedule.daily.isDue(last: now.addingTimeInterval(-3_600), now: now))
        XCTAssertTrue(ManagerSchedule.daily.isDue(last: now.addingTimeInterval(-86_400), now: now))
        XCTAssertFalse(ManagerSchedule.weekly.isDue(last: now.addingTimeInterval(-86_400), now: now))
    }
}
