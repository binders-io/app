import XCTest
@testable import BindersKit

final class AgentChatTests: XCTestCase {
    func testMarkdownReadsAsTheManagerWrites() {
        let reply = """
        No agent is working on anything right now.

        **Waiting on you**
        • Post on LinkedIn: the drafts are ready.
        • Show HN: run `harbor update web` first.

        ## Next
        1. Rebuild the CLI
        2) Update Harbor
          - nested
        > a quote
        > that goes on

        ```
        harbor update emails
        ```
        ---
        """
        XCTAssertEqual(ChatMarkdown.blocks(reply), [
            .paragraph("No agent is working on anything right now."),
            .paragraph("**Waiting on you**"),
            .bullet(depth: 0, "Post on LinkedIn: the drafts are ready."),
            .bullet(depth: 0, "Show HN: run `harbor update web` first."),
            .heading(level: 2, "Next"),
            .numbered(depth: 0, number: "1.", "Rebuild the CLI"),
            .numbered(depth: 0, number: "2.", "Update Harbor"),
            .bullet(depth: 1, "nested"),
            .quote("a quote\nthat goes on"),
            .code("harbor update emails"),
            .rule,
        ])
    }

    func testMarkdownLeavesWhatIsntAList() {
        XCTAssertEqual(ChatMarkdown.blocks("**Bold** start\nand more"), [.paragraph("**Bold** start\nand more")])
        XCTAssertEqual(ChatMarkdown.blocks("2026 was a year.\n#hashtag"), [.paragraph("2026 was a year.\n#hashtag")])
        XCTAssertEqual(ChatMarkdown.blocks("```\nunfinished"), [.code("unfinished")])
        XCTAssertEqual(ChatMarkdown.blocks(""), [])
    }

    func testAChatStartsAndCarriesOnItsSession() throws {
        let chat = UUID(), session = UUID()
        let wake = ClaudeCodeWake(repository: "/Users/me/code/app/", permissionMode: "auto", model: "sonnet")
        func launch(resume: Bool, directory: String?, strict: Bool = true) -> ClaudeCodeLaunch {
            AgentChatLaunch.claude(chat: chat, boardName: "Claude Code · app", wake: wake, binders: "/Applications/Binders.app/Contents/MacOS/Binders",
                                   dataFolder: "/Users/me/Library/Application Support/Binders", home: "/Users/me", session: session,
                                   resume: resume, directory: directory, prompt: "hi", strictMCP: strict)
        }
        let first = launch(resume: false, directory: nil)
        XCTAssertEqual(first.directory, "/Users/me/code/app")
        XCTAssertEqual(first.arguments[first.arguments.firstIndex(of: "--worktree")! + 1], AgentChatLaunch.worktreeName(for: chat))
        XCTAssertEqual(first.arguments[first.arguments.firstIndex(of: "--session-id")! + 1], session.uuidString.lowercased())
        XCTAssertEqual(first.arguments[first.arguments.firstIndex(of: "--permission-mode")! + 1], "auto", "the agent's own mode")
        XCTAssertTrue(first.arguments.contains("--strict-mcp-config"))
        XCTAssertEqual(first.arguments[first.arguments.firstIndex(of: "--model")! + 1], "sonnet")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.arguments[first.arguments.firstIndex(of: "--mcp-config")! + 1].utf8)) as? [String: Any])
        let env = try XCTUnwrap((((config["mcpServers"] as? [String: Any])?["binders"]) as? [String: Any])?["env"] as? [String: String])
        XCTAssertEqual(MCPConfinement.read(env), .board(card: nil), "the board's tools as the agent, no card of its own")
        XCTAssertEqual(env["BINDERS_CHAT"], chat.uuidString)
        for denied in ["Read(~/.ssh/**)", "Bash(git push)"] { XCTAssertTrue(first.arguments.contains(denied), denied) }

        let worktree = AgentChatLaunch.worktree(repository: "/Users/me/code/app/", chat: chat)
        XCTAssertEqual(worktree, "/Users/me/code/app/.claude/worktrees/" + AgentChatLaunch.worktreeName(for: chat))
        let next = launch(resume: true, directory: worktree)
        XCTAssertEqual(next.directory, worktree)
        XCTAssertEqual(next.arguments[next.arguments.firstIndex(of: "--resume")! + 1], session.uuidString.lowercased())
        XCTAssertFalse(next.arguments.contains("--worktree"))
        XCTAssertFalse(next.arguments.contains("--session-id"))

        let again = launch(resume: false, directory: worktree)
        XCTAssertEqual(again.directory, worktree)
        XCTAssertTrue(again.arguments.contains("--session-id"))
        XCTAssertFalse(again.arguments.contains("--worktree"), "a new session where the chat's worktree is")

        let managed = launch(resume: false, directory: nil, strict: false)
        XCTAssertFalse(managed.arguments.contains("--strict-mcp-config"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(managed.arguments[managed.arguments.firstIndex(of: "--settings")! + 1].utf8)) as? [String: Any])
        XCTAssertNotNil((settings["hooks"] as? [String: Any])?["PreToolUse"], "the board-tools guard where the limit can't be")
    }

    func testWhatARunSaid() {
        let output = """
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Looking"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Found it."}]}}
        {"type":"result","result":"Found it: the minimum width.","is_error":false}
        """
        XCTAssertEqual(AgentChatStream.said(in: output), "Found it.")
        XCTAssertEqual(AgentChatStream.reply(in: output).text, "Found it: the minimum width.")
        XCTAssertFalse(AgentChatStream.reply(in: output).error)
        XCTAssertNil(AgentChatStream.reply(in: #"{"type":"result","result":"","is_error":true}"#).text)
        XCTAssertTrue(AgentChatStream.sessionGone(in: "Error: No conversation found with session ID: abc"))
        XCTAssertTrue(AgentChatReach.chats("claudeCode") && AgentChatReach.chats("board") && !AgentChatReach.chats("command") && !AgentChatReach.chats("webhook"))
        XCTAssertNil(AgentPrompts.worthKeeping(AgentChatPrompt.first(agent: "A", text: "hello there, this is long enough", draftsFirst: true)))
    }
}
