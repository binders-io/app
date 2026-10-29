import XCTest
@testable import BindersKit

final class AgentTerminalTests: XCTestCase {
    /// A run you sent words into: its prompt and your message echoed back, each turn ended with its own result.
    private let live = """
    {"type":"system","subtype":"init","session_id":"s1"}
    {"type":"user","message":{"role":"user","content":"Binders woke you for one card.\\nCard: 1234\\nThe user made it ready for you.\\n\\n1. Read the card"},"uuid":"u1","isReplay":true}
    {"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"On it."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}
    {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"line 1\\nline 2\\nline 3"}]}}
    {"type":"result","subtype":"success","is_error":false,"result":"Tests pass.","duration_ms":192000,"total_cost_usd":0.4213,"num_turns":4}
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"Now fold Done into a strip."}]},"uuid":"u2"}
    {"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/r/a/b/Board.swift","old_string":"x\\n.frame(minWidth: 260)","new_string":"x\\n.frame(minWidth: 120)"}}]}}
    {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}
    {"type":"result","subtype":"success","is_error":false,"result":"Folded.","duration_ms":12000}
    """

    func testYourWordsAndEachTurnsEnd() {
        var reader = AgentSessionReader(tool: .claude)
        reader.feed(text: live)
        let asked = reader.events.compactMap { if case .asked(let text) = $0.kind { text } else { nil } }
        XCTAssertEqual(asked.count, 2, "the prompt and your message, never a tool's result")
        XCTAssertEqual(asked.last, "Now fold Done into a strip.")
        let ends = reader.events.filter { if case .ended = $0.kind { true } else { false } }.map(\.id)
        XCTAssertEqual(ends, ["end", "end-2"])
        XCTAssertEqual(reader.stats["end"], AgentSessionStats(seconds: 192, cost: 0.4213, turns: 4))
        XCTAssertTrue(reader.ended)
        reader.feed(#"{"type":"user","message":{"role":"user","content":"And the tokens."},"uuid":"u3"}"#)
        XCTAssertFalse(reader.ended, "a run that carries on after a turn hasn't ended")
    }

    func testTheTerminalsLines() {
        var reader = AgentSessionReader(tool: .claude, output: AgentTerminal.outputKept, diff: AgentTerminal.diffKept)
        reader.feed(text: live)
        let blocks = AgentTerminal.blocks([AgentTerminal.Run(events: reader.events, stats: reader.stats)],
                                          waiting: [(text: "Also the README", why: "Goes when the run ends")])
        guard case .run(let started) = blocks.first?.kind else { return XCTFail("a run's start") }
        XCTAssertEqual(started, "Started")
        guard case .binders(let summary, _) = blocks[1].kind else { return XCTFail("Binders' prompt, in a line") }
        XCTAssertEqual(summary, "Binders woke it for the card. The user made it ready for you.")
        XCTAssertEqual(blocks[2].kind, .said("On it."))
        guard case .tool(let bash) = blocks[3].kind else { return XCTFail("a command") }
        XCTAssertEqual(bash.name, "Bash")
        XCTAssertEqual(bash.argument, "npm test")
        XCTAssertEqual(bash.output, ["line 1", "line 2", "line 3"])
        XCTAssertEqual(blocks[4].kind, .end(ok: true, line: "Done in 3m 12s · $0.42"))
        XCTAssertEqual(blocks[5].kind, .you("Now fold Done into a strip."))
        guard case .tool(let edit) = blocks[6].kind else { return XCTFail("an edit") }
        XCTAssertEqual(edit.name, "Update")
        XCTAssertEqual(edit.argument, "a/b/Board.swift")
        XCTAssertEqual(edit.summary, "Updated a/b/Board.swift with 1 addition and 1 removal")
        XCTAssertEqual(edit.diff, ["- .frame(minWidth: 260)", "+ .frame(minWidth: 120)"])
        XCTAssertEqual(blocks[7].kind, .end(ok: true, line: "Done in 12s"))
        XCTAssertEqual(blocks.last?.kind, .waiting("Also the README", why: "Goes when the run ends"))
    }

    func testARunWithoutEchoesShowsWhatReachedIt() {
        var reader = AgentSessionReader(tool: .codex)
        reader.feed(#"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Fixed it."}}"#)
        reader.feed(#"{"type":"turn.failed","error":{"message":"rate limited"}}"#)
        let blocks = AgentTerminal.blocks([AgentTerminal.Run(events: [], yours: ["first"]),
                                           AgentTerminal.Run(events: reader.events, yours: ["Try the other link"])])
        XCTAssertEqual(blocks.map(\.kind), [.run("Started"), .you("first"), .run("Carried on"), .you("Try the other link"), .said("Fixed it."),
                                            .end(ok: false, line: "Stopped: rate limited")])
    }

    func testToolsInClaudeCodesWords() {
        let read = AgentTerminal.tool(AgentSessionStep(kind: .read, name: "Read", subject: "Hub/View.swift", status: .ok, output: "1\n2\n3"))
        XCTAssertEqual(read.summary, "Read 3 lines")
        XCTAssertTrue(read.output.isEmpty)
        let failed = AgentTerminal.tool(AgentSessionStep(kind: .command, name: "shell", subject: "go test", status: .failed, output: "FAIL x"))
        XCTAssertEqual(failed.name, "Bash")
        XCTAssertEqual(failed.output, ["FAIL x"])
        XCTAssertEqual(AgentTerminal.name(AgentSessionStep(kind: .board, name: "mcp__binders__report_progress", subject: "report progress")), "binders")
        let many = (1...50).map(String.init)
        let folded = AgentTerminal.fold(many)
        XCTAssertEqual(folded.shown.count, AgentTerminal.foldAfter)
        XCTAssertEqual(folded.hidden, 30)
        XCTAssertEqual(AgentTerminal.fold(Array(many.prefix(21))).hidden, 0, "one line more isn't worth folding")
        XCTAssertEqual(AgentTerminal.duration(3_840), "1h 4m")
    }

    func testAChatsFirstPromptShowsYourWords() {
        let prompt = AgentChatPrompt.first(agent: "Claude Code", text: "What's left on the release?", draftsFirst: true)
        var reader = AgentSessionReader(tool: .claude)
        reader.feed(Substring(String(ClaudeCodeLiveInput.message(prompt).dropLast())))
        XCTAssertEqual(AgentTerminal.blocks([AgentTerminal.Run(events: reader.events)]).last?.kind, .you("What's left on the release?"))
    }

    func testLiveInput() {
        let launch = ClaudeCodeLaunch(arguments: ["-p", "--output-format", "stream-json", "--verbose", "--strict-mcp-config"], directory: "/r", prompt: "Go")
        let taking = ClaudeCodeLiveInput.taking(launch)
        XCTAssertEqual(taking.arguments, ["-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--replay-user-messages",
                                          "--strict-mcp-config"])
        XCTAssertEqual(ClaudeCodeLiveInput.taking(taking).arguments, taking.arguments, "once")
        let line = ClaudeCodeLiveInput.message("Say \"hi\"\nthen stop")
        XCTAssertTrue(line.hasSuffix("\n") && line.dropLast().contains("\n") == false, "one line")
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "user")
        XCTAssertEqual((object?["message"] as? [String: Any])?["content"] as? String, "Say \"hi\"\nthen stop")
        XCTAssertEqual(ClaudeCodeLiveInput.answer(in: #"{"type":"result","is_error":false,"result":" Folded. "}"#), .init(text: "Folded.", error: false))
        XCTAssertNil(ClaudeCodeLiveInput.answer(in: #"{"type":"assistant","message":{"content":[{"type":"text","text":"the result"}]}}"#))
        XCTAssertTrue(ClaudeCodeLiveInput.closes(sent: 2, answered: 2))
        XCTAssertFalse(ClaudeCodeLiveInput.closes(sent: 2, answered: 1))
        XCTAssertFalse(ClaudeCodeLiveInput.closes(sent: 0, answered: 0))
    }

    func testLookingInFromTerminal() {
        let receipt = "Carried on its session. Started Claude Code in /Users/sam/code/app/.claude/worktrees/binders-1a2b3c4d (acceptEdits, you commented). To look in: claude --resume 3f2a3c55-1111-4222-8333-944455556666 there."
        XCTAssertEqual(AgentLookIn.claudeFolder(inReceipt: receipt), "/Users/sam/code/app/.claude/worktrees/binders-1a2b3c4d")
        XCTAssertEqual(AgentLookIn.claudeFolder(inReceipt: "Started Claude Code in /r/app, the folder itself (plan, Wake Now)."), "/r/app")
        XCTAssertNil(AgentLookIn.claudeFolder(inReceipt: "Started Claude Code in somewhere (plan)."))
        XCTAssertEqual(AgentLookIn.claude(executable: nil, session: "3F2A3C55-1111-4222-8333-944455556666"), "claude --resume 3f2a3c55-1111-4222-8333-944455556666")
        XCTAssertEqual(AgentLookIn.claude(executable: "/Applications/My Tools/claude", session: "3f2a3c55-1111-4222-8333-944455556666"),
                       "'/Applications/My Tools/claude' --resume 3f2a3c55-1111-4222-8333-944455556666")
        XCTAssertNil(AgentLookIn.claude(executable: nil, session: "x; rm -rf ~"))
        let codex = "Committed Codex's changes on binders/x: abc, 1 file. To look in, with your own Codex settings: codex resume 3f2a3c55-1111-4222-8333-944455556666 -C ~/'code/my app'"
        XCTAssertEqual(AgentLookIn.cli(.codex, inLine: codex), "codex resume 3f2a3c55-1111-4222-8333-944455556666 -C ~/'code/my app'")
        XCTAssertNil(AgentLookIn.cli(.codex, inLine: "To look in: codex resume 3f2a3c55-1111-4222-8333-944455556666 -C /tmp; rm -rf ~"))
        XCTAssertNil(AgentLookIn.cli(.codex, inLine: "To look in: codex resume 3f2a3c55-1111-4222-8333-944455556666 -C $(whoami)"))
        XCTAssertEqual(AgentLookIn.cli(.opencode, inLine: "To look in, with your own OpenCode settings, whose build agent runs commands without asking: opencode ~/w/x --session ses_01JABC"),
                       "opencode ~/w/x --session ses_01JABC")
        XCTAssertNotNil(AgentLookIn.cli(.antigravity, inLine: "To look in, with your own Antigravity settings: cd ~/w/x && agy --conversation 3f2a3c55-1111-4222-8333-944455556666"))
        let script = AgentLookIn.script(folder: "/Users/sam/code/it's here", command: "claude --resume 3f2a3c55-1111-4222-8333-944455556666", title: "Fix login")
        XCTAssertEqual(script, "#!/bin/zsh -l\n# Fix login: opened from Binders' Agents page.\ncd '/Users/sam/code/it'\\''s here' || exit 1\nclaude --resume 3f2a3c55-1111-4222-8333-944455556666\n")
    }
}
