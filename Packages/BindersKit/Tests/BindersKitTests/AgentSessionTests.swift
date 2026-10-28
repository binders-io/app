import XCTest
@testable import BindersKit

final class AgentSessionTests: XCTestCase {
    func testClaudeCodeStreamBecomesATimeline() {
        var reader = AgentSessionReader(tool: .claude)
        reader.feed(text: """
        {"type":"system","subtype":"init","session_id":"abc"}
        {"type":"assistant","message":{"id":"m1","content":[{"type":"text","text":"On it. I'll tighten the rows."},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/Users/x/repo/Binders/UI/Hub/HubView.swift"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"..."}]}}
        {"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/r/HubView.swift","old_string":"a\\n.padding(12)\\nb","new_string":"a\\n.padding(Spacing.md)\\n.animation(.snappy)\\nb"}}]}}
        {"type":"assistant","message":{"id":"m3","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift test --filter HubTests"}}]}}
        not json at all
        {"type":"assistant","message":{"id":"m4","content":[{"type":"tool_use","id":"t4","name":"TodoWrite","input":{"todos":[{"content":"Read feedback","status":"completed"},{"content":"Tighten rows","activeForm":"Tightening rows","status":"in_progress"},{"content":"Open PR","status":"pending"}]}}]}}
        """)
        XCTAssertEqual(reader.session, "abc")
        XCTAssertEqual(reader.events.first?.kind, .said("On it. I'll tighten the rows."))
        guard case .tool(let read) = reader.events[1].kind else { return XCTFail("a read") }
        XCTAssertEqual(read.kind, .read)
        XCTAssertEqual(read.subject, "UI/Hub/HubView.swift")
        XCTAssertEqual(read.status, .ok)
        guard case .tool(let edit) = reader.events[2].kind else { return XCTFail("an edit") }
        XCTAssertEqual(edit.diff, ["- .padding(12)", "+ .padding(Spacing.md)", "+ .animation(.snappy)"])
        XCTAssertEqual(edit.added, 2)
        XCTAssertEqual(edit.removed, 1)
        XCTAssertEqual(edit.status, .running)
        guard case .tool(let test) = reader.events[3].kind else { return XCTFail("tests") }
        XCTAssertEqual(test.kind, .test)
        XCTAssertEqual(reader.plan.map(\.status), [.done, .active, .pending])
        XCTAssertEqual(reader.current, "Tightening rows")
        reader.feed(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":[{"type":"text","text":"24 passed"}]}]}}"#)
        guard case .tool(let passed) = reader.events[3].kind else { return XCTFail("tests") }
        XCTAssertEqual(passed.line, "Tests passed")
        XCTAssertEqual(passed.output, "24 passed")
        reader.feed(#"{"type":"result","subtype":"success","is_error":false,"result":"Done."}"#)
        XCTAssertTrue(reader.ended)
        XCTAssertNil(reader.current)
    }

    func testCodexItems() {
        var reader = AgentSessionReader(tool: .codex)
        reader.feed(text: """
        {"type":"thread.started","thread_id":"th1"}
        {"type":"item.started","item":{"id":"i1","type":"command_execution","command":"go test ./...","status":"in_progress"}}
        {"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"go test ./...","aggregated_output":"FAIL x","exit_code":1,"status":"failed"}}
        {"type":"item.completed","item":{"id":"i2","type":"file_change","changes":[{"path":"a/b/c/d.go","kind":"update"}],"status":"completed"}}
        {"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"Fixed it."}}
        {"type":"turn.completed"}
        """)
        XCTAssertEqual(reader.session, "th1")
        guard case .tool(let test) = reader.events[0].kind, case .tool(let change) = reader.events[1].kind else { return XCTFail() }
        XCTAssertEqual(test.line, "Tests failed")
        XCTAssertEqual(change.kind, .edit)
        XCTAssertEqual(change.subject, "b/c/d.go")
        XCTAssertEqual(reader.events[2].kind, .said("Fixed it."))
        XCTAssertEqual(reader.events.last?.kind, .ended(ok: true, words: nil))
    }

    func testOpenCodeAndCopilotTools() {
        var open = AgentSessionReader(tool: .opencode)
        open.feed(#"{"type":"tool_use","sessionID":"ses_1","part":{"callID":"c1","tool":"bash","state":{"status":"completed","input":{"command":"npm test"},"output":"ok"}}}"#)
        guard case .tool(let step) = open.events.first?.kind else { return XCTFail() }
        XCTAssertEqual(step.kind, .test)
        XCTAssertEqual(step.status, .ok)
        var copilot = AgentSessionReader(tool: .copilot)
        copilot.feed(#"{"type":"tool.execution_start","data":{"toolCallId":"x","toolName":"create_task","mcpServerName":"binders","arguments":{}}}"#)
        copilot.feed(#"{"type":"tool.execution_complete","data":{"toolCallId":"x","success":true}}"#)
        guard case .tool(let board) = copilot.events.first?.kind else { return XCTFail() }
        XCTAssertEqual(board.kind, .board)
        XCTAssertEqual(board.status, .ok)
    }

    func testTheTimelineIsKeptShort() {
        var reader = AgentSessionReader(tool: .claude)
        for index in 0..<(AgentSessionReader.eventLimit + 20) {
            reader.feed(Substring(#"{"type":"assistant","message":{"id":"m\#(index)","content":[{"type":"text","text":"line \#(index)"}]}}"#))
        }
        XCTAssertEqual(reader.events.count, AgentSessionReader.eventLimit)
        XCTAssertEqual(reader.events.last?.kind, .said("line \(AgentSessionReader.eventLimit + 19)"))
    }
}
