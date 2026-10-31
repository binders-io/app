import XCTest
@testable import BindersKit

final class HubAgentsTests: XCTestCase {
    let hub = URL(string: "https://hub.example.com")!

    func testMCPURL() {
        XCTAssertEqual(HubAgents.mcpURL(hub: hub).absoluteString, "https://hub.example.com/mcp")
        XCTAssertEqual(HubAgents.mcpURL(hub: URL(string: "http://localhost:5173/")!).absoluteString, "http://localhost:5173/mcp")
    }

    func testServerName() {
        let team = HubAgents.serverName(spaceName: "Team", hub: hub, space: "team")
        XCTAssertTrue(team.hasPrefix("binders-team-"), team)
        XCTAssertEqual(team.count, "binders-team-".count + 6)
        XCTAssertEqual(team, HubAgents.serverName(spaceName: "Team", hub: URL(string: "https://hub.example.com/")!, space: "team"),
                       "the same on every Mac and in every run, a trailing slash or not")
        XCTAssertTrue(HubAgents.serverName(spaceName: "Robin's  Lab!", hub: hub, space: "lab").hasPrefix("binders-robin-s-lab-"))
        XCTAssertTrue(HubAgents.serverName(spaceName: "  ", hub: hub, space: "x").hasPrefix("binders-hub-"), "nothing to name it by")
        XCTAssertTrue(HubAgents.serverName(spaceName: "Binders", hub: hub, space: "x").hasPrefix("binders-hub-"), "never Binders' own server's name")
        XCTAssertTrue(HubAgents.serverName(spaceName: "Équipe", hub: hub, space: "x").hasPrefix("binders-quipe-"))
        XCTAssertFalse(HubAgents.serverName(spaceName: String(repeating: "a-", count: 30), hub: hub, space: "x").contains("--"))
    }

    func testServerNamesDontCollide() {
        // Two Binders named Team, on one hub or on two, are two servers.
        let one = HubAgents.serverName(spaceName: "Team", hub: hub, space: "team")
        XCTAssertNotEqual(one, HubAgents.serverName(spaceName: "Team", hub: hub, space: "team-2"))
        XCTAssertNotEqual(one, HubAgents.serverName(spaceName: "Team", hub: URL(string: "https://other.example.com")!, space: "team"))
    }

    func testProvider() {
        XCTAssertEqual(HubAgents.provider(forTool: "Claude Code"), "claude")
        XCTAssertEqual(HubAgents.provider(forTool: "Cursor"), "cursor")
        XCTAssertEqual(HubAgents.provider(forTool: "VS Code"), "copilot")
        XCTAssertEqual(HubAgents.provider(forTool: "Codex CLI"), "openai")
        XCTAssertEqual(HubAgents.provider(forTool: "Windsurf"), "other")
    }

    func testAgentName() {
        XCTAssertEqual(HubAgents.agentName(tool: "Claude Code", mac: "Robin's MacBook"), "Claude Code · Robin's MacBook")
        XCTAssertEqual(HubAgents.agentName(tool: "Claude Code", mac: " "), "Claude Code")
    }

    func testNewAgentBody() throws {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: HubAgents.newAgent(name: "Claude Code · Mac", provider: "claude",
                                                                                         binders: ["binder-b", "binder-a"], runsOn: "Mac")) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Claude Code · Mac")
        XCTAssertEqual(body["provider"] as? String, "claude")
        XCTAssertEqual(body["binders"] as? [String], ["binder-a", "binder-b"])
        XCTAssertEqual(body["runsOn"] as? String, "Mac")
        XCTAssertEqual(body["repos"] as? [String], [])
        let patch = try XCTUnwrap(JSONSerialization.jsonObject(with: HubAgents.agentBinders(["z", "y"])) as? [String: Any])
        XCTAssertEqual(patch["binders"] as? [String], ["y", "z"])
    }

    func testIssued() {
        let issued = HubAgents.issued(from: Data(#"{"agent":{"id":"agent-1","name":"x"},"token":"bnd_abc"}"#.utf8))
        XCTAssertEqual(issued?.agent, "agent-1")
        XCTAssertEqual(issued?.token, "bnd_abc")
        XCTAssertNil(HubAgents.issued(from: Data(#"{"agent":{"id":"agent-1"},"token":"bnp_abc"}"#.utf8)), "a person's token isn't an agent's")
        XCTAssertNil(HubAgents.issued(from: Data(#"{"error":"No."}"#.utf8)))
        XCTAssertNil(HubAgents.issued(from: Data("not json".utf8)))
    }

    func testEntries() {
        let url = HubAgents.mcpURL(hub: hub)
        let typed = HubAgents.entry(.typed, url: url, token: "bnd_t")
        XCTAssertEqual(typed["type"] as? String, "http")
        XCTAssertEqual(typed["url"] as? String, "https://hub.example.com/mcp")
        XCTAssertEqual((typed["headers"] as? [String: String])?["Authorization"], "Bearer bnd_t")
        XCTAssertNil(HubAgents.entry(.url, url: url, token: "bnd_t")["type"])
        XCTAssertEqual(HubAgents.entry(.serverURL, url: url, token: "bnd_t")["serverUrl"] as? String, "https://hub.example.com/mcp")
        XCTAssertTrue(HubAgents.isEntry(typed, for: url))
        XCTAssertTrue(HubAgents.isEntry(HubAgents.entry(.serverURL, url: url, token: "bnd_t"), for: url))
        XCTAssertFalse(HubAgents.isEntry(["command": "/x/Binders", "args": ["--mcp"]], for: url))
        XCTAssertFalse(HubAgents.isEntry(nil, for: url))
    }

    func testAddingToAConfiguration() throws {
        let url = HubAgents.mcpURL(hub: hub)
        let theirs = Data(#"{"mcpServers":{"binders":{"command":"/x/Binders","args":["--mcp"]}},"other":1}"#.utf8)
        let added = try MCPConfigFile.adding(HubAgents.entry(.url, url: url, token: "bnd_t"), named: "binders-team-3f9a1c", to: theirs)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: added) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["binders"], "Binders' own server stays")
        XCTAssertTrue(HubAgents.isEntry(servers["binders-team-3f9a1c"] as? [String: Any], for: url))
        XCTAssertEqual(object["other"] as? Int, 1)
    }
}
