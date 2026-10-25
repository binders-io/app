import XCTest
@testable import BindersKit

/// Antigravity CLI (agy) as Binders starts it for a card, from its documentation: the launch, Binders' server in the
/// worktree, the check of your Antigravity settings, what it prints, what it refused, and Settings → MCP's file.
final class AntigravityTests: XCTestCase {
    private let card = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    private let home = "/Users/sam"
    private let data = "/Users/sam/Library/Application Support/Binders"
    private let binders = "/Applications/Binders.app/Contents/MacOS/Binders"
    private let logs = "/Users/sam/Library/Logs/Binders/Agents"
    private let worktree = "/Users/sam/.binders/worktrees/app-1a2b3c4d/binders-3f2504e04f89-antigravity"
    private let temporary = "/Users/sam/.binders/tmp/3f2504e0-20261018T120000"

    private func run(mode: String = "acceptEdits", model: String? = nil, conversation: String? = nil, throwaway: String? = nil) -> CLIAgentRun {
        CLIAgentRun(card: card, run: UUID(), reason: .ready, boardName: "Antigravity · app",
                    wake: CLIAgentWake(tool: .antigravity, repository: "/Users/sam/code/app", permissionMode: mode, model: model),
                    binders: binders, worktree: worktree + "/", temporary: temporary, places: "/Users/sam/.binders", bindersTemp: "/private/var/folders/xy/T",
                    dataFolder: data, home: home, alsoPrivate: [logs], runStem: "\(logs)/3f2504e0-20261018T120000", session: UUID(),
                    path: "/opt/homebrew/bin:/usr/bin:/bin",
                    base: ["HOME": home, "USER": "sam", "SHELL": "/bin/zsh", "GEMINI_API_KEY": "not-for-runs", "GOOGLE_API_KEY": "x",
                           "GOOGLE_GEMINI_BASE_URL": "https://elsewhere.invalid", "AGY_ADC_AUTH": "1", "SSH_AUTH_SOCK": "/tmp/agent"],
                    throwawayData: throwaway, copilotHome: "/Users/sam/.binders/copilot", conversation: conversation)
    }

    private var privatePaths: [String] { CLIAgentLaunches.privatePaths(home: home, dataFolder: data, alsoPrivate: [logs]) }

    // MARK: The launch

    func testLaunchLine() throws {
        let line = try CLIAgentLaunches.make(run())
        XCTAssertEqual(line.arguments, ["--input-format", "stream-json", "--output-format", "stream-json", "--sandbox", "--mode", "accept-edits",
                                        "--disable-slash-commands"])
        XCTAssertEqual(line.directory, worktree)
        XCTAssertEqual(line.mode, "edits files in its worktree, commands only in its sandbox, no network")
        XCTAssertNil(line.session)
        XCTAssertNil(line.lookIn)
    }

