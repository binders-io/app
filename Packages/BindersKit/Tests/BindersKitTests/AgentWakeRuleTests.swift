import XCTest
@testable import BindersKit

final class AgentWakeRuleTests: XCTestCase {
    func testAnAgentsPlacingStartsAnAgentOnlyWithItsStartSwitch() {
        let agent = "Claude Code"
        XCTAssertEqual(AgentWakeRule.verdict(.yours, agent: agent, startsOnItsOwn: false), .wake, "yours wakes as it always did")
        XCTAssertEqual(AgentWakeRule.verdict(.placedByAgent, agent: agent, startsOnItsOwn: true), .wake)
        guard case .waits(let line) = AgentWakeRule.verdict(.placedByAgent, agent: agent, startsOnItsOwn: false) else {
            return XCTFail("a placing waits for your Give to while the agent may not start on its own")
        }
        XCTAssertTrue(line.hasPrefix("Waits for your Give to: Claude Code"), line)
    }
}
