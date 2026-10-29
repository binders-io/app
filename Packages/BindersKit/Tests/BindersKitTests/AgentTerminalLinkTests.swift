import XCTest
@testable import BindersKit

final class AgentTerminalLinkTests: XCTestCase {
    private let blocks: [AgentTerminalBlock] = [
        AgentTerminalBlock(id: "0-run", kind: .run("Started · Tue 10:02")),
        AgentTerminalBlock(id: "0-you", kind: .you("Can it fold Done into a narrower strip?")),
        AgentTerminalBlock(id: "0-b", kind: .binders(summary: "Binders woke it for the card.", text: "[Binders] …")),
        AgentTerminalBlock(id: "0-s", kind: .said("On it. **Done** folds.")),
        AgentTerminalBlock(id: "0-t", kind: .tool(AgentTerminalTool(name: "Bash", argument: "swift test", status: .failed, output: ["1 failure"]))),
        AgentTerminalBlock(id: "0-e", kind: .tool(AgentTerminalTool(name: "Update", argument: "Board.swift", status: .ok, summary: "Updated Board.swift with 1 addition and 1 removal",
                                                                  diff: ["- a", "+ b"]))),
        AgentTerminalBlock(id: "0-p", kind: .plan([AgentSessionPlanItem(text: "Read the board", status: .done), AgentSessionPlanItem(text: "Fold Done", status: .active)])),
        AgentTerminalBlock(id: "0-end", kind: .end(ok: false, line: "Stopped: out of turns")),
        AgentTerminalBlock(id: "waiting-0", kind: .waiting("And the spacing?", why: "Goes to it when this run ends")),
    ]

    func testBlocksGoOverTheLinkAndComeBackTheSame() {
        let shown = AgentSessionShown(kind: .card, id: "C", title: "Fold Done", blocks: blocks, earlier: 3, running: true, current: "Running swift test",
                                      since: Date(timeIntervalSince1970: 1_800_000_000.25), hint: "It takes your words now.", needsYou: false, column: "In progress")
        let object = AgentSessionLink.object(shown)
        XCTAssertEqual((object["blocks"] as? [[String: Any]])?.first?["type"] as? String, "run")
        XCTAssertNotNil(object["needs_you"], "the link's keys are snake_case")
        XCTAssertEqual(AgentSessionLink.decode(AgentSessionShown.self, from: object), shown)
    }

    func testABlockOfAKindThisBuildDoesntKnowReadsAsWhatItSaid() throws {
        let data = Data(#"{"id":"x","type":"hologram","text":"Something new"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AgentTerminalBlock.self, from: data).kind, .said("Something new"))
    }

    func testAPhoneIsSentTheNewestBlocksWithLongOutputCut() {
        let long = AgentTerminalTool(name: "Bash", argument: "make", status: .ok, output: (1...100).map { "line \($0)" },
                                     diff: (1...200).map { "+ \($0)" })
        let many = (0..<200).map { AgentTerminalBlock(id: "\($0)", kind: .said("said \($0)")) } + [AgentTerminalBlock(id: "t", kind: .tool(long))]
        let sent = AgentSessionLink.trimmed(many)
        XCTAssertEqual(sent.blocks.count, AgentSessionLink.blocksSent)
        XCTAssertEqual(sent.earlier, many.count - AgentSessionLink.blocksSent)
        XCTAssertEqual(sent.blocks.last?.id, "t", "the newest are kept")
        guard case .tool(let tool) = sent.blocks.last?.kind else { return XCTFail("the tool is kept") }
        XCTAssertEqual(tool.output.count, AgentSessionLink.outputSent)
        XCTAssertEqual(tool.more, 100 - AgentSessionLink.outputSent)
        XCTAssertEqual(tool.diff.count, AgentSessionLink.diffSent)
        XCTAssertEqual(tool.diffMore, 200 - AgentSessionLink.diffSent)
        let said = AgentSessionLink.trimmed([AgentTerminalBlock(id: "s", kind: .said(String(repeating: "a", count: 9_000)))]).blocks[0]
        guard case .said(let text) = said.kind else { return XCTFail("what it said is kept") }
        XCTAssertEqual(text.count, AgentSessionLink.textSent)
    }

    func testASessionSaysWhereItIs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func session(_ kind: AgentSessionSummary.Kind, running: Bool = false, needsYou: Bool = false, done: Bool = false) -> AgentSessionSummary {
            AgentSessionSummary(kind: kind, id: "x", title: "T", updatedAt: now, running: running, needsYou: needsYou, done: done)
        }
        XCTAssertEqual(session(.card, running: true).state(now: now), "running")
        XCTAssertEqual(session(.card, needsYou: true).state(now: now), "needs you")
        XCTAssertEqual(session(.card, done: true).state(now: now), "done")
        XCTAssertEqual(session(.card).state(now: now), "idle")
        XCTAssertEqual(session(.chat).state(now: now), now.formatted(.dateTime.hour().minute()))
    }

    func testWhatAnAgentWears() {
        XCTAssertEqual(AgentAvatarKind.of(wakes: "claudeCode", tool: nil, name: "Builder"), .claude)
        XCTAssertEqual(AgentAvatarKind.of(wakes: "cliAgent", tool: .opencode, name: "Builder"), .opencode)
        XCTAssertEqual(AgentAvatarKind.of(wakes: "cliAgent", tool: .antigravity, name: "Builder").icon, "provider-gemini")
        XCTAssertEqual(AgentAvatarKind.of(wakes: "board", tool: nil, name: "Grok Bot"), .grok)
        XCTAssertEqual(AgentAvatarKind.of(wakes: "board", tool: nil, name: "Pennant"), .other)
        XCTAssertEqual(AgentAvatarKind.other.fill(name: "Pennant")?.hex, AgentAvatarKind.other.fill(name: "pennant")?.hex, "the same name, the same colour")
        XCTAssertEqual(AgentAvatarKind.grok.fill(name: "Grok")?.darkLetter, true)
        XCTAssertNil(AgentAvatarKind.manager.fill(name: "The Manager"))
        XCTAssertEqual(AgentAvatarKind.initial("  pennant"), "P")
    }
}
