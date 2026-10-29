import XCTest
@testable import BindersKit

/// A Claude Code that an organization manages (lane RF1): the run without the limit to Binders' tools, what its output
/// says, and the hook that keeps every other MCP tool out of such a run.
final class ClaudeCodeManagedTests: XCTestCase {
    private let card = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let session = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
    private let binders = "/Applications/Binders.app/Contents/MacOS/Binders"

    private func launch(strict: Bool) -> ClaudeCodeLaunch {
        ClaudeCodeLaunch.make(card: card, reason: .ready, boardName: "Claude Code · app", wake: ClaudeCodeWake(repository: "/Users/sam/code/app", permissionMode: "auto"),
                              binders: binders, dataFolder: "/Users/sam/Library/Application Support/Binders", home: "/Users/sam",
                              worktreeExists: false, session: session, strictMCP: strict)
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private func settings(_ launch: ClaudeCodeLaunch) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value(after: "--settings", in: launch.arguments)).utf8)) as? [String: Any])
    }

    func testWithoutTheLimitOnlyTheFlagGoesAndAHookKeepsOtherToolsOut() throws {
        let strict = launch(strict: true), loose = launch(strict: false)
        XCTAssertTrue(strict.arguments.contains("--strict-mcp-config"), "limited to Binders' tools, as it always was")
        XCTAssertFalse(loose.arguments.contains("--strict-mcp-config"))
        // Everything else is the same: the server, what's allowed, the deny list, the sandbox, the session.
        let settingsIndex = try XCTUnwrap(strict.arguments.firstIndex(of: "--settings")) + 1
        var withoutFlag = strict.arguments.filter { $0 != "--strict-mcp-config" }
        var looseArguments = loose.arguments
        withoutFlag[settingsIndex - 1] = "<settings>"
        looseArguments[try XCTUnwrap(looseArguments.firstIndex(of: "--settings")) + 1] = "<settings>"
        XCTAssertEqual(withoutFlag, looseArguments, "only the flag differs on the command line")
        XCTAssertEqual(value(after: "--allowedTools", in: loose.arguments), "mcp__binders")
        XCTAssertEqual(value(after: "--mcp-config", in: loose.arguments), value(after: "--mcp-config", in: strict.arguments), "the same Binders server, for the card")
        let strictSettings = try settings(strict), looseSettings = try settings(loose)
        XCTAssertEqual(NSDictionary(dictionary: strictSettings["permissions"] as? [String: Any] ?? [:]),
                       NSDictionary(dictionary: looseSettings["permissions"] as? [String: Any] ?? [:]), "the same deny list")
        XCTAssertEqual(NSDictionary(dictionary: strictSettings["sandbox"] as? [String: Any] ?? [:]),
                       NSDictionary(dictionary: looseSettings["sandbox"] as? [String: Any] ?? [:]), "the same sandbox")
        let strictHooks = try XCTUnwrap(strictSettings["hooks"] as? [String: Any])
        let looseHooks = try XCTUnwrap(looseSettings["hooks"] as? [String: Any])
        XCTAssertNil(strictHooks["PreToolUse"], "a run limited to Binders' tools needs no guard")
        XCTAssertNotNil(looseHooks["Stop"])
        XCTAssertNotNil(looseHooks["SessionEnd"])
        let guardEntry = try XCTUnwrap((looseHooks["PreToolUse"] as? [[String: Any]])?.first)
        XCTAssertEqual(guardEntry["matcher"] as? String, "mcp__.*", "every MCP tool asks first")
        let command = try XCTUnwrap((guardEntry["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(command["command"] as? String, "'\(binders)' --agent-hook pre-tool")
        XCTAssertEqual(command["type"] as? String, "command")
        XCTAssertEqual(ClaudeCodeToolGuard.hook, "pre-tool")
    }

    func testTheGuardLetsThroughOnlyTheBoardTools() {
        func refusal(_ tool: String) -> String? { ClaudeCodeToolGuard.refusal(Data(#"{"hook_event_name":"PreToolUse","tool_name":"\#(tool)","tool_input":{}}"#.utf8)) }
        for tool in ["get_task", "claim_task", "update_task", "ask_on_task", "complete_task", "request_approval", "propose_work_items"] {
            XCTAssertNil(refusal("mcp__binders__\(tool)"), tool)
        }
        // Binders' other tools, from a server of that name the run didn't bring (yours from Settings → MCP, or your
        // organization's), and everyone else's.
        XCTAssertNotNil(refusal("mcp__binders__search_knowledge"))
        XCTAssertNotNil(refusal("mcp__binders__list_notes"))
        XCTAssertNotNil(refusal("mcp__github__create_issue"))
        XCTAssertNotNil(refusal("mcp__binders-card__get_task"))
        XCTAssertNotNil(refusal("mcp__bindersx__get_task"))
        XCTAssertTrue(refusal("mcp__slack__post_message")?.contains("mcp__slack__post_message") == true, "it says which tool")
        XCTAssertNotNil(ClaudeCodeToolGuard.refusal(Data("not json".utf8)), "what it can't read is refused")
        XCTAssertNotNil(ClaudeCodeToolGuard.refusal(Data(#"{"tool_input":{}}"#.utf8)))
        XCTAssertEqual(ClaudeCodeToolGuard.boardTools.count, 14, "open_pull_request among them, which the server offers only where it's let")
    }

    func testTheRefusalOfTheLimit() {
        let output = "Error: You cannot use --strict-mcp-config when an enterprise MCP config is present\n"
        XCTAssertEqual(ClaudeCodeManaged.finding(in: output), .refusedOnlyBinders)
        // The refusal ends the run: it comes first, whatever else is there.
        XCTAssertEqual(ClaudeCodeManaged.finding(in: "Warning: managed setting disableSideloadFlags forbids --mcp-config on this machine; ignoring 1 server\n" + output),
                       .refusedOnlyBinders)
    }

    func testBindersToolsKeptOut() {
        let lines = [
            "Warning: an enterprise MCP config (managed-mcp.json) is present and has exclusive control over MCP servers; ignoring 1 MCP server supplied via --mcp-config: binders",
            "Ignored: an enterprise MCP config (managed-mcp.json) is present and has exclusive control over MCP servers",
            "You cannot dynamically configure MCP servers when an enterprise MCP config is present",
            "Warning: managed setting disableSideloadFlags forbids --mcp-config on this machine; ignoring 1 server-delivered MCP server: binders",
            "the enterprise MCP config (managed-mcp.json) keeps exclusive control over MCP servers; ignoring 1 dynamically configured MCP server: binders",
            "Note: these configured MCP servers are blocked by the organization's managed policy, so their tools are unavailable: binders",
        ]
        for line in lines { XCTAssertEqual(ClaudeCodeManaged.finding(in: "something first\n" + line + "\n{\"type\":\"result\"}"), .keptOut, line) }
        // A policy line about other servers isn't about Binders'.
        XCTAssertNil(ClaudeCodeManaged.finding(in: "Note: these configured MCP servers are blocked by the organization's managed policy, so their tools are unavailable: github, binders-card"))
    }

    func testTheRunsStartSaysWhichServersItHas() {
        func start(_ servers: String) -> String {
            #"{"type":"system","subtype":"init","session_id":"x","tools":["Read"],"mcp_servers":[\#(servers)]}"#
        }
        XCTAssertNil(ClaudeCodeManaged.finding(in: start(#"{"name":"binders","status":"connected"}"#)), "Binders' server connected: nothing to say")
        XCTAssertNil(ClaudeCodeManaged.finding(in: start(#"{"name":"binders","status":"failed"}"#)), "one that failed isn't the organization's doing")
        XCTAssertEqual(ClaudeCodeManaged.finding(in: start(#"{"name":"github","status":"connected"}"#)), .keptOut, "Binders' missing from it: left out")
        XCTAssertEqual(ClaudeCodeManaged.finding(in: start("")), .keptOut)
        XCTAssertEqual(ClaudeCodeManaged.finding(in: start(#"{"name":"binders","status":"failed","error":"Blocked by enterprise policy (allowedMcpServers/deniedMcpServers)"}"#)),
                       .keptOut, "blocked by a policy")
        XCTAssertNil(ClaudeCodeManaged.finding(in: #"{"type":"assistant","message":{"content":"has exclusive control over MCP servers"}}"#),
                     "what the run says in its messages doesn't count")
        XCTAssertNil(ClaudeCodeManaged.finding(in: ""))
    }

    func testTheLinesSayItPlainly() {
        for line in [ClaudeCodeManaged.startedAgainLine, ClaudeCodeManaged.keptOutLine, ClaudeCodeManaged.settingsLine] {
            XCTAssertFalse(line.contains("strict") || line.contains("MCP") || line.contains("!"), line)
            XCTAssertTrue(line.contains("organization"), line)
        }
        XCTAssertTrue(ClaudeCodeManaged.keptOutLine.contains("admin") && ClaudeCodeManaged.keptOutLine.contains("Post to the Claude Code session open in this repository")
                      && ClaudeCodeManaged.keptOutLine.contains("command agent"), "what to do")
        XCTAssertEqual(ClaudeCodeManaged.folder, "/Library/Application Support/ClaudeCode")
    }
    // MARK: The Manager on a managed Mac

    func testSettingsFilesAreFoundWhereverAnOrganizationPutsThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("managed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("ClaudeCode", isDirectory: true), profiles = root.appendingPathComponent("Managed Preferences", isDirectory: true)
        XCTAssertEqual(ClaudeCodeManaged.settingsFiles(folder: folder.path, preferences: profiles.path, user: "sam"), [], "nothing there, nothing managed")
        let dropIns = folder.appendingPathComponent(ClaudeCodeManaged.dropInFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dropIns, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profiles.appendingPathComponent("sam"), withIntermediateDirectories: true)
        try Data(#"{"permissions":{}}"#.utf8).write(to: dropIns.appendingPathComponent("10-base.json"))
        try Data("x".utf8).write(to: dropIns.appendingPathComponent("notes.txt"))
        let profile = try PropertyListSerialization.data(fromPropertyList: ["allowManagedHooksOnly": true], format: .xml, options: 0)
        try profile.write(to: profiles.appendingPathComponent("sam/\(ClaudeCodeManaged.preferencesDomain).plist"))
        let files = ClaudeCodeManaged.settingsFiles(folder: folder.path, preferences: profiles.path, user: "sam")
        XCTAssertEqual(files.map(\.lastPathComponent), ["10-base.json", "com.anthropic.claudecode.plist"], "a drop-in and the profile, not other files")
        XCTAssertTrue(ClaudeCodeManaged.turnsOn("allowManagedHooksOnly", in: files), "read from the profile's property list")
        XCTAssertFalse(ClaudeCodeManaged.turnsOn("disableAllHooks", in: files))
    }

    func testARunsStartSaysWhetherBindersToolsCameUp() {
        let started = #"{"type":"system","subtype":"init","mcp_servers":[{"name":"binders_manager","status":"failed"},{"name":"other","status":"connected"}]}"#
        XCTAssertTrue(ClaudeCodeManaged.started(in: "warming up\n" + started))
        XCTAssertFalse(ClaudeCodeManaged.started(in: "Error: something\n"))
        XCTAssertEqual(ClaudeCodeManaged.serverTrouble(in: started, server: "binders_manager"), "failed")
        XCTAssertNil(ClaudeCodeManaged.serverTrouble(in: started.replacingOccurrences(of: "\"failed\"", with: "\"connected\""), server: "binders_manager"))
        XCTAssertNil(ClaudeCodeManaged.serverTrouble(in: started.replacingOccurrences(of: "\"failed\"", with: "\"pending\""), server: "binders_manager"),
                     "still coming up is not trouble")
        XCTAssertNil(ClaudeCodeManaged.serverTrouble(in: started, server: "binders"), "another server's word is not ours")
    }

    func testWhatClaudeCodePrintedWhenItDidntStartIsSaidPlainly() {
        XCTAssertEqual(ClaudeCodeManaged.startupProblem(in: "Your organization's settings carries settings not yet approved in the managed-settings dialog; it is not applied until they are"),
                       ClaudeCodeManaged.approveLine)
        XCTAssertEqual(ClaudeCodeManaged.startupProblem(in: "Invalid API key · Please run /login"), ClaudeCodeManaged.signInLine)
        XCTAssertTrue(ClaudeCodeManaged.startupProblem(in: "Claude Code didn't start: your organization's policy hasn't loaded yet")?.contains("couldn't load your organization's settings") == true)
        XCTAssertTrue(ClaudeCodeManaged.startupProblem(in: "error: unknown option '--permission-prompts'")?.contains("claude update") == true)
        XCTAssertNil(ClaudeCodeManaged.startupProblem(in: #"{"type":"result","result":"Please run /login"}"#), "the run's own words never count")
        XCTAssertNil(ClaudeCodeManaged.startupProblem(in: "something else went wrong"))
        XCTAssertTrue(ClaudeCodeManaged.managerKeptOutLine.contains(ManagerLaunch.server), "it names the Manager's server, which the admin has to allow")
    }
}
