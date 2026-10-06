import XCTest
@testable import BindersKit

final class AgentPromptsTests: XCTestCase {
    func testClaudeCodePrompts() throws {
        let line = #"{"display":"Fix the undo crash when a card's sheet closes [Pasted text #1 +12 lines]","pastedContents":{"1":{"content":"secret log"}},"timestamp":1759334400000,"project":"/Users/someone/Documents/Acme/app","sessionId":"abc"}"#
        let prompt = try XCTUnwrap(AgentPrompts.claudeCode(line))
        XCTAssertEqual(prompt.text, "Fix the undo crash when a card's sheet closes [Pasted text #1 +12 lines]")
        XCTAssertFalse(prompt.text.contains("secret log"), "pasted contents aren't kept")
        XCTAssertEqual(prompt.projectName, "Acme/app")
        XCTAssertEqual(prompt.date, Date(timeIntervalSince1970: 1_759_334_400))
        XCTAssertEqual(prompt.session, "abc")
    }

    func testWhatIsntWriting() {
        func claude(_ display: String) -> String? {
            AgentPrompts.claudeCode(#"{"display":"\#(display)","timestamp":1,"project":"/p"}"#)?.text
        }
        XCTAssertNil(claude("/clear"))
        XCTAssertNil(claude("/model opus"))
        XCTAssertEqual(claude("/compact keep the pricing decisions"), "keep the pricing decisions")
        XCTAssertNil(claude("!git status --short"))
        XCTAssertNil(claude("yes"))
        XCTAssertNil(claude("go ahead"))
        XCTAssertNil(claude("1 2 3"))
        XCTAssertNil(AgentPrompts.claudeCode("not json"))
    }

    func testCodexPrompts() throws {
        let prompt = try XCTUnwrap(AgentPrompts.codex(#"{"session_id":"s1","ts":1759334400,"text":"Write the release notes for 0.6.0"}"#))
        XCTAssertEqual(prompt.text, "Write the release notes for 0.6.0")
        XCTAssertNil(prompt.project)
    }

    func testOnlyCompleteLinesAreRead() {
        let data = Data("{\"a\":1}\n{\"b\":2}\n{\"c\":".utf8)
        let (lines, consumed) = AgentPrompts.completeLines(in: data)
        XCTAssertEqual(lines, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(consumed, 16)
        XCTAssertEqual(AgentPrompts.completeLines(in: Data("{\"partial".utf8)).consumed, 0)
    }
}

final class AgentHarnessTests: XCTestCase {
    private func harness(_ id: String) -> AgentHarness { AgentHarness.builtIn.first { $0.id == id }! }
    private func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8)) }

    func testTheBuiltInDescriptionsReadTheirRecords() {
        let claude = harness("claudeCode").prompt(from: json(#"{"display":"Fix the undo crash in the card sheet","timestamp":1759334400000,"project":"/Users/someone/Acme/app"}"#))
        XCTAssertEqual(claude?.text, "Fix the undo crash in the card sheet")
        XCTAssertEqual(claude?.projectName, "Acme/app")
        XCTAssertEqual(claude?.date, Date(timeIntervalSince1970: 1_759_334_400))
        XCTAssertEqual(harness("codex").prompt(from: json(#"{"ts":1759334400,"text":"Write the release notes now"}"#))?.text, "Write the release notes now")

        let gemini = harness("geminiCLI")
        let log = json(#"[{"sessionId":"s","messageId":0,"type":"user","message":"Explain the attachment downloader please","timestamp":"2026-10-01T12:00:00.000Z"},{"type":"gemini","message":"Sure, here's how it works today"}]"#)
        let prompts = gemini.items(in: log).compactMap(gemini.prompt(from:))
        XCTAssertEqual(prompts.map(\.text), ["Explain the attachment downloader please"], "only what you sent, not the model's replies")
        XCTAssertEqual(prompts.first?.date, ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z"))

        let copilot = harness("copilotCLI")
        XCTAssertEqual(copilot.items(in: json(#"{"commandHistory":["add a test for the tables parser","/clear"]}"#)).compactMap(copilot.prompt(from:)).map(\.text),
                       ["add a test for the tables parser"])
    }

    func testYourOwnDescriptionsJoinOrReplaceTheBuiltInOnes() {
        let custom = AgentHarness.decode(Data(#"""
        [{"id":"aider","name":"Aider","format":"jsonl","path":"~/aider.jsonl","text":"prompt"},
         {"id":"codex","name":"Codex (mine)","format":"jsonl","path":"~/elsewhere.jsonl","text":"text"},
         {"id":"broken","name":"No query","format":"sqlite","path":"~/x.db"}]
        """#.utf8))
        XCTAssertEqual(custom.map(\.id), ["aider", "codex"], "one that can't work is left out")
        let all = AgentHarness.all(adding: custom)
        XCTAssertEqual(all.first { $0.id == "codex" }?.name, "Codex (mine)")
        XCTAssertTrue(all.contains { $0.id == "aider" } && all.contains { $0.id == "claudeCode" })
    }

    func testWhatAHookSends() {
        XCTAssertEqual(HookPayload.read(Data(#"{"prompt":"Ship the tables","cwd":"/Users/someone/Acme"}"#.utf8))?.text, "Ship the tables")
        XCTAssertEqual(HookPayload.read(Data(#"{"prompt":"x","workspace_roots":["/a/b"]}"#.utf8))?.project, "/a/b")
        XCTAssertEqual(HookPayload.read(Data("plain words from a tool\n".utf8))?.text, "plain words from a tool")
        XCTAssertNil(HookPayload.read(Data(#"{"other":1}"#.utf8)))
    }
}
