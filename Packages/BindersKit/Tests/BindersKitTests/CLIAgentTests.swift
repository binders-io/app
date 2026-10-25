import XCTest
@testable import BindersKit

/// The command-line coding tools as agents: how agents-cli.json holds them, what an older Binders and a newer one find in
/// it, and which versions Binders starts.
final class CLIAgentTests: XCTestCase {
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Fixtures in the kit's test bundle.
    static func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"), name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheWakeReadsLikeWhatItIs() throws {
        for tool in CLIAgent.allCases {
            let agent = AgentProfile(name: "\(tool.shortName) · app", wake: .cliAgent(CLIAgentWake(tool: tool, repository: "/Users/sam/code/app")),
                                     preset: tool.rawValue)
            let data = try AgentFile(agents: [agent]).encoded()
            let wake = try XCTUnwrap((try object(data)["agents"] as? [[String: Any]])?.first?["wake"] as? NSDictionary)
            XCTAssertEqual(wake, ["cliAgent": ["permissionMode": "acceptEdits", "repository": "/Users/sam/code/app", "tool": tool.rawValue]] as NSDictionary,
                           "its settings sit right under the one key, with no nils")
            XCTAssertEqual(agent.wake.kind, "cliAgent")
            XCTAssertEqual(try AgentFile.decode(data).file.agents, [agent])
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(text.contains(#""cliAgent" : {"#), text)
        }
        XCTAssertEqual(CLIAgent.allCases.map(\.rawValue), ["codex", "opencode", "copilot", "antigravity"])
        XCTAssertEqual(CLIAgent.allCases.map(\.name), ["Codex", "OpenCode", "GitHub Copilot CLI", "Antigravity"])
        XCTAssertEqual(CLIAgent.allCases.map(\.program), ["codex", "opencode", "copilot", "agy"])
        // A kind no earlier build knows: one of them, reading it, leaves that agent out and keeps the rest.
        let known: Set = ["board", "command", "webhook", "shortcut", "claudeCode"]
        XCTAssertFalse(known.contains(AgentProfile.Wake.cliAgent(CLIAgentWake(tool: .codex, repository: "/r")).kind))
        let full = CLIAgentWake(tool: .opencode, repository: "/r", permissionMode: "plan", model: "anthropic/claude-sonnet-4-5",
                                allowedDomains: ["registry.npmjs.org"], executable: "/opt/homebrew/bin/opencode")
        XCTAssertEqual(try JSONDecoder().decode(CLIAgentWake.self, from: JSONEncoder().encode(full)), full, "every field comes back")
    }

    func testAToolOrARepositoryIsNeeded() {
        for json in [#"{"repository": "/r"}"#, #"{"tool": "codex"}"#, #"{"tool": 7, "repository": "/r"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(CLIAgentWake.self, from: Data(json.utf8)), json)
        }
    }

    func testAnUnknownToolIsKeptAsItIs() throws {
        let fromBefore = try Self.fixture("agents-every-old-kind.json")
        var file = try object(Data(fromBefore.utf8))
        var agents = try XCTUnwrap(file["agents"] as? [[String: Any]])
        let gemini: [String: Any] = ["id": "11111111-2222-4333-8444-555555555555", "name": "Gemini · app", "isEnabled": true, "report": "mcp",
                                     "wake": ["cliAgent": ["tool": "gemini", "repository": "/Users/sam/code/app", "permissionMode": "acceptEdits",
                                                           "futureSetting": ["deep": [1, 2.5, true, NSNull()]]]]]
        agents.append(gemini)
        file["agents"] = agents
        let data = try JSONSerialization.data(withJSONObject: file)
        let read = try AgentFile.decode(data)
        XCTAssertEqual(read.file.agents.count, 5, "the five old kinds read")
        XCTAssertEqual(read.skipped, 1, "the newer tool is left out")
        XCTAssertFalse(read.file.agents.contains { $0.name == "Gemini · app" }, "and never read as something else")
        XCTAssertEqual(read.file.kept.count, 1)
        // Saved again, it's written back after the agents this build knows, as it was.
        let saved = try object(read.file.encoded())
        let written = try XCTUnwrap(saved["agents"] as? [[String: Any]])
        XCTAssertEqual(written.count, 6)
        XCTAssertEqual(written.last as NSDictionary?, gemini as NSDictionary)
        XCTAssertEqual(try AgentFile.decode(read.file.encoded()).file.kept, read.file.kept, "and stays kept the next time")
    }

    func testAModeThatIsntKnownRunsAsPlans() throws {
        XCTAssertEqual(CLIAgentWake.modes, ["acceptEdits", "plan"])
        XCTAssertEqual(CLIAgentWake.newAgentMode, "acceptEdits")
        let missing = try JSONDecoder().decode(CLIAgentWake.self, from: Data(#"{"tool": "codex", "repository": "/r"}"#.utf8))
        XCTAssertEqual(missing.permissionMode, "plan", "no mode reads as plan")
        XCTAssertFalse(missing.editsFiles)
        for mode in ["bypassPermissions", "auto", "dontAsk", "", "ACCEPTEDITS", "allow-all"] {
            XCTAssertEqual(CLIAgentWake(tool: .copilot, repository: "/r", permissionMode: mode).safeMode, "plan", mode)
        }
        XCTAssertTrue(CLIAgentWake(tool: .copilot, repository: "/r").editsFiles)
    }

    func testAnAgentsFileFromBeforeReadsAndWritesTheSame() throws {
        // Every old kind, as a 0.8.0 test build wrote it (this lane's code before the change).
        let fromBefore = try Self.fixture("agents-every-old-kind.json")
        let read = try AgentFile.decode(Data(fromBefore.utf8))
        XCTAssertEqual(read.skipped, 0)
        XCTAssertTrue(read.file.kept.isEmpty, "nothing kept aside")
        XCTAssertEqual(read.file.agents.map(\.wake.kind), ["command", "board", "webhook", "shortcut", "claudeCode"])
        XCTAssertEqual(String(decoding: try read.file.encoded(), as: UTF8.self), fromBefore, "byte for byte")
        XCTAssertEqual(try AgentFile(agents: [], kept: []).encoded(), try AgentFile().encoded())
    }

    func testCodeInItsRepositoryUnlessYouSay() {
        for tool in CLIAgent.allCases {
            let agent = AgentProfile(name: "\(tool.shortName) · app", wake: .cliAgent(CLIAgentWake(tool: tool, repository: "/Users/sam/code/app/")),
                                     report: .manual)
            XCTAssertEqual(agent.whatItsFor, "code in the app repository")
            XCTAssertEqual(agent.reporting, .mcp, "it always reports with Binders' tools, whatever the file says")
            var said = agent
            said.purpose = "The website"
            XCTAssertEqual(said.whatItsFor, "The website")
        }
        XCTAssertEqual(AgentProfile(name: "x", wake: .cliAgent(CLIAgentWake(tool: .codex, repository: ""))).whatItsFor, "code")
        XCTAssertEqual(CLIAgent.allCases.map(\.shortName), ["Codex", "OpenCode", "Copilot", "Antigravity"])
    }

    func testVersionsArePinnedByTheirParts() {
        XCTAssertEqual(CLIAgent.codex.checkedVersion, "0.162.0")
        XCTAssertEqual(CLIAgent.opencode.checkedVersion, "1.18.27")
        XCTAssertEqual(CLIAgent.copilot.checkedVersion, "1.0.10")
        XCTAssertTrue(CLIAgent.codex.starts("0.162.0"))
        XCTAssertTrue(CLIAgent.codex.starts("0.162.3"), "a patch release")
        XCTAssertFalse(CLIAgent.codex.starts("0.163.0"), "a minor release needs Check")
        XCTAssertFalse(CLIAgent.codex.starts("1.162.0"))
        XCTAssertTrue(CLIAgent.opencode.starts("1.18.30"))
        XCTAssertFalse(CLIAgent.opencode.starts("1.19.0"))
        XCTAssertTrue(CLIAgent.copilot.starts("1.0.10"))
        XCTAssertFalse(CLIAgent.copilot.starts("1.0.11"), "Copilot's 1.0.x releases carry features: only the one checked")
        XCTAssertFalse(CLIAgent.copilot.starts("1.0.10-beta.1"))
        XCTAssertTrue(CLIAgent.codex.starts("0.163.0", accepted: "0.163.0"), "accepted with Check")
        XCTAssertFalse(CLIAgent.codex.starts("0.164.0", accepted: "0.163.0"), "only the one accepted")
        XCTAssertTrue(CLIAgent.copilot.starts("1.0.11", accepted: "1.0.11"))
        XCTAssertFalse(CLIAgent.codex.starts("not a version"))
        XCTAssertNil(CLIAgent.codex.versionNote("0.162.0"))
        XCTAssertEqual(CLIAgent.codex.versionNote("0.162.1"), "Codex 0.162.1; Binders checked 0.162.0")
    }

    func testAVersionInTheToolsOwnShape() {
        XCTAssertEqual(CLIAgent.codex.version(in: "codex-cli 0.162.0\n"), "0.162.0")
        XCTAssertEqual(CLIAgent.opencode.version(in: "1.18.27\n"), "1.18.27")
        XCTAssertEqual(CLIAgent.copilot.version(in: "GitHub Copilot CLI 1.0.10.\nRun 'copilot update' to check for updates.\n"), "1.0.10")
        XCTAssertEqual(CLIAgent.copilot.version(in: "GitHub Copilot CLI 1.0.11-beta.2.\n"), "1.0.11-beta.2")
        // Anything else isn't the tool.
        XCTAssertNil(CLIAgent.codex.version(in: "1.18.27"))
        XCTAssertNil(CLIAgent.opencode.version(in: "codex-cli 0.162.0"))
        XCTAssertNil(CLIAgent.copilot.version(in: "copilot: command not found"))
        XCTAssertNil(CLIAgent.codex.version(in: ""))
        XCTAssertEqual(CLIAgent.copilot.versionArguments, ["--no-auto-update", "--version"], "the bundled build, not one it downloaded")
        XCTAssertEqual(CLIAgent.codex.versionArguments, ["--version"])
    }

    func testWhatEachToolMayDo() {
        XCTAssertEqual(CLIAgent.allCases.filter(\.runsCommands), [.codex, .antigravity], "only Codex and Antigravity have a sandbox for commands")
        XCTAssertEqual(CLIAgent.allCases.filter { !$0.readsOnly }, [.antigravity], "Antigravity can't be held to reading only")
        XCTAssertEqual(CLIAgentWake.modes(for: .antigravity), ["acceptEdits"])
        XCTAssertEqual(CLIAgentWake.modes(for: .codex), ["acceptEdits", "plan"])
        XCTAssertTrue(CLIAgent.allCases.allSatisfy { !$0.honoursSites }, "no sites in this build")
        XCTAssertEqual(CLIAgent.allCases.filter(\.needsModel), [.opencode])
        XCTAssertEqual(CLIAgent.allCases.map(\.company), ["OpenAI", nil, "GitHub (Microsoft)", "Google"])
        XCTAssertEqual(CLIAgentWake(tool: .opencode, repository: "/r", model: " Anthropic/claude-sonnet-4-5").provider, "anthropic")
        XCTAssertEqual(CLIAgentWake(tool: .opencode, repository: "/r", model: "opencode/big-pickle").provider, "opencode")
        XCTAssertNil(CLIAgentWake(tool: .opencode, repository: "/r", model: "sonnet").provider)
        XCTAssertNil(CLIAgentWake(tool: .opencode, repository: "/r").provider)
        XCTAssertTrue(CLIAgentWake.isOpenCodeModel("anthropic/claude-sonnet-4-5"))
        XCTAssertTrue(CLIAgentWake.isOpenCodeModel("openrouter/meta/llama-3"))
        for model in ["sonnet", "/claude", "anthropic/", "anthropic /x"] {
            XCTAssertFalse(CLIAgentWake.isOpenCodeModel(model), model)
        }
    }

    func testARunRecordComesBackTheSame() throws {
        let record = CLIRunRecord(card: UUID(), run: UUID(), agent: UUID(), agentName: "Codex · app", tool: .codex, mode: "workspace sandbox, no network",
                                  worktree: "/Users/sam/.binders/worktrees/app-1a2b3c4d/binders-3f2504e04f89-codex",
                                  stem: "/Users/sam/Library/Logs/Binders/Agents/3f2504e0-20261018T120000", session: nil, pid: 4242,
                                  processStart: 1_792_000_000.25, startedAt: Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertEqual(CLIRunRecord.decode(try record.encoded()), record)
        XCTAssertNil(CLIRunRecord.decode(Data("{}".utf8)))
        // With the worktree's record in it, so the commit never depends on worktrees.json alone; one without it still reads.
        var full = record
        full.worktreeRecord = AgentWorktreeRecord(card: record.card, tool: .codex, repository: "/Users/sam/code/app", commonDir: "/Users/sam/code/app/.git",
                                                  path: record.worktree, branch: "binders-card-3f2504e04f89-codex",
                                                  gitDir: "/Users/sam/code/app/.git/worktrees/binders-3f2504e04f89-codex", ready: true,
                                                  made: Date(timeIntervalSince1970: 1_792_000_000))
        XCTAssertEqual(CLIRunRecord.decode(try full.encoded()), full)
        XCTAssertEqual(CLIRunRecord.decode(try record.encoded())?.worktreeRecord, nil)
    }

    func testAnEntryIsKeptValueForValue() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"[1, 2.5, true, null, "x", {"a": [false]}]"#.utf8))
        XCTAssertEqual(value, .array([.int(1), .double(2.5), .bool(true), .null, .string("x"), .object(["a": .array([.bool(false)])])]))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }

    func testJSONIsWrittenInTheOrderItsBuilt() {
        let json = OrderedJSON.object([("z", .int(1)), ("a", .array([.bool(true), .string("q\"uote\\n\n{env:X}")]))])
        XCTAssertEqual(json.text(), #"{"z":1,"a":[true,"q\"uote\\n\n{env:X}"]}"#)
        let open = "\\u007b", close = "\\u007d"
        XCTAssertEqual(json.text(escapingBraces: true), #"{"z":1,"a":[true,"q\"uote\\n\n"# + open + "env:X" + close + #""]}"#)
        XCTAssertEqual(OrderedJSON.string("\u{1}/").text(), #""\u0001/""#, "control characters escaped, slashes as they are")
    }
}