    func testThePromptGoesOnStandardInputAsOneMessage() throws {
        let line = try CLIAgentLaunches.make(run())
        XCTAssertTrue(line.stdin.hasSuffix("\n"))
        XCTAssertEqual(line.stdin.filter { $0 == "\n" }.count, 1, "one line: the prompt's own line breaks are escaped")
        let message = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.stdin.utf8)) as? [String: Any])
        XCTAssertEqual(message["event"] as? String, "user")
        let prompt = try XCTUnwrap((message["message"] as? [String: Any])?["content"] as? String)
        XCTAssertTrue(prompt.hasPrefix(AgentWake.promptMarker))
        XCTAssertTrue(prompt.contains("Card: \(card.uuidString)"))
        XCTAssertTrue(prompt.contains("Its commands run in Antigravity's terminal sandbox, and only the ones its settings allow"))
        // Nothing of the prompt in the arguments: no -p with text, and the card's id isn't there either.
        XCTAssertFalse(line.arguments.contains { $0 == "-p" || $0 == "--print" || $0 == "--prompt" || $0.hasPrefix("--prompt=") })
        XCTAssertFalse(line.arguments.joined(separator: " ").contains(card.uuidString))
        XCTAssertFalse(line.arguments.contains { $0.contains(AgentWake.promptMarker) })
    }

    func testItsChecksStayOn() throws {
        for model in [nil, "gemini-3.6-flash", "--dangerously-skip-permissions", "-m", "x --mode auto"] {
            let line = try CLIAgentLaunches.make(run(model: model))
            XCTAssertFalse(line.arguments.contains { $0.contains("dangerously") || $0.contains("skip-permissions") }, "\(model ?? "")")
            XCTAssertTrue(line.arguments.contains("--sandbox"), "its sandbox is always on")
            let mode = try XCTUnwrap(line.arguments.firstIndex(of: "--mode").map { line.arguments[$0 + 1] })
            XCTAssertEqual(mode, "accept-edits", "never Antigravity's Auto, whose approvals another model gives")
            XCTAssertEqual(line.arguments.filter { $0 == "--mode" }.count, 1)
            XCTAssertTrue(AgentCommands.isAllowed((["agy"] + line.arguments.map(AgentMCPEntry.quoted)).joined(separator: " ")))
        }
        XCTAssertEqual(try CLIAgentLaunches.make(run(model: "gemini-3.6-flash")).arguments.suffix(2), ["--model", "gemini-3.6-flash"])
        XCTAssertFalse(try CLIAgentLaunches.make(run(model: "--dangerously-skip-permissions")).arguments.contains("--model"), "a flag is no model")
    }

    func testReadingOnlyIsRefused() {
        for mode in ["plan", "", "bypassPermissions", "auto"] {
            XCTAssertThrowsError(try CLIAgentLaunches.make(run(mode: mode)), mode) { error in
                XCTAssertTrue((error as? CLIAgentLaunches.Refusal)?.message.hasPrefix("Antigravity can't be held to reading only") == true)
            }
        }
    }

    func testTheEnvironmentIsTheAllowlist() throws {
        let line = try CLIAgentLaunches.make(run())
        XCTAssertEqual(Set(line.environment.keys), ["PATH", "HOME", "USER", "SHELL", "LANG", "TMPDIR", "PWD", "NO_COLOR"])
        XCTAssertEqual(line.environment["PWD"], worktree)
        XCTAssertNil(line.environment["GEMINI_API_KEY"], "no API key of yours reaches a run")
        XCTAssertNil(line.environment["GOOGLE_GEMINI_BASE_URL"], "nor another address for its model")
        XCTAssertEqual(try CLIAgentLaunches.make(run(throwaway: "/tmp/data")).environment["BINDERS_DATA_DIR"], "/tmp/data")
    }

    func testItCarriesOnTheCardsConversation() throws {
        let id = "C3B66B04-872B-4FBE-A3A4-058A026EF20A"
        XCTAssertEqual(try CLIAgentLaunches.make(run(conversation: id)).arguments.suffix(2), ["--conversation", id.lowercased()])
        for bad in ["x; rm -rf ~", "--dangerously-skip-permissions", "", "c3b66b04"] {
            XCTAssertFalse(try CLIAgentLaunches.make(run(conversation: bad)).arguments.contains("--conversation"), bad)
        }
        XCTAssertEqual(AntigravityLaunch.lookIn(conversation: id, worktree: worktree, home: home),
                       "cd ~/.binders/worktrees/app-1a2b3c4d/binders-3f2504e04f89-antigravity && agy --conversation c3b66b04-872b-4fbe-a3a4-058a026ef20a")
        XCTAssertNil(AntigravityLaunch.lookIn(conversation: "x && open .", worktree: worktree, home: home))
        XCTAssertNil(AntigravityLaunch.lookIn(conversation: nil, worktree: worktree, home: home))
    }

    // MARK: Binders' server in the worktree

    func testTheWorktreesMCPConfigHasBindersServerForThisCardAlone() throws {
        let line = try CLIAgentLaunches.make(run(throwaway: "/tmp/data"))
        XCTAssertEqual(Array(line.files.keys), [worktree + "/.agents/mcp_config.json"])
        let text = try XCTUnwrap(line.files.values.first)
        XCTAssertEqual(text, #"{"mcpServers":{"binders":{"command":"\#(binders)","args":["--mcp"],"env":{"BINDERS_TOOLS":"board","BINDERS_RUN":"1","BINDERS_CARD":"\#(card.uuidString)","BINDERS_AGENT":"Antigravity · app","BINDERS_DATA_DIR":"/tmp/data"}}}}"#)
        let env = try XCTUnwrap(((((try JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["mcpServers"] as? [String: Any])?["binders"]
                                 as? [String: Any])?["env"] as? [String: String])
        XCTAssertEqual(MCPConfinement.read(env), .card(card), "board tools for this card only, even in a Binders before this one")
        XCTAssertTrue(AntigravityLaunch.isOurs(Data(text.utf8), binders: binders))
        XCTAssertFalse(AntigravityLaunch.isOurs(Data(text.utf8), binders: "/Applications/Other.app/Contents/MacOS/Binders"))
        // One a run changed, or the repository's own, is never taken for Binders'.
        let added = text.replacingOccurrences(of: #"{"mcpServers":{"#, with: #"{"mcpServers":{"mine":{"command":"/bin/sh"},"#)
        XCTAssertFalse(AntigravityLaunch.isOurs(Data(added.utf8), binders: binders))
        XCTAssertFalse(AntigravityLaunch.isOurs(Data(#"{"mcpServers":{"binders":{"command":"\#(binders)","args":["--mcp"]}}}"#.utf8), binders: binders),
                       "a server with every tool isn't the run's")
        XCTAssertFalse(AntigravityLaunch.isOurs(Data("// comment\n{}".utf8), binders: binders))
    }

    func testTheWorktreesAgentsFolder() {
        XCTAssertNil(AntigravityWorkspace.problem(present: []))
        XCTAssertNil(AntigravityWorkspace.problem(present: ["rules", "skills", "agents", "AGENTS.md"]), "words, read as data")
        XCTAssertEqual(AntigravityWorkspace.problem(present: ["rules", "hooks.json"]),
                       "Binders didn't start Antigravity: the card's worktree has .agents/hooks.json, which Antigravity would load and run outside its sandbox. Take it off the card's branch if the card doesn't need it, or give the card to another agent, then Wake Now.")
        XCTAssertTrue(AntigravityWorkspace.problem(present: ["mcp_config.json"])?.contains("whose servers Antigravity would start outside its sandbox") == true)
        XCTAssertTrue(AntigravityWorkspace.problem(present: ["plugins"])?.contains(".agents/plugins, which can bring hooks and servers of their own") == true)
        XCTAssertEqual(AntigravityWorkspace.added(present: ["hooks.json"], worktree: "~/w"),
                       "Didn't commit Antigravity's changes: the worktree has .agents/hooks.json now, which Antigravity would load and run outside its sandbox the next time it opens this repository. They're still in ~/w.")
        XCTAssertNil(AntigravityWorkspace.added(present: ["skills"], worktree: "~/w"))
    }

    // MARK: Your Antigravity settings

    private func check(_ json: String?) -> String? {
        AntigravitySettings.problem(json.map { Data($0.utf8) }, worktree: worktree, home: home, privatePaths: privatePaths)
    }

    private func allowing(_ rules: [String], preset: String? = nil) -> String {
        let list = (rules + ["mcp(binders/*)"]).map { "\"\($0)\"" }.joined(separator: ",")
        return "{" + (preset.map { #""toolPermission":"\#($0)","# } ?? "") + #""colorScheme":"dark","permissions":{"allow":[\#(list)],"deny":["write_file(.env)"]}}"#
    }

    func testTheBoardRuleIsNeeded() {
        for missing in [nil, "", "{}", #"{"permissions":{"allow":["command(git status)"]}}"#, #"{"permissions":{"ask":["mcp(binders/*)"]}}"#,
                        #"{"permissions":{"allow":["mcp(binders/get_task)"]}}"#] {
            let said = check(missing)
            XCTAssertTrue(said?.hasPrefix("Binders didn't start Antigravity: in a run with no one there to approve a step, Antigravity refuses any MCP tool its settings don't allow") == true, missing ?? "no file")
            XCTAssertTrue(said?.contains(#"Add "mcp(binders/*)" to permissions.allow in ~/.gemini/antigravity-cli/settings.json, then Wake Now."#) == true)
            XCTAssertTrue(said?.contains("Binders doesn't change that file.") == true)
        }
        XCTAssertNil(check(#"{"permissions":{"allow":["mcp(binders/*)"]}}"#))
        let each = AntigravitySettings.boardTools.map { "\"mcp(binders/\($0))\"" }.joined(separator: ",")
        XCTAssertNil(check(#"{"permissions":{"allow":[\#(each)]}}"#), "or every board tool by name")
        XCTAssertEqual(AntigravitySettings.boardTools.count, 9)
        XCTAssertNil(check(#"{"permission":{"allow":["mcp(binders/*)"]}}"#), "permission.allow, as the changelog once spelled it")
    }

    func testEachPreset() {
        for safe in ["request-review", "strict", "proceed-in-sandbox", ""] { XCTAssertNil(check(allowing([], preset: safe)), safe) }
        XCTAssertEqual(check(allowing([], preset: "always-proceed")),
                       "Binders didn't start Antigravity: ~/.gemini/antigravity-cli/settings.json sets toolPermission to always-proceed, which runs commands and tools without asking. Binders can't change your Antigravity settings for a run: change it there, or give the card to another agent, then Wake Now.")
        XCTAssertTrue(check(allowing([], preset: "turbo"))?.contains("sets toolPermission to turbo, which Binders doesn't know") == true)
        XCTAssertTrue(check(#"{"toolPermission":3,"permissions":{"allow":["mcp(binders/*)"]}}"#)?.contains("toolPermission in ~/.gemini/antigravity-cli/settings.json isn't a name Binders knows") == true)
    }

    func testAllowRulesInsideAndOutsideTheWorktree() {
        // Inside: relative paths, commands in the sandbox, Binders' own tools.
        for inside in ["write_file(src/)", "write_file(README.md)", "write_file(\(worktree)/docs)", "read_file(src)", "read_file(/usr/local/include)",
                       "command(git status)", "command(npm test)", "command(regex:npm run (build|lint))", "mcp(binders/claim_task)"] {
            XCTAssertNil(check(allowing([inside])), inside)
        }
        let outside: [(String, String)] = [
            ("write_file(*)", "lets it change files anywhere"),
            ("write_file(/etc)", "lets it change files outside its worktree (/etc)"),
            ("write_file(~/Documents)", "lets it change files outside its worktree (~/Documents)"),
            ("write_file(../other)", "lets it change files outside its worktree"),
            ("write_file(/Users/sam/.binders/worktrees/app-1a2b3c4d/binders-3f2504e04f89-antigravity-other)", "outside its worktree"),
            ("read_file(*)", "lets it read every file"),
            ("read_file(/)", "lets it read every file"),
            ("read_file(~/.ssh)", "lets it read ~/.ssh, which no run may read"),
            ("read_file(/Users/sam)", "lets it read ~/.ssh, which no run may read"),
            ("read_file(/Users/sam/*)", "lets it read ~/.ssh"),
            ("read_file(~/.gemini/antigravity-cli)", "lets it read ~/.gemini, which no run may read"),
            ("read_file(\(data)/notes)", "which no run may read"),
            ("read_file(../secrets)", "lets it read files outside its worktree"),
            ("unsandboxed(npm)", "runs commands outside Antigravity's sandbox"),
            ("read_url(github.com)", "lets it reach github.com without asking, its sandboxed commands too"),
            ("read_url(*)", "lets it reach any site without asking"),
            ("execute_url(example.com)", "lets it reach example.com"),
            ("mcp(*)", "lets it use every MCP server's tools without asking"),
            ("mcp(github/*)", "lets it use github's tools without asking, and they act outside its worktree"),
            ("mcp(binders)", "lets it use binders's tools without asking"),
            ("browse(x)", "Binders doesn't know what it allows"),
        ]
        for (rule, words) in outside {
            let said = check(allowing([rule]))
            XCTAssertTrue(said?.hasPrefix("Binders didn't start Antigravity: ~/.gemini/antigravity-cli/settings.json allows ") == true, rule)
            XCTAssertTrue(said?.contains(words) == true, "\(rule): \(said ?? "allowed")")
            XCTAssertTrue(said?.hasSuffix("then Wake Now.") == true)
        }
        XCTAssertTrue(check(allowing(["not a rule"]))?.contains("allows “not a rule”, which Binders can't read") == true)
        XCTAssertNil(check(allowing(["  "])), "a blank entry allows nothing")
    }

    func testAFileBindersCantRead() {
        for bad in ["{", "// mine\n{\"toolPermission\":\"request-review\"}", "[1,2]", "/* mine */ {}"] {
            XCTAssertEqual(check(bad), "Binders didn't start Antigravity: ~/.gemini/antigravity-cli/settings.json isn't JSON Binders can read (it doesn't read comments), so it can't tell what a run would be allowed. Fix it there, then Wake Now.", bad)
        }
        XCTAssertTrue(check(#"{"permissions":["mcp(binders/*)"]}"#)?.contains("permissions in ~/.gemini/antigravity-cli/settings.json isn't in a shape Binders can read") == true)
        XCTAssertTrue(check(#"{"permissions":{"allow":"mcp(binders/*)"}}"#)?.contains("permissions.allow in ~/.gemini/antigravity-cli/settings.json isn't a list") == true)
        XCTAssertTrue(check(#"{"permissions":{"allow":["mcp(binders/*)", 3]}}"#)?.contains("isn't a list Binders can read") == true)
        XCTAssertEqual(AntigravitySettings.found(Data(allowing([], preset: "always-proceed").utf8), worktree: nil, home: home, privatePaths: privatePaths)?
            .hasPrefix("Binders won't start Antigravity as your settings are: ~/.gemini/antigravity-cli/settings.json sets toolPermission to always-proceed"), true)
        XCTAssertNil(AntigravitySettings.found(Data(allowing([]).utf8), worktree: nil, home: home, privatePaths: privatePaths))
    }

    func testOnlyTheTwoKeysCount() {
        // Everything else in the file (its look, its model, its other lists) is left unread.
        XCTAssertNil(check(#"{"model":"x","customModelsConfig":{"customModels":[]},"enableTerminalSandbox":false,"agentMode":"auto","permissions":{"allow":["mcp(binders/*)"],"ask":["command(*)"],"deny":["mcp(*)"]}}"#))
    }

    func testARuleReadsAsAntigravityWritesIt() {
        XCTAssertEqual(AntigravitySettings.Rule.parse("command(npm test)"), .init(action: "command", target: "npm test"))
        XCTAssertEqual(AntigravitySettings.Rule.parse(" command(regex:npm run (build|lint)) ")?.target, "regex:npm run (build|lint)")
        XCTAssertNil(AntigravitySettings.Rule.parse("command (git)"))
        XCTAssertNil(AntigravitySettings.Rule.parse("(git)"))
        XCTAssertNil(AntigravitySettings.Rule.parse("command(git"))
    }

    // MARK: What it prints (stream-json)

    /// The example in Antigravity's headless documentation, as it is.
    private let documented = [
        #"{"event":"init","conversation_id":"c3b66b04-872b-4fbe-a3a4-058a026ef20a","init":{"cwd":"/home/user/project","tools":["ask_permission","run_command","write_to_file","..."],"permission_mode":"request-review"}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c3b66b04-872b-4fbe-a3a4-058a026ef20a","step_index":0,"state":"DONE","step_type":"user_input"}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c3b66b04-872b-4fbe-a3a4-058a026ef20a","step_index":3,"state":"DONE","step_type":"agent_response","text_delta":"Git rebase rewrites a branch's history.\n","duration_seconds":6.28,"usage":{"input_tokens":10302,"output_tokens":582,"thinking_tokens":551,"cache_read_tokens":8113,"total_tokens":10884}}}"#,
        #"{"event":"step_update","step_update":{"conversation_id":"c3b66b04-872b-4fbe-a3a4-058a026ef20a","step_index":4,"state":"DONE","step_type":"checkpoint","duration_seconds":0.53}}"#,
        #"{"event":"result","result":{"conversation_id":"c3b66b04-872b-4fbe-a3a4-058a026ef20a","status":"SUCCESS","response":"Git rebase rewrites a branch's history.\n","duration_seconds":6.88,"num_turns":1,"usage":{"input_tokens":10418,"output_tokens":589,"thinking_tokens":551,"cache_read_tokens":8113,"total_tokens":11007}}}"#,
    ]

    private func read(_ lines: [String]) -> CLIAgentResult { CLIAgentOutput.read(.antigravity, lines.joined(separator: "\n")) }

    private func step(_ index: Int, _ type: String, state: String = "DONE", _ more: String = "") -> String {
        #"{"event":"step_update","step_update":{"conversation_id":"c3b66b04-872b-4fbe-a3a4-058a026ef20a","step_index":\#(index),"state":"\#(state)","step_type":"\#(type)"\#(more)}}"#
    }

    private func result(_ status: String, _ more: String = "") -> String {
        #"{"event":"result","result":{"conversation_id":"c3b66b04-872b-4fbe-a3a4-058a026ef20a","status":"\#(status)"\#(more)}}"#
    }

    func testTheDocumentedRun() {
        let out = read(documented)
        XCTAssertTrue(out.completed)
        XCTAssertNil(out.failure)
        XCTAssertEqual(out.session, "c3b66b04-872b-4fbe-a3a4-058a026ef20a")
        XCTAssertEqual(out.lastText, "Git rebase rewrites a branch's history.\n")
        XCTAssertFalse(out.usedBoard)
        XCTAssertNil(out.plan)
    }

    func testDeltasMakeTheLastWordsWhenThereIsNoResponse() {
        let out = read([step(1, "agent_response", state: "ACTIVE", #","text_delta":"Fixed the ""#), step(1, "agent_response", state: "ACTIVE", #","text_delta":"footer.""#),
                        result("SUCCESS")])
        XCTAssertEqual(out.lastText, "Fixed the footer.")
        // A step that's done and says its whole text again replaces what came before, not doubles it.
        let again = read([step(1, "agent_response", state: "ACTIVE", #","text_delta":"Fixed ""#),
                          step(1, "agent_response", #","text_delta":"Fixed the footer.""#)])
        XCTAssertEqual(again.lastText, "Fixed the footer.")
        XCTAssertFalse(again.completed, "no result: it didn't end its turn")
    }

    func testToolSteps() {
        let board = step(2, "tool", state: "ACTIVE", #","tool_name":"mcp_binders_claim_task","tool_info":{"name":"mcp_binders_claim_task","parameters":{"id":"x"}}"#)
        XCTAssertTrue(read([board]).usedBoard)
        XCTAssertTrue(read([step(2, "tool", #","tool_info":{"name":"claim_task","server":"binders"}"#)]).usedBoard, "by its server")
        XCTAssertFalse(read([step(2, "tool", #","tool_name":"mcp_github_claim_task"}"#)]).usedBoard, "another server's tool of the same name")
        XCTAssertFalse(read([step(2, "tool", #","tool_name":"binders_notes"}"#)]).usedBoard)
        let command = step(3, "tool", state: "ACTIVE", #","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"swift test","Cwd":"/w"}}"#)
        XCTAssertEqual(read([command]).plan, "Running swift test")
        XCTAssertEqual(read([step(3, "tool", state: "ACTIVE", #","tool_name":"replace_file_content","tool_info":{"args":{"TargetFile":"/w/Sources/App.swift"}}"#)]).plan,
                       "Editing App.swift")
        XCTAssertEqual(read([step(3, "tool", state: "ACTIVE", #","tool_name":"view_file","tool_info":{"input":{"AbsolutePath":"/w/README.md"}}"#)]).plan, "Reading README.md")
        XCTAssertNil(read([command, result("SUCCESS")]).plan, "nothing once it's done")
    }

    func testResultStatuses() {
        XCTAssertEqual(read([result("ERROR", #","error":"model unavailable""#)]).failure, "model unavailable")
        XCTAssertFalse(read([result("ERROR")]).completed)
        let words = ["CANCELED": "its turn was cancelled", "INTERRUPTED": "its turn was interrupted", "INVALID": "Antigravity didn't take the request",
                     "WAITING": "it stopped at a step a run can't approve", "RUNNING": "it ended while its turn was still going", "LATER": "its turn ended with LATER"]
        for (status, said) in words {
            let out = read([result(status)])
            XCTAssertFalse(out.completed, status)
            XCTAssertEqual(out.failure, said, status)
        }
        XCTAssertTrue(read([result("success")]).completed)
    }

    func testUnknownEventsAndCutLinesAreSkipped() {
        let out = read([#"{"event":"heartbeat","heartbeat":{"conversation_id":"c3b66b04-872b-4fbe-a3a4-058a026ef20a"}}"#,
                        #"{"event":"subagent_update","subagent_update":{"text_delta":"not mine"}}"#,
                        "not json", "", #"{"event":"result","result":{"status":"SUCC"#] + documented.prefix(3))
        XCTAssertEqual(out.lastText, "Git rebase rewrites a branch's history.\n")
        XCTAssertFalse(out.completed, "the cut result line isn't read")
        XCTAssertEqual(out.session, "c3b66b04-872b-4fbe-a3a4-058a026ef20a")
    }

    func testDeniedActions() {
        let out = read([result("SUCCESS", #","response":"Done, but I couldn't run the tests.","denied_actions":["command(npm test)",{"rule":"write_file(/etc/hosts)"},{"tool":"run_command","command":"swift build"},{"action":"read_url","target":"github.com"},"command(npm test)",7]"#)])
        XCTAssertEqual(out.denied, ["command(npm test)", "write_file(/etc/hosts)", "command(swift build)", "read_url(github.com)"])
        XCTAssertEqual(AntigravityDenials.line(out.denied),
                       "Antigravity wasn't allowed to run `npm test`, change `/etc/hosts`, run `swift build` or reach `github.com`. No one is there to approve a step in Binders' runs, so a command outside its sandbox, or one your Antigravity settings don't allow, doesn't run.")
    }

    // MARK: What it refused, on stderr

    func testSoftDenyNotices() {
        let stderr = """
            \u{1B}[33mnotice:\u{1B}[0m run_command was soft-denied: "npm test" needs approval. To allow it, add "command(npm test)" to permissions.allow in settings.json
            Permission denied for write_to_file (../outside.txt); allow rule: write_file(../outside.txt)
            Working on it, see command(this is not a refusal)
            denied: mcp(github/create_issue) and command(git push origin (main))
            notice: run_command was soft-denied: "npm test" needs approval. To allow it, add "command(npm test)" to permissions.allow in settings.json
            """
        let rules = AntigravityDenials.inErrors(stderr)
        XCTAssertEqual(rules.map(\.text), ["command(npm test)", "write_file(../outside.txt)", "mcp(github/create_issue)", "command(git push origin (main))"])
        XCTAssertEqual(AntigravityDenials.line(rules.map(\.text)),
                       "Antigravity wasn't allowed to run `npm test`, change `../outside.txt`, use the tool `github/create_issue` or run `git push origin (main)`. No one is there to approve a step in Binders' runs, so a command outside its sandbox, or one your Antigravity settings don't allow, doesn't run.")
        XCTAssertEqual(AntigravityDenials.line(["command(npm test)"])?.hasPrefix("Antigravity wasn't allowed to run `npm test`. "), true)
        XCTAssertNil(AntigravityDenials.line([]))
        XCTAssertTrue(AntigravityDenials.inErrors("stand-in: done\nerror: model unavailable").isEmpty)
        let many = (1...7).map { "command(step \($0))" }
        XCTAssertEqual(AntigravityDenials.line(many)?.contains("run `step 4` or run `step 5`, and 2 more."), true)
    }

    func testSignInAndWhyItStopped() {
        for said in ["error: authentication required: run agy in a terminal to sign in", "Authentication expired. Please log back in.",
                     "agy failed with a locked-keyring error"] {
            XCTAssertEqual(CLIAgentOutput.signIn(.antigravity, said: said),
                           "Sign in to Antigravity: open Terminal and run agy once, then Wake Now. Binders' runs use the sign-in agy keeps on this Mac; Binders never sees it.", said)
        }
        XCTAssertNil(CLIAgentOutput.signIn(.antigravity, said: "error: model unavailable"))
        XCTAssertEqual(AntigravityOutput.reason(inErrors: "starting\nerror: unknown model gemini-9\nhint: agy models"), "error: unknown model gemini-9")
        XCTAssertEqual(AntigravityOutput.reason(inErrors: #"partial\nAGY_ERROR: {"status":"UNAVAILABLE","message":"The model is overloaded","retryable":true}"#
            .replacingOccurrences(of: "\\n", with: "\n")), "The model is overloaded")
        XCTAssertEqual(AntigravityOutput.reason(inErrors: #"AGY_ERROR: {"status":"UNAVAILABLE"}"#), "Antigravity said UNAVAILABLE")
        XCTAssertEqual(AntigravityOutput.reason(inErrors: "only this"), "only this")
        XCTAssertNil(AntigravityOutput.reason(inErrors: ""))
    }

    func testItsVersion() {
        for (printed, version) in [("1.4.7\n", "1.4.7"), ("agy 1.4.7", "1.4.7"), ("agy version 1.4.7 (abc123)", "1.4.7"), ("Antigravity CLI v1.4.8", "1.4.8"),
                                   ("antigravity 1.5.0-beta.1", "1.5.0-beta.1")] {
            XCTAssertEqual(CLIAgent.antigravity.version(in: printed), version, printed)
        }
        XCTAssertNil(CLIAgent.antigravity.version(in: "codex-cli 0.162.0"))
        XCTAssertNil(CLIAgent.antigravity.version(in: "zsh: command not found: agy"))
        XCTAssertTrue(CLIAgent.antigravity.starts("1.4.9"))
        XCTAssertFalse(CLIAgent.antigravity.starts("1.5.0"), "a minor release needs Check")
        XCTAssertEqual(CLIAgent.antigravity.versionArguments, ["--version"])
    }

    func testACommandAgentCantTurnItsChecksOff() {
        XCTAssertEqual(AgentCommands.refusal("agy --mode auto -p 'fix it'"), "--mode auto")
        XCTAssertEqual(AgentCommands.refusal("agy --mode=auto -p x"), "--mode auto")
        XCTAssertNotNil(AgentCommands.refusal("agy -p x --dangerously-skip-permissions"))
        XCTAssertNil(AgentCommands.refusal("agy -p x --mode accept-edits --sandbox"))
        XCTAssertEqual(AgentConsent.knownVendors["agy"], "Google")
    }

    // MARK: Settings → MCP's file

    func testAddingKeepsEverythingElse() throws {
        let theirs = #"{"mcpServers":{"sqlite":{"command":"node","args":["s.js"],"timeoutSeconds":180}},"other":{"keep":true}}"#
        let entry: [String: Any] = ["command": binders, "args": ["--mcp"], "env": ["BINDERS_AGENT": "Antigravity"]]
        let added = try MCPConfigFile.adding(entry, named: "binders", to: Data(theirs.utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: added) as? [String: Any])
        let servers = try XCTUnwrap(object["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["sqlite", "binders"])
        XCTAssertEqual((servers["sqlite"] as? [String: Any])?["timeoutSeconds"] as? Int, 180)
        XCTAssertEqual((object["other"] as? [String: Any])?["keep"] as? Bool, true)
        XCTAssertEqual(((servers["binders"] as? [String: Any])?["env"] as? [String: String])?["BINDERS_AGENT"], "Antigravity")
        // Again: replaced, not doubled.
        let again = try MCPConfigFile.adding(["command": "/new"], named: "binders", to: added)
        XCTAssertEqual(((try JSONSerialization.jsonObject(with: again) as? [String: Any])?["mcpServers"] as? [String: Any])?.count, 2)
        // No file, or an empty one.
        for empty in [nil, Data(), Data("  \n".utf8)] {
            let made = try MCPConfigFile.adding(entry, named: "binders", to: empty)
            XCTAssertEqual(((try JSONSerialization.jsonObject(with: made) as? [String: Any])?["mcpServers"] as? [String: Any])?.keys.sorted(), ["binders"])
        }
        // One Binders can't read is never written over: comments, trailing commas, not an object, servers not a map.
        for unreadable in ["// mine\n{\"mcpServers\":{}}", "/* c */ {}", "[]", #"{"mcpServers":[]}"#] {
            XCTAssertThrowsError(try MCPConfigFile.adding(entry, named: "binders", to: Data(unreadable.utf8)), unreadable)
        }
    }

    func testRemovingTakesOnlyBinders() throws {
        let both = #"{"mcpServers":{"sqlite":{"command":"node"},"binders":{"command":"/b"}},"other":1}"#
        let removed = try XCTUnwrap(try MCPConfigFile.removing(named: "binders", from: Data(both.utf8)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
        XCTAssertEqual((object["mcpServers"] as? [String: Any])?.keys.sorted(), ["sqlite"])
        XCTAssertEqual(object["other"] as? Int, 1)
        XCTAssertNil(try MCPConfigFile.removing(named: "binders", from: Data(#"{"mcpServers":{"sqlite":{}}}"#.utf8)), "nothing to take out")
        XCTAssertNil(try MCPConfigFile.removing(named: "binders", from: nil))
        XCTAssertThrowsError(try MCPConfigFile.removing(named: "binders", from: Data("/* c */ {}".utf8)))
        let alone = try XCTUnwrap(try MCPConfigFile.removing(named: "binders", from: Data(#"{"mcpServers":{"binders":{}}}"#.utf8)))
        XCTAssertEqual(String(decoding: alone, as: UTF8.self).filter { !$0.isWhitespace }, #"{"mcpServers":{}}"#)
    }

    // MARK: Writing capture through its hook

    func testItsHookHandsOverTheLastThingYouSent() throws {
        let payload = Data(#"{"conversationId":"ec33ebf9-0cba-4100-8142-c61503f6c587","workspacePaths":["/Users/sam/code/app"],"transcriptPath":"/x","modelName":"gemini-3.6-flash-medium","invocationNum":2,"lastUserInput":"add a test for the parser"}"#.utf8)
        let read = try XCTUnwrap(HookPayload.read(payload))
        XCTAssertEqual(read.text, "add a test for the parser")
        XCTAssertEqual(read.project, "/Users/sam/code/app")
        XCTAssertEqual(HookPayload.conversation(payload), "ec33ebf9-0cba-4100-8142-c61503f6c587")
        let object = Data(#"{"conversationId":"c","lastUserInput":{"content":"rename the module"}}"#.utf8)
        XCTAssertEqual(HookPayload.read(object)?.text, "rename the module")
        XCTAssertNil(HookPayload.read(Data(#"{"conversationId":"c","modelName":"m","transcriptPath":"/t"}"#.utf8)), "no prompt, nothing kept")
        // The same prompt in the same conversation, handed over before each model call, is one prompt.
        let first = HookPayload.repeatKey(tool: "Antigravity", conversation: "c", text: "a")
        XCTAssertEqual(first, HookPayload.repeatKey(tool: "Antigravity", conversation: "c", text: "a"))
        XCTAssertNotEqual(first, HookPayload.repeatKey(tool: "Antigravity", conversation: "d", text: "a"))
        XCTAssertNotEqual(first, HookPayload.repeatKey(tool: "Antigravity", conversation: "c", text: "b"))
        XCTAssertFalse(first.contains("a "), "a digest, not the words")
        XCTAssertNil(HookPayload.conversation(Data("plain words".utf8)))
    }
}
